package com.colorlink

import android.content.ContentResolver
import android.content.ContentValues
import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.MediaStore.MediaColumns
import android.util.Log
import android.util.Size
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.concurrent.Semaphore

private const val TAG = "ColorLink.Media"

/** 通过 MediaStore 读取照片、视频、录音，并维护磁盘缩略图缓存。 */
class MediaRepo(private val ctx: Context) {

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

    private fun toJson(kind: Kind, c: Cursor) = JSONObject().apply {
        put("id", c.getLong(0))
        put("kind", kind.key)
        put("name", c.getString(1) ?: "")
        put("mime", c.getString(2) ?: "application/octet-stream")
        put("size", c.getLong(3))
        put("modified", c.getLong(4))
        put("added", c.getLong(5))
        if (!c.isNull(6)) put("width", c.getInt(6))
        if (!c.isNull(7)) put("height", c.getInt(7))
        if (!c.isNull(8)) put("duration", c.getLong(8))
        put("path", c.getString(9) ?: "")
    }

    fun list(kind: Kind, offset: Int, limit: Int): JSONObject {
        val args = Bundle()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            args.putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaColumns.DATE_ADDED))
            args.putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            args.putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
            args.putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
        } else {
            // Android 10 的 MediaProvider 不认 LIMIT/OFFSET 参数，只能拼进排序语句
            args.putString(
                ContentResolver.QUERY_ARG_SQL_SORT_ORDER,
                "${MediaColumns.DATE_ADDED} DESC LIMIT $limit OFFSET $offset",
            )
        }
        val items = JSONArray()
        cr.query(kind.uri, projection, args, null)?.use { c ->
            while (c.moveToNext()) items.put(toJson(kind, c))
        }
        val total = cr.query(kind.uri, arrayOf(MediaColumns._ID), null, null)?.use { it.count } ?: 0
        return JSONObject().put("total", total).put("items", items)
    }

    fun item(kind: Kind, id: Long): JSONObject? =
        cr.query(kind.uri, projection, "${MediaColumns._ID}=?", arrayOf(id.toString()), null)?.use { c ->
            if (c.moveToFirst()) toJson(kind, c) else null
        }

    fun open(kind: Kind, id: Long): ParcelFileDescriptor? = try {
        cr.openFileDescriptor(ContentUris.withAppendedId(kind.uri, id), "r")
    } catch (e: Exception) {
        Log.w(TAG, "打开文件失败 $kind/$id", e)
        null
    }

    /** 先查磁盘缓存，没有才解码。version 是文件的修改时间，文件被编辑后缓存自然失效。 */
    fun thumbnail(kind: Kind, id: Long, version: Long, size: Int): ByteArray? {
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
        Log.i(TAG, "充电中，开始预生成缩略图")
        var made = 0
        for ((kind, n) in listOf(Kind.IMAGE to images, Kind.VIDEO to videos)) {
            val items = list(kind, 0, n).getJSONArray("items")
            for (i in 0 until items.length()) {
                if (!isCharging()) {
                    Log.i(TAG, "已拔掉电源，暂停预生成（已完成 $made 张）")
                    return
                }
                val it = items.getJSONObject(i)
                thumbnail(kind, it.getLong("id"), it.getLong("modified"), 256)
                made++
            }
        }
        Log.i(TAG, "预生成完成，共 $made 张")
    }

    class NewImage(val json: JSONObject, val added: Long, val isScreenshot: Boolean)

    /** sinceSeconds 之后新增的图片；截图（ColorOS 存在 DCIM/Screenshots/ 或 Pictures/Screenshots/）单独标出。 */
    fun newImages(sinceSeconds: Long): List<NewImage> {
        val result = mutableListOf<NewImage>()
        cr.query(
            Kind.IMAGE.uri, projection, "${MediaColumns.DATE_ADDED} >= ?", arrayOf(sinceSeconds.toString()),
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
    fun save(name: String, mime: String, input: InputStream): Saved {
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
            cr.openOutputStream(uri)!!.use { out -> input.copyTo(out, 64 * 1024) }
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
