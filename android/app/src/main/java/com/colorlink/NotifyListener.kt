package com.colorlink

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject

/**
 * 短信同步（只转发短信 App 的通知，Mac 端会自动识别并复制验证码）。它还承担保活：系统绑定着它，进程就能一直活着，连接核心（LinkCore）在空闲时
 * 不用开前台服务、通知栏不显示任何东西；进程被杀后系统通常会重新绑定，相当于自带复活。
 */
class NotifyListener : NotificationListenerService() {

    companion object {
        /** 系统当前是否绑定着我们。ColorOS 上偶尔会出现“开关开着但没绑定”的情况。 */
        @Volatile
        var connected = false
            private set

        /** 常见短信 App；再加上系统当前的默认短信 App。 */
        private val SMS_PACKAGES = setOf(
            "com.android.mms", // ColorOS 自带信息
            "com.oplus.mms",
            "com.coloros.mms",
            "com.google.android.apps.messaging",
            "com.samsung.android.messaging",
        )

        fun enabled(ctx: Context): Boolean =
            Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
                ?.contains(ctx.packageName) == true

        /** 开关开着却没绑定时，请系统重新绑定。 */
        fun rebindIfNeeded(ctx: Context) {
            if (!connected && enabled(ctx)) {
                AppLog.i("ColorLink.Notify", "通知监听未绑定，请求系统重新绑定")
                requestRebind(ComponentName(ctx, NotifyListener::class.java))
            }
        }
    }

    override fun onListenerConnected() {
        connected = true
        AppLog.init(this)
        AppLog.i("ColorLink.Notify", "通知监听已绑定")
        BleWake.register(this)
        LinkCore.start(this)
        // 进程有了保活的依靠，空闲时就不需要前台服务了。前台服务可能正在启动，过一会儿再复查一次
        LinkService.refresh(this)
        android.os.Handler(mainLooper).postDelayed({ LinkService.refresh(this) }, 3_000)
    }

    override fun onListenerDisconnected() {
        connected = false
        AppLog.w("ColorLink.Notify", "通知监听被解绑，请求重新绑定")
        requestRebind(ComponentName(this, NotifyListener::class.java))
        // 失去保活依靠，先用前台服务顶上
        LinkService.refresh(this)
    }

    /** 同一条短信通知可能被系统重复投递（例如被更新、被标为已读），2 分钟内同样内容只转发一次。 */
    private val recentlySent = LinkedHashMap<String, Long>()

    private fun isSmsApp(pkg: String): Boolean =
        pkg in SMS_PACKAGES || pkg == runCatching { Telephony.Sms.getDefaultSmsPackage(this) }.getOrNull()

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (EventBus.count == 0) return
        // 只同步短信：电脑上主要是用来看验证码，其他通知不发出手机
        if (!isSmsApp(sbn.packageName) || sbn.isOngoing) return
        val n = sbn.notification
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return

        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: return
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString() ?: ""
        val now = System.currentTimeMillis()
        val dedupKey = "${sbn.key}|$title|$text"
        synchronized(recentlySent) {
            recentlySent.entries.removeAll { now - it.value > 120_000 }
            if (recentlySent.containsKey(dedupKey)) return
            recentlySent[dedupKey] = now
        }
        val app = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
        } catch (_: Exception) {
            sbn.packageName
        }

        // 日志里不记短信内容
        AppLog.i("ColorLink.Notify", "转发短信给 Mac（${sbn.packageName}，${text.length} 字）")
        EventBus.publish(
            "notification",
            JSONObject()
                .put("key", sbn.key)
                .put("pkg", sbn.packageName)
                .put("app", app)
                .put("title", title)
                .put("text", text)
                .put("time", sbn.postTime),
        )
    }
}
