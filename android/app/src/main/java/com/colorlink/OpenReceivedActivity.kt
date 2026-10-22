package com.colorlink

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * 点「已收到」流体云时经过这里：撤掉通知（实况通知必须常驻，不能靠 autoCancel），再打开收到的文件或文件夹。
 * 没有界面，立刻结束。
 */
class OpenReceivedActivity : Activity() {
    companion object {
        const val EXTRA_TARGET = "target"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Notifications.dismissTransfer(this)
        val target = intent.getParcelableExtra(EXTRA_TARGET, Intent::class.java)
        if (target != null) {
            try {
                startActivity(target)
            } catch (e: Exception) {
                AppLog.w("ColorLink.Open", "打不开收到的文件", e)
                // 文件管理不认文件夹链接时，退回打开 App
                startActivity(Intent(this, MainActivity::class.java))
            }
        }
        finish()
    }
}
