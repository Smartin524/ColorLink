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

/**
 * 协议见 PROTOCOL.md。
 *
 * onTransferStart / onTransferEnd 包住传输类接口（列表、缩略图、原文件、收发文件），
 * 用来在传输期间持有 Wi-Fi 锁和唤醒锁；探活、事件流这类轻请求不算传输，不持锁。
 */
class Api(
    private val ctx: Context,
    private val media: MediaRepo,
    private val onTransferStart: () -> Unit,
    private val onTransferEnd: () -> Unit,
) {
    private var failedPairs = 0

    fun handle(req: Request): Response {
        if (!Prefs.connectionEnabled(ctx)) return Response.text(503, "connection disabled")
        if (req.path == "/api/pair") return pair(req)
        if (req.path == "/api/logs") {
            return if (authorized(req)) Response.bytes(AppLog.dump().toByteArray(), "text/plain; charset=utf-8")
            else Response.text(401, "unauthorized")
        }
        // 不需要令牌：Mac 先用它核对“这个地址上的是不是我配对过的手机”，确认了才发令牌
        if (req.path == "/api/id") return Response.json(JSONObject().put("deviceId", Prefs.deviceId(ctx)).put("name", deviceName()))
        if (!authorized(req)) return Response.text(401, "unauthorized")
        return when (req.path) {
            "/api/info" -> {
                EventBus.ping()
                Response.json(info())
            }
            "/api/media" -> transfer {
                val kind = MediaRepo.Kind.of(req.q("kind")) ?: return@transfer Response.text(400, "bad kind")
                val offset = req.q("offset")?.toIntOrNull()?.coerceAtLeast(0) ?: 0
                val limit = req.q("limit")?.toIntOrNull()?.coerceIn(1, 500) ?: 200
                Response.json(media.list(kind, offset, limit))
            }
            "/api/thumb" -> transfer { thumb(req) }
            "/api/file" -> transfer { file(req) }
            "/api/events" -> events(req)
            "/api/upload" -> transfer { upload(req) }
            "/api/trash" -> trash(req)
            "/api/shared" -> transfer { shared(req) }
            "/api/dnd" -> dnd(req)
            else -> Response.text(404, "not found")
        }
    }

    /**
     * 免打扰：GET 查当前档位，POST ?mode=all|priority|alarms|none 改档位，都返回 {"mode"}。
     * 没开通知使用权时改不了，返回 503。改完系统会异步回调，再以 dnd 事件通知 Mac
     */
    private fun dnd(req: Request): Response {
        val current = NotifyListener.dndMode() ?: return Response.text(503, "notification access not granted")
        if (req.method != "POST") return Response.json(JSONObject().put("mode", current))
        val mode = req.q("mode") ?: return Response.text(400, "missing mode")
        if (!NotifyListener.setDndMode(mode)) return Response.text(400, "bad mode")
        return Response.json(JSONObject().put("mode", mode))
    }

    /** 传输期间持锁：从开始处理到响应（包括原文件的整个流）写完为止；处理出错也会放锁 */
    private inline fun transfer(block: () -> Response): Response {
        onTransferStart()
        val resp = try {
            block()
        } catch (e: Throwable) {
            onTransferEnd()
            throw e
        }
        resp.onDone = onTransferEnd
        return resp
    }

    private fun authorized(req: Request): Boolean {
        val given = req.header("authorization")?.removePrefix("Bearer ")?.trim() ?: return false
        val ok = MessageDigest.isEqual(given.toByteArray(), Prefs.token(ctx).toByteArray())
        // 早于“已配对”记录的老配对：有电脑带着正确密钥来访问，就补记为已配对
        if (ok && !Prefs.paired(ctx)) Prefs.setPaired(ctx)
        return ok
    }

    @Synchronized
    private fun pair(req: Request): Response {
        val code = req.q("code") ?: return Response.text(400, "missing code")
        if (!MessageDigest.isEqual(code.toByteArray(), Prefs.pairCode(ctx).toByteArray())) {
            failedPairs++
            AppLog.w("ColorLink.Api", "配对码错误（${req.remote.hostAddress}，第 $failedPairs 次）")
            if (failedPairs >= 5) {
                Prefs.resetPairCode(ctx)
                failedPairs = 0
            }
            return Response.text(403, "wrong code")
        }
        failedPairs = 0
        Prefs.resetPairCode(ctx)
        Prefs.setPaired(ctx)
        AppLog.i("ColorLink.Api", "与「${req.q("client") ?: "?"}」配对成功（${req.remote.hostAddress}）")
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
            .put("dnd", NotifyListener.dndMode()) // null：没开通知使用权，Mac 上的免打扰按钮不可用
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

    /** 分享菜单「发送到 Mac」的文件：GET /api/shared?id=，id 来自 shared 事件 */
    private fun shared(req: Request): Response {
        val entry = req.q("id")?.let(SharedFiles::get) ?: return Response.text(404, "not found")
        val name = URLEncoder.encode(entry.name, "UTF-8").replace("+", "%20")
        return Response(
            200,
            mutableMapOf("Content-Type" to entry.mime, "Content-Disposition" to "attachment; filename*=UTF-8''$name"),
            Response.Body.Stream(entry.file.inputStream(), entry.file.length()),
        )
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

    /**
     * 移到「最近删除」：POST /api/trash，请求体 {"items":[{"kind":"image","id":123},…]}。
     * 返回 {"trashed": 已移走数量, "pending": 是否在等手机上确认}。
     */
    private fun trash(req: Request): Response {
        if (req.method != "POST") return Response.text(405, "use POST")
        val items = JSONObject(req.body.readBytes().decodeToString()).optJSONArray("items")
            ?: return Response.text(400, "missing items")
        val targets = (0 until items.length()).mapNotNull { i ->
            val o = items.getJSONObject(i)
            MediaRepo.Kind.of(o.optString("kind"))?.let { it to o.getLong("id") }
        }
        val (trashed, pending) = media.trash(targets)
        AppLog.i("ColorLink.Api", "Mac 请求删除 ${targets.size} 项：已移到最近删除 $trashed，等待确认 $pending")
        return Response.json(JSONObject().put("trashed", trashed).put("pending", pending))
    }

    /** Mac 发来的文件：POST /api/upload?name=文件名&mime=类型&batch=批次&index=序号&count=总数，请求体是文件内容。 */
    private fun upload(req: Request): Response {
        if (req.method != "POST") return Response.text(405, "use POST")
        val name = (req.q("name") ?: "file").substringAfterLast('/')
            .replace(Regex("""[\\:*?"<>|]"""), "_").take(120).ifBlank { "file" }
        val mime = req.q("mime")?.takeIf { it.contains('/') }
            ?: URLConnection.guessContentTypeFromName(name) ?: "application/octet-stream"
        // 一次拖过来的多个文件是一批：batch 相同，index 从 0 数到 count - 1。旧版 Mac 不带这些参数，当作一个文件的一批
        val count = req.q("count")?.toIntOrNull()?.coerceAtLeast(1) ?: 1
        val index = req.q("index")?.toIntOrNull()?.coerceIn(0, count - 1) ?: 0
        val batchId = req.q("batch") ?: "single-${System.nanoTime()}"
        // 接收过程中显示流体云和进度，最多每 0.3 秒更新一次
        val total = req.header("content-length")?.toLongOrNull() ?: 0
        var lastUpdate = 0L
        Notifications.receiving(ctx, name, index, count, if (total > 0) 0f else null)
        val saved = try {
            media.save(name, mime, req.body) { done ->
                val now = System.currentTimeMillis()
                if (now - lastUpdate > 300 && total > 0) {
                    lastUpdate = now
                    Notifications.receiving(ctx, name, index, count, done.toFloat() / total)
                }
            }
        } catch (e: Exception) {
            Notifications.receiveFailed(ctx)
            throw e
        }
        AppLog.i("ColorLink.Api", "收到 Mac 发来的文件：$mime，保存到 ${saved.dir}")
        Notifications.receivedOne(ctx, saved, batchId, index, count)
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

    /** 优先用商品名（OPPO Find X8 Ultra），读不到才用厂商 + 工程型号（OPPO PKJ110） */
    private fun deviceName() = ColorOS.marketName ?: "${Build.MANUFACTURER} ${Build.MODEL}".trim()
}
