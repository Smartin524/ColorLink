package com.colorlink

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "ColorLink.Share"

/**
 * 从分享菜单「发送到 Mac」发出去的文件。
 *
 * 别的 App 分享给我们的读取权限只在分享界面存活期间有效，所以先复制进缓存，再通知 Mac 来取
 * （GET /api/shared?id=）。一小时后自动清掉。
 */
object SharedFiles {
    private const val KEEP_MS = 60 * 60_000L

    class Entry(val id: String, val file: File, val name: String, val mime: String) {
        val json: JSONObject get() = JSONObject().put("id", id).put("name", name).put("mime", mime).put("size", file.length())
    }

    private val entries = ConcurrentHashMap<String, Entry>()

    private fun dir(ctx: Context) = File(ctx.cacheDir, "shared").apply { mkdirs() }

    /** 复制一份分享来的内容；读不到返回 null */
    fun add(ctx: Context, uri: Uri, fallbackMime: String?): Entry? {
        cleanUp(ctx)
        val cr = ctx.contentResolver
        val name = runCatching {
            cr.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        }.getOrNull() ?: uri.lastPathSegment?.substringAfterLast('/') ?: "分享的文件"
        val mime = cr.getType(uri)?.takeIf { it.contains('/') && !it.endsWith("/*") }
            ?: fallbackMime?.takeIf { it.contains('/') && !it.endsWith("/*") }
            ?: java.net.URLConnection.guessContentTypeFromName(name)
            ?: "application/octet-stream"
        val id = UUID.randomUUID().toString()
        val file = File(dir(ctx), id)
        return try {
            cr.openInputStream(uri)?.use { input -> file.outputStream().use { input.copyTo(it) } } ?: return null
            Entry(id, file, name, mime).also { entries[id] = it }
        } catch (e: Exception) {
            AppLog.w(TAG, "读取分享的内容失败", e)
            file.delete()
            null
        }
    }

    fun get(id: String): Entry? = entries[id]?.takeIf { it.file.exists() }

    private fun cleanUp(ctx: Context) {
        val cutoff = System.currentTimeMillis() - KEEP_MS
        dir(ctx).listFiles()?.filter { it.lastModified() < cutoff }?.forEach {
            entries.remove(it.name)
            it.delete()
        }
    }
}
