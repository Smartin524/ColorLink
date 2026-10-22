package com.colorlink

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import kotlin.concurrent.thread

private const val TAG = "ColorLink.Share"

/**
 * 分享菜单里的「发送到 Mac」：
 * - 图片、文件（一个或多个）：Mac 收下后存进「图片 / 下载」的 ColorLink 文件夹并复制到剪贴板；
 * - 文字：直接放进 Mac 剪贴板（安卓 10 以后后台 App 读不到剪贴板，只能这样主动发）。
 * Mac 没连着时先敲门，等几秒它连上再发。
 */
class ShareActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LinkCore.start(this)
        val uris = streams(intent)
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (uris.isEmpty() && text.isNullOrEmpty()) {
            done("没有可发送的内容")
            return
        }
        // 复制文件要在界面结束前做完：别的 App 给的读取权限随界面一起失效。
        // 复制完立刻关掉这个透明界面（它盖在屏幕上会挡住操作），等 Mac、发送都在后台做
        val app = applicationContext
        thread(name = "share") {
            val files = uris.mapNotNull { SharedFiles.add(app, it, intent.type) }
            main.post { finish() }
            if (!waitForMac()) {
                done("Mac 未连接")
                return@thread
            }
            val msg = if (files.isNotEmpty()) {
                EventBus.publish("shared", JSONObject().put("items", JSONArray(files.map { it.json })))
                AppLog.i(TAG, "分享 ${files.size} 个文件到 Mac")
                if (files.size < uris.size) "已发送 ${files.size} 个，${uris.size - files.size} 个读取失败" else "已发送到 Mac"
            } else if (!text.isNullOrEmpty()) {
                EventBus.publish("clipboard", JSONObject().put("text", text))
                "已发送到 Mac 剪贴板"
            } else {
                "读取分享的内容失败"
            }
            done(msg)
        }
    }

    private fun streams(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
        Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        else -> emptyList()
    }

    /** Mac 没连着时敲门，最多等 5 秒 */
    private fun waitForMac(): Boolean {
        if (EventBus.count > 0) return true
        main.post { Toast.makeText(applicationContext, "正在连接 Mac…", Toast.LENGTH_SHORT).show() }
        LinkCore.knockSoon(force = true)
        val deadline = SystemClock.elapsedRealtime() + 5_000
        while (SystemClock.elapsedRealtime() < deadline) {
            if (EventBus.count > 0) return true
            Thread.sleep(100)
        }
        return EventBus.count > 0
    }

    private fun done(msg: String) {
        main.post {
            Toast.makeText(applicationContext, msg, Toast.LENGTH_SHORT).show()
            if (!isFinishing) finish()
        }
    }
}
