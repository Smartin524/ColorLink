package com.colorlink

import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.net.URLConnection
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/** 协议见 PROTOCOL.md。onActivity 在每个请求到来时调用，用于短暂持有 Wi-Fi 锁和唤醒锁。 */
class Api(
    private val ctx: Context,
    private val media: MediaRepo,
    private val onActivity: () -> Unit,
) {
    private var failedPairs = 0

    fun handle(req: Request): Response {
        onActivity()
        if (req.path == "/api/pair") return pair(req)
        // 不需要令牌：Mac 先用它核对“这个地址上的是不是我配对过的手机”，确认了才发令牌
        if (req.path == "/api/id") return Response.json(JSONObject().put("deviceId", Prefs.deviceId(ctx)).put("name", deviceName()))
        if (!authorized(req)) return Response.text(401, "unauthorized")
        return when (req.path) {
            "/api/info" -> Response.json(info())
            "/api/media" -> {
                val kind = MediaRepo.Kind.of(req.q("kind")) ?: return Response.text(400, "bad kind")
                val offset = req.q("offset")?.toIntOrNull()?.coerceAtLeast(0) ?: 0
                val limit = req.q("limit")?.toIntOrNull()?.coerceIn(1, 500) ?: 200
                Response.json(media.list(kind, offset, limit))
            }
            "/api/thumb" -> thumb(req)
            "/api/file" -> file(req)
            "/api/events" -> events(req)
            "/api/upload" -> upload(req)
            else -> Response.text(404, "not found")
        }
    }

    private fun authorized(req: Request): Boolean {
        val given = req.header("authorization")?.removePrefix("Bearer ")?.trim() ?: req.q("t") ?: return false
        return MessageDigest.isEqual(given.toByteArray(), Prefs.token(ctx).toByteArray())
    }

    @Synchronized
    private fun pair(req: Request): Response {
        val code = req.q("code") ?: return Response.text(400, "missing code")
        if (!MessageDigest.isEqual(code.toByteArray(), Prefs.pairCode(ctx).toByteArray())) {
            failedPairs++
            if (failedPairs >= 5) {
                Prefs.resetPairCode(ctx)
                failedPairs = 0
            }
            return Response.text(403, "wrong code")
        }
        failedPairs = 0
        Prefs.resetPairCode(ctx)
        return Response.json(
            JSONObject()
                .put("token", Prefs.token(ctx))
                .put("deviceId", Prefs.deviceId(ctx))
                .put("name", deviceName()),
        )
    }

    fun info(): JSONObject {
        val bm = ctx.getSystemService(BatteryManager::class.java)
        return JSONObject()
            .put("deviceId", Prefs.deviceId(ctx))
            .put("name", deviceName())
            .put("model", Build.MODEL)
            .put("android", Build.VERSION.RELEASE)
            .put("battery", bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
            .put("charging", bm?.isCharging)
    }

    private fun thumb(req: Request): Response {
        val kind = MediaRepo.Kind.of(req.q("kind")) ?: return Response.text(400, "bad kind")
        val id = req.q("id")?.toLongOrNull() ?: return Response.text(400, "bad id")
        val version = req.q("v")?.toLongOrNull() ?: 0
        val size = req.q("size")?.toIntOrNull()?.coerceIn(64, 1024) ?: 256
        val data = media.thumbnail(kind, id, version, size) ?: return Response.text(404, "no thumbnail")
        // 缩略图由 (id, 修改时间) 唯一确定，可以放心让 Mac 长期缓存
        return Response.bytes(data, "image/jpeg", mapOf("Cache-Control" to "max-age=31536000, immutable"))
    }

    private fun file(req: Request): Response {
        val kind = MediaRepo.Kind.of(req.q("kind")) ?: return Response.text(400, "bad kind")
        val id = req.q("id")?.toLongOrNull() ?: return Response.text(400, "bad id")
        val meta = media.item(kind, id) ?: return Response.text(404, "not found")
        val pfd = media.open(kind, id) ?: return Response.text(404, "cannot open")
        val size = pfd.statSize
        val input = ParcelFileDescriptor.AutoCloseInputStream(pfd)
        val name = URLEncoder.encode(meta.getString("name"), "UTF-8").replace("+", "%20")
        val headers = mutableMapOf(
            "Content-Type" to meta.getString("mime"),
            "Accept-Ranges" to "bytes",
            "Content-Disposition" to "inline; filename*=UTF-8''$name",
        )

        val range = req.header("range")
        if (range == null || !range.startsWith("bytes=") || size <= 0) {
            return Response(200, headers, Response.Body.Stream(input, size))
        }

        // 只处理单段 Range，播放器和下载器都只用这种
        val spec = range.removePrefix("bytes=").substringBefore(',').trim()
        val startStr = spec.substringBefore('-')
        val endStr = spec.substringAfter('-', "")
        val start: Long
        val end: Long
        if (startStr.isEmpty()) {
            val suffix = endStr.toLongOrNull() ?: 0
            start = (size - suffix).coerceAtLeast(0)
            end = size - 1
        } else {
            start = startStr.toLongOrNull() ?: 0
            end = endStr.toLongOrNull()?.coerceAtMost(size - 1) ?: (size - 1)
        }
        if (start > end || start >= size) {
            input.close()
            return Response(416, mutableMapOf("Content-Range" to "bytes */$size"), Response.Body.Bytes(ByteArray(0)))
        }
        skipFully(input, start)
        headers["Content-Range"] = "bytes $start-$end/$size"
        return Response(206, headers, Response.Body.Stream(input, end - start + 1))
    }

    private fun events(req: Request): Response {
        req.q("name")?.takeIf { it.isNotBlank() }?.let { LinkCore.macName = it }
        // 记下 Mac 的地址，手机下次醒来时直接给它敲门
        val addr = req.remote
        if (addr is java.net.Inet4Address && !addr.isLoopbackAddress) addr.hostAddress?.let { Prefs.setLastMac(ctx, it) }
        return eventStream()
    }

    private fun eventStream() = Response(
        200,
        mutableMapOf(
            "Content-Type" to "text/event-stream; charset=utf-8",
            "Cache-Control" to "no-cache",
            // 没有这个头，macOS 的 URLSession 会先攒够 512 字节用来猜内容类型，事件就迟迟收不到
            "X-Content-Type-Options" to "nosniff",
        ),
        Response.Body.Streaming { out ->
            val q = EventBus.subscribe()
            try {
                out.write("event: hello\ndata: ${info()}\n\n".toByteArray())
                out.flush()
                while (true) {
                    // 20 秒没有事件就发一行注释保活，Mac 端据此判断连接是否还活着
                    val msg = q.poll(20, TimeUnit.SECONDS) ?: ": ping\n\n"
                    out.write(msg.toByteArray(Charsets.UTF_8))
                    out.flush()
                }
            } catch (_: IOException) {
            } catch (_: InterruptedException) {
            } finally {
                EventBus.unsubscribe(q)
            }
        },
    )

    /** Mac 发来的文件：POST /api/upload?name=文件名&mime=类型，请求体是文件内容。 */
    private fun upload(req: Request): Response {
        if (req.method != "POST") return Response.text(405, "use POST")
        val name = (req.q("name") ?: "file").substringAfterLast('/')
            .replace(Regex("""[\\:*?"<>|]"""), "_").take(120).ifBlank { "file" }
        val mime = req.q("mime")?.takeIf { it.contains('/') }
            ?: URLConnection.guessContentTypeFromName(name) ?: "application/octet-stream"
        val saved = media.save(name, mime, req.body)
        Notifications.received(ctx, saved)
        return Response.json(saved.json)
    }

    private fun skipFully(input: InputStream, n: Long) {
        var left = n
        while (left > 0) {
            val s = input.skip(left)
            if (s <= 0) break
            left -= s
        }
    }

    private fun deviceName() = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
}
