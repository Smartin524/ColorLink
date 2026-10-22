package com.colorlink

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import org.json.JSONObject

/**
 * 分享菜单里的「发送到 Mac」。安卓 10 以后后台 App 读不到剪贴板，
 * 所以手机 → Mac 的文字只能这样主动发一下。
 */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val msg = when {
            text.isNullOrEmpty() -> "没有可发送的文字"
            EventBus.count == 0 -> "Mac 未连接"
            else -> {
                EventBus.publish("clipboard", JSONObject().put("text", text))
                "已发送到 Mac 剪贴板"
            }
        }
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
        finish()
    }
}
