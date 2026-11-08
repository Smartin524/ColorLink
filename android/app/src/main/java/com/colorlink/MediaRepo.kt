package com.colorlink

import android.content.ContentResolver
import android.content.ContentValues
import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.net.Uri
import android.os.BatteryManager
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.MediaStore.MediaColumns
import android.util.Size
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.concurrent.Semaphore

private const val TAG = "ColorLink.Media"

/** 通过 MediaStore 读取照片、视频、录音，并维护磁盘缩略图缓存。 */
class MediaRepo(context: Context) {
    // 只持有进程级 Application，避免调用方传入 Activity 时延长其生命周期。
    private val ctx = context.applicationContext as android.app.Application

    enum class Kind(val key: String, val uri: Uri) {
        IMAGE("image", MediaStore.Images.Media.EXTERNAL_CONTENT_URI),
        VIDEO("video", MediaStore.Video.Media.EXTERNAL_CONTENT_URI),
        AUDIO("audio", MediaStore.Audio.Media.EXTERNAL_CONTENT_URI);

        companion object {
            fun of(key: String?) = entries.firstOrNull { it.key == key }
        }
    }

    private val cr: ContentResolver = ctx.contentResolver
    private val thumbDir = File(ctx.cacheDir, "thumbs").apply { mkdirs() }

    /** 同时解码的缩略图数量上限，避免几十个请求一起把 CPU 和内存打满。 */
    private val decodeSlots = Semaphore(3)

    private val projection = arrayOf(
        MediaColumns._ID,
        MediaColumns.DISPLAY_NAME,
        MediaColumns.MIME_TYPE,
        MediaColumns.SIZE,
        MediaColumns.DATE_MODIFIED,
        MediaColumns.DATE_ADDED,
        MediaColumns.WIDTH,
        MediaColumns.HEIGHT,
        MediaColumns.DURATION,
        MediaColumns.RELATIVE_PATH,
    )

    private fun projection(kind: Kind) =
        if (kind == Kind.AUDIO) projection else projection + MediaColumns.DATE_TAKEN

    private fun toJson(kind: Kind, c: Cursor) = JSONObject().apply {
        put("id", c.getLong(0))
        put("kind", kind.key)
        put("name", c.getString(1) ?: "")
        put("mime", c.getString(2) ?: "application/octet-stream")
        put("size", c.getLong(3))
        put("modified", c.getLong(4))
        put("added", c.getLong(5))
        // MediaStore 的拍摄时间来自图片 EXIF / 视频元数据，单位是毫秒。
        if (kind != Kind.AUDIO && !c.isNull(10)) {
            val taken = c.getLong(10) / 1000
            if (taken > 0) put("taken", taken)
        }
        if (!c.isNull(6)) put("width", c.getInt(6))
        if (!c.isNull(7)) put("height", c.getInt(7))
        if (!c.isNull(8)) put("duration", c.getLong(8))
        put("path", c.getString(9) ?: "")
    }

    fun list(kind: Kind, offset: Int, limit: Int): JSONObject {
        val args = Bundle()
        args.putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaColumns.DATE_ADDED))
        args.putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
        args.putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
        args.putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
        val items = JSONArray()
        cr.query(kind.uri, projection(kind), args, null)?.use { c ->
            while (c.moveToNext()) items.put(toJson(kind, c))
        }
        // generation：媒体库的「代数」，任何增删改都会变。Mac 据此判断本地保存的列表还能不能直接用
        return JSONObject().put("metadataVersion", 1).put("total", total(kind)).put("generation", generation(kind)).put("items", items)
    }

    private fun generation(kind: Kind): Long =
        // 部分授权可能在媒体库没有增删时变化，不能据代数复用列表或总数。
        if (MediaAccess.full(ctx, kind)) MediaStore.getGeneration(ctx, MediaStore.VOLUME_EXTERNAL_PRIMARY)
        else -android.os.SystemClock.elapsedRealtimeNanos().coerceAtLeast(1L)

    /** 每种媒体的总数，按媒体库「代数」缓存：没有增删就不重新数（一万多张照片数一次要把所有 ID 读一遍） */
    private val totals = HashMap<Kind, Pair<Long, Int>>()

    @Synchronized
    private fun total(kind: Kind): Int {
        val generation = generation(kind)
        totals[kind]?.let { (gen, n) -> if (gen == generation && gen >= 0) return n }
        val n = cr.query(kind.uri, arrayOf(MediaColumns._ID), null, null)?.use { it.count } ?: 0
        totals[kind] = generation to n
        return n
    }

    fun item(kind: Kind, id: Long): JSONObject? =
        cr.query(kind.uri, projection(kind), "${MediaColumns._ID}=?", arrayOf(id.toString()), null)?.use { c ->
            if (c.moveToFirst()) toJson(kind, c) else null
        }

    /**
     * Mac 要删的照片 / 视频：移到「最近删除」（系统回收站，30 天内可恢复），不是彻底删除。
     * 1. 直接标记（本 App 存的文件可以）；
     * 2. 不行就发系统的移到回收站请求：用户给过「媒体管理」权限时系统直接通过，不弹确认；
     * 3. 还是没成功，就发一条通知，用户点一下在系统确认框里确认。
     * 返回已经移走的数量和是否在等用户确认。
     */
    fun trash(targets: List<Pair<Kind, Long>>): Pair<Int, Boolean> {
        val uris = targets.map { (kind, id) -> ContentUris.withAppendedId(kind.uri, id) }
        if (uris.isEmpty()) return 0 to false
        val left = uris.filterNot { uri ->
            try {
                cr.update(uri, ContentValues().apply { put(MediaColumns.IS_TRASHED, 1) }, null, null) > 0
            } catch (_: SecurityException) {
                false
            }
        }
        if (left.isEmpty()) return uris.size to false
        val request = MediaStore.createTrashRequest(cr, left, true)
        if (MediaStore.canManageMedia(ctx)) {
            try {
                val options = android.app.ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(
                    android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
                ).toBundle()
                request.send(ctx, 0, null, null, null, null, options)
            } catch (e: Exception) {
                AppLog.w(TAG, "发送移到回收站请求失败", e)
            }
            // 系统处理是异步的，等它一会儿
            repeat(15) {
                if (left.none { !isTrashed(it) }) return uris.size to false
                Thread.sleep(100)
            }
        }
        val pending = left.count { !isTrashed(it) }
        if (pending > 0) Notifications.confirmTrash(ctx, request, pending)
        return uris.size - pending to (pending > 0)
    }

    private fun isTrashed(uri: Uri): Boolean {
        val args = Bundle().apply { putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE) }
        return cr.query(uri, arrayOf(MediaColumns.IS_TRASHED), args, null)?.use { c ->
            // 查不到（已经被彻底删掉）也算移走了
            !c.moveToFirst() || c.getInt(0) == 1
        } ?: true
    }

    fun open(kind: Kind, id: Long): ParcelFileDescriptor? = try {
        cr.openFileDescriptor(ContentUris.withAppendedId(kind.uri, id), "r")
    } catch (e: Exception) {
        AppLog.w(TAG, "打开文件失败 $kind/$id", e)
        null
    }

    /** 先查磁盘缓存，没有才解码。version 是文件的修改时间，文件被编辑后缓存自然失效。 */
    fun thumbnail(kind: Kind, id: Long, version: Long, size: Int): ByteArray? {
        // 权限收窄后，缓存不能绕过系统对这张照片的访问限制。
        if (!MediaAccess.full(ctx, kind) && open(kind, id)?.use { true } != true) return null
        val file = File(thumbDir, "${kind.key}_${id}_${version}_$size.jpg")
        if (file.length() > 0) return file.readBytes()
        decodeSlots.acquire()
        try {
            if (file.length() > 0) return file.readBytes()
            val bmp = cr.loadThumbnail(ContentUris.withAppendedId(kind.uri, id), Size(size, size), null)
            val bytes = ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
            bmp.recycle()
            val tmp = File(thumbDir, file.name + ".tmp")
            tmp.writeBytes(bytes)
            tmp.renameTo(file)
            return bytes
        } catch (e: Exception) {
            // 录音没有封面、文件损坏等情况，返回空让 Mac 显示占位图
            return null
        } finally {
            decodeSlots.release()
        }
    }

    /** 充电时把最近的照片、视频缩略图提前生成好，Mac 打开相册时直接读缓存。 */
    fun prewarmIfCharging(images: Int = 600, videos: Int = 200) {
        if (!isCharging()) return
        AppLog.i(TAG, "充电中，开始预生成缩略图")
        var made = 0
        for ((kind, n) in listOf(Kind.IMAGE to images, Kind.VIDEO to videos)) {
            val items = list(kind, 0, n).getJSONArray("items")
            for (i in 0 until items.length()) {
                if (!isCharging()) {
                    AppLog.i(TAG, "已拔掉电源，暂停预生成（已完成 $made 张）")
                    return
                }
                val it = items.getJSONObject(i)
                thumbnail(kind, it.getLong("id"), it.getLong("modified"), 256)
                made++
            }
        }
        AppLog.i(TAG, "预生成完成，共 $made 张")
    }

    class NewImage(val json: JSONObject, val added: Long, val isScreenshot: Boolean)

    /** sinceSeconds 之后新增的图片；截图（ColorOS 存在 DCIM/Screenshots/ 或 Pictures/Screenshots/）单独标出。 */
    fun newImages(sinceSeconds: Long): List<NewImage> {
        val result = mutableListOf<NewImage>()
        cr.query(
            Kind.IMAGE.uri, projection(Kind.IMAGE), "${MediaColumns.DATE_ADDED} >= ?", arrayOf(sinceSeconds.toString()),
            "${MediaColumns.DATE_ADDED} ASC",
        )?.use { c ->
            while (c.moveToNext()) {
                val json = toJson(Kind.IMAGE, c)
                val shot = json.getString("path").contains("Screenshot", ignoreCase = true) ||
                    json.getString("name").startsWith("Screenshot", ignoreCase = true)
                result += NewImage(json, c.getLong(5), shot)
            }
        }
        return result
    }

    class Saved(val uri: Uri, val name: String, val mime: String, val dir: String, val json: JSONObject)

    /**
     * 把 Mac 发来的文件存进系统媒体库：图片 → Pictures/ColorLink，视频 → Movies/ColorLink，
     * 音频 → Music/ColorLink，其他 → Download/ColorLink。存自己创建的文件不需要任何权限。
     */
    fun save(name: String, mime: String, input: InputStream, onProgress: (Long) -> Unit = {}): Saved {
        val (collection, dir) = when {
            mime.startsWith("image/") -> Kind.IMAGE.uri to "Pictures/ColorLink"
            mime.startsWith("video/") -> Kind.VIDEO.uri to "Movies/ColorLink"
            mime.startsWith("audio/") -> Kind.AUDIO.uri to "Music/ColorLink"
            else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI to "Download/ColorLink"
        }
        val values = ContentValues().apply {
            put(MediaColumns.DISPLAY_NAME, name)
            put(MediaColumns.MIME_TYPE, mime)
            put(MediaColumns.RELATIVE_PATH, dir)
            put(MediaColumns.IS_PENDING, 1) // 写完之前别让相册看到半个文件
        }
        val uri = cr.insert(collection, values) ?: throw IllegalStateException("无法在媒体库创建文件")
        try {
            cr.openOutputStream(uri)!!.use { out ->
                val buf = ByteArray(64 * 1024)
                var written = 0L
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    written += n
                    onProgress(written)
                }
            }
            cr.update(uri, ContentValues().apply { put(MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            cr.delete(uri, null, null)
            throw e
        }
        val json = JSONObject().put("name", name).put("mime", mime).put("path", "$dir/")
        Kind.entries.firstOrNull { it.uri == collection }?.let { kind ->
            item(kind, ContentUris.parseId(uri))?.let { return Saved(uri, name, mime, dir, it) }
        }
        return Saved(uri, name, mime, dir, json)
    }

    private fun isCharging(): Boolean =
        ctx.getSystemService(BatteryManager::class.java)?.isCharging == true
}
