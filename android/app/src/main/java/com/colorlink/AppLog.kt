package com.colorlink

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * 日志：同时写 logcat 和文件。ColorOS 上 logcat 很快被冲掉，事后排查要靠文件。
 * 文件在 files/logs/colorlink.log，超过 1 MB 轮换成 colorlink.1.log，最多占 2 MB。
 * Mac 可以通过 /api/logs 取走，状态栏菜单「导出诊断日志」会用到。
 */
object AppLog {
    private const val MAX_BYTES = 1L shl 20
    private val writer = Executors.newSingleThreadExecutor()
    private val time = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.ROOT)

    @Volatile
    private var dir: File? = null

    fun init(ctx: Context) {
        if (dir == null) dir = File(ctx.applicationContext.filesDir, "logs").apply { mkdirs() }
    }

    fun i(tag: String, msg: String) {
        Log.i(tag, msg)
        append("I", tag, msg)
    }

    fun w(tag: String, msg: String, e: Throwable? = null) {
        Log.w(tag, msg, e)
        append("W", tag, if (e == null) msg else "$msg：$e")
    }

    private fun append(level: String, tag: String, msg: String) {
        val d = dir ?: return
        val line = "${time.format(Date())} $level ${tag.removePrefix("ColorLink.")}: $msg\n"
        writer.execute {
            runCatching {
                val f = File(d, "colorlink.log")
                if (f.length() > MAX_BYTES) f.renameTo(File(d, "colorlink.1.log"))
                f.appendText(line)
            }
        }
    }

    /** 旧的在前、新的在后，供 /api/logs 返回。 */
    fun dump(): String {
        val d = dir ?: return ""
        return listOf("colorlink.1.log", "colorlink.log")
            .map { File(d, it) }
            .filter { it.exists() }
            .joinToString("") { it.readText() }
    }
}
