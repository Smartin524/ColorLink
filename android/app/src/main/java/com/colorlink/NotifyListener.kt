package com.colorlink

import android.app.AutomaticZenRule
import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.provider.Settings
import android.provider.Telephony
import android.service.notification.Condition
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject

private const val TAG = "ColorLink.Notify"

/**
 * 通知同步：把手机上会响的通知转发给 Mac（微信除外；短信由 Mac 端识别并复制验证码），
 * 以及免打扰的远程开关。它还承担保活：系统绑定着它，进程就能一直活着，连接核心（LinkCore）在空闲时
 * 不用开前台服务、通知栏不显示任何东西；进程被杀后系统通常会重新绑定，相当于自带复活。
 */
class NotifyListener : NotificationListenerService() {

    companion object {
        /** 系统当前是否绑定着我们。ColorOS 上偶尔会出现“开关开着但没绑定”的情况。 */
        @Volatile
        var connected = false
            private set

        /** 绑定着的那个实例，免打扰开关要通过它调系统 */
        @Volatile
        private var instance: NotifyListener? = null

        /** 常见短信 App；再加上系统当前的默认短信 App。短信要标出来，Mac 只在短信里找验证码 */
        private val SMS_PACKAGES = setOf(
            "com.android.mms", // ColorOS 自带信息
            "com.oplus.mms",
            "com.coloros.mms",
            "com.google.android.apps.messaging",
            "com.samsung.android.messaging",
        )

        /** 不转发的 App：微信（消息太多、电脑上多半也登着），以及系统和自己 */
        private val MUTED_PACKAGES = setOf(
            "com.tencent.mm",
            "android",
            "com.android.systemui",
        )

        /** 免打扰档位 ↔ 协议里的名字 */
        private val DND_MODES = mapOf(
            NotificationListenerService.INTERRUPTION_FILTER_ALL to "all",
            NotificationListenerService.INTERRUPTION_FILTER_PRIORITY to "priority",
            NotificationListenerService.INTERRUPTION_FILTER_ALARMS to "alarms",
            NotificationListenerService.INTERRUPTION_FILTER_NONE to "none",
        )

        /** 当前免打扰档位；通知监听没绑定时为 null（没开通知使用权就改不了免打扰） */
        fun dndMode(): String? = instance?.let { DND_MODES[it.currentInterruptionFilter] }

        /**
         * 改免打扰档位。通知监听服务本身就有这个权限，不用再要「勿扰权限」。
         * 返回 false 表示没绑定或档位名不对。系统改完会回调 onInterruptionFilterChanged，由它推事件给 Mac。
         *
         * 不用 requestInterruptionFilter：targetSdk 35 起它不再改系统的勿扰，而是给本应用建一个隐式的「模式」，
         * ColorOS 上实测没有任何效果。改成自己建一个名为 ColorLink 的勿扰规则，开关它的状态。
         * 所以 Mac 上只能关掉自己开的这个；手机上手动开的勿扰，Mac 关不掉
         */
        fun setDndMode(mode: String): Boolean {
            val filter = DND_MODES.entries.firstOrNull { it.value == mode }?.key ?: return false
            val l = instance ?: return false
            AppLog.i(TAG, "Mac 把免打扰改为 $mode")
            val nm = l.getSystemService(NotificationManager::class.java)
            val on = filter != NotificationListenerService.INTERRUPTION_FILTER_ALL
            val id = if (on) ensureRule(l, nm, filter) else Prefs.sp(l).getString("dndRule", null)
            if (id != null) {
                nm.setAutomaticZenRuleState(id, Condition(DND_RULE_URI, "Mac 远程开关", if (on) Condition.STATE_TRUE else Condition.STATE_FALSE))
            }
            return true
        }

        private val DND_RULE_URI = Uri.parse("colorlink://dnd")

        /** 找到（或新建）自己的勿扰规则，档位改成 filter，返回规则 ID */
        private fun ensureRule(ctx: Context, nm: NotificationManager, filter: Int): String {
            val p = Prefs.sp(ctx)
            val rule = AutomaticZenRule(
                "ColorLink", null, ComponentName(ctx, MainActivity::class.java), DND_RULE_URI, null, filter, true,
            )
            p.getString("dndRule", null)?.let { id ->
                // 用户可能在系统设置里删了它
                if (nm.getAutomaticZenRule(id) != null && nm.updateAutomaticZenRule(id, rule)) return id
            }
            return nm.addAutomaticZenRule(rule).also {
                p.edit().putString("dndRule", it).apply()
                AppLog.i(TAG, "已建勿扰规则 ColorLink")
            }
        }

        /** 改完没生效时记一下规则的状态，方便查原因 */
        fun logDndRule() {
            val l = instance ?: return
            val nm = l.getSystemService(NotificationManager::class.java)
            val id = Prefs.sp(l).getString("dndRule", null)
            val rule = id?.let { nm.getAutomaticZenRule(it) }
            AppLog.w(
                TAG,
                "免打扰没改成：当前 ${dndMode()}，规则 ${if (rule == null) "无" else "enabled=${rule.isEnabled} state=${nm.getAutomaticZenRuleState(id)}"}",
            )
        }

        fun enabled(ctx: Context): Boolean =
            Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
                ?.contains(ctx.packageName) == true

        /** 主动关闭连接时解绑，保留系统授予的通知使用权。 */
        fun pause() {
            instance?.requestUnbind()
            instance = null
            connected = false
        }

        /** 总开关和通知使用权都开启时，才恢复监听。 */
        fun rebindIfNeeded(ctx: Context) {
            if (Prefs.connectionEnabled(ctx) && !connected && enabled(ctx)) {
                AppLog.i(TAG, "通知监听未绑定，请求系统重新绑定")
                requestRebind(ComponentName(ctx, NotifyListener::class.java))
            }
        }
    }

    override fun onListenerConnected() {
        if (!Prefs.connectionEnabled(this)) {
            requestUnbind()
            return
        }
        connected = true
        instance = this
        AppLog.init(this)
        AppLog.i(TAG, "通知监听已绑定")
        LinkCore.start(this)
        BleWake.update(this)
        // 进程有了保活的依靠，空闲时就不需要前台服务了。前台服务可能正在启动，过一会儿再复查一次
        LinkService.refresh(this)
        android.os.Handler(mainLooper).postDelayed({ LinkService.refresh(this) }, 3_000)
    }

    override fun onListenerDisconnected() {
        connected = false
        instance = null
        AppLog.w(TAG, "通知监听被解绑，请求重新绑定")
        if (Prefs.connectionEnabled(this)) requestRebind(ComponentName(this, NotifyListener::class.java))
        // 失去保活依靠，先用前台服务顶上
        LinkService.refresh(this)
    }

    /** 手机上（或 Mac 上）改了免打扰，告诉 Mac 面板上的开关跟着变 */
    override fun onInterruptionFilterChanged(filter: Int) {
        val mode = DND_MODES[filter] ?: return
        AppLog.i(TAG, "免打扰档位：$mode")
        if (EventBus.count > 0) EventBus.publish("dnd", JSONObject().put("mode", mode))
    }

    /** 同一条通知可能被系统重复投递（例如被更新、被标为已读），2 分钟内同样内容只转发一次。 */
    private val recentlySent = LinkedHashMap<String, Long>()

    private fun isSmsApp(pkg: String): Boolean =
        pkg in SMS_PACKAGES || pkg == runCatching { Telephony.Sms.getDefaultSmsPackage(this) }.getOrNull()

    /** 这条通知在手机上会不会响：静默通道（音乐播放、下载进度、后台提示）不值得发到 Mac */
    private fun wouldAlert(sbn: StatusBarNotification): Boolean {
        val ranking = NotificationListenerService.Ranking()
        if (!currentRanking.getRanking(sbn.key, ranking)) return true // 查不到就当会响
        return ranking.importance >= NotificationManager.IMPORTANCE_DEFAULT
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!Prefs.connectionEnabled(this) || EventBus.count == 0) return
        val pkg = sbn.packageName
        if (pkg in MUTED_PACKAGES || pkg == packageName || sbn.isOngoing) return
        val n = sbn.notification
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (!wouldAlert(sbn)) return

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
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Exception) {
            pkg
        }

        // 日志里不记通知内容
        AppLog.i(TAG, "转发通知给 Mac（$pkg，${text.length} 字）")
        EventBus.publish(
            "notification",
            JSONObject()
                .put("key", sbn.key)
                .put("pkg", pkg)
                .put("app", app)
                .put("sms", isSmsApp(pkg))
                .put("title", title)
                .put("text", text)
                .put("time", sbn.postTime),
        )
    }
}
