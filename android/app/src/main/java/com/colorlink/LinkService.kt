package com.colorlink

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.os.IBinder

private const val TAG = "ColorLink.Service"

/**
 * 前台服务，只在需要时运行，通知栏里的那条通知就是它：
 * - Mac 刚连上的几秒：通知显示成流体云（左边彩色链环，右边「已连接」）；
 * - 之后一直连着：降级成普通常驻通知「已连接 xxx」，断开后消失；
 * - 用户打开了「空闲时也用前台服务保活」，或没开通知使用权时：一条折叠的静默通知。
 * 其余时间（空闲且通知监听在保活）它不运行，通知栏里什么都没有。
 *
 * 类型用 connectedDevice 而不是 dataSync：Android 15 起 dataSync 每天最多只能跑 6 小时。
 */
class LinkService : Service() {

    companion object {
        /** 现在需不需要前台服务：连着 Mac、用户要求常驻、或者没有通知监听保活。 */
        fun needed(ctx: Context) = Prefs.connectionEnabled(ctx) &&
            (EventBus.count > 0 || Prefs.keepAlive(ctx) || !NotifyListener.connected)

        private fun state() = when {
            EventBus.count == 0 -> Notifications.LinkState.IDLE
            LinkCore.announcing -> Notifications.LinkState.ANNOUNCING
            else -> Notifications.LinkState.CONNECTED
        }

        /** 根据当前状态启动或停止前台服务。随时可以调用。 */
        fun refresh(ctx: Context) {
            if (needed(ctx)) {
                try {
                    ctx.startForegroundService(Intent(ctx, LinkService::class.java))
                } catch (e: Exception) {
                    // Android 12+ 不允许从后台随意启动前台服务；忽略电池优化后就没有这个限制
                    AppLog.w(TAG, "无法启动前台服务（是否已忽略电池优化？）", e)
                }
            } else {
                stop(ctx)
            }
        }

        // stopService 按显式组件匹配，不要求同一个 Intent 实例；这里不是 SAM 监听器。
        @android.annotation.SuppressLint("ImplicitSamInstance")
        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, LinkService::class.java))
        }
    }

    private var shown: Notifications.LinkState? = null
    private var night = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (!Prefs.connectionEnabled(this)) {
            stopSelf()
            return
        }
        LinkCore.start(this)
        night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        show()
    }

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    /**
     * 深浅色切换后重发通知：通知栏里的 App 图标是发通知那一刻按当时的深浅色取的，
     * 不重发的话夜里发的通知白天还是深色图标。
     * 不能一收到切换就发：那时通知栏（SystemUI）往往还没切过去，会又取到旧主题的图标，看起来就像深浅配反了。
     * 所以等几秒再发，发两次保险。流体云弹出期间不动它，几秒后降级时自然会重发
     */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val now = newConfig.uiMode and Configuration.UI_MODE_NIGHT_MASK
        if (now == night) return
        night = now
        AppLog.i(TAG, "切换到${if (now == Configuration.UI_MODE_NIGHT_YES) "深色" else "浅色"}，稍后重发通知刷新图标")
        handler.removeCallbacksAndMessages(null)
        for (delay in longArrayOf(2_000, 6_000)) {
            handler.postDelayed({
                val state = shown ?: return@postDelayed
                if (state == Notifications.LinkState.ANNOUNCING) return@postDelayed
                getSystemService(NotificationManager::class.java).notify(Notifications.ID_LINK, Notifications.link(this, state))
            }, delay)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!Prefs.connectionEnabled(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        show()
        // 兜底：启动请求发出后情况可能已经变了（例如通知监听刚绑定好），不需要就自己退出
        if (!needed(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        // 只有用户要求常驻时，被系统杀掉后才自动重启
        return if (Prefs.keepAlive(this)) START_STICKY else START_NOT_STICKY
    }

    /**
     * 状态变了才更新通知。刚连上时先撤掉再发，流体云才会播放弹出动画；
     * 之后降级成普通常驻通知时直接原地更新，不打扰。
     */
    private fun show() {
        val state = state()
        if (state == shown) return
        AppLog.i(TAG, "前台服务通知：$state")
        val notification = Notifications.link(this, state)
        if (shown == null || state == Notifications.LinkState.ANNOUNCING) {
            if (shown != null) stopForeground(STOP_FOREGROUND_REMOVE)
            startForeground(Notifications.ID_LINK, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            getSystemService(NotificationManager::class.java).notify(Notifications.ID_LINK, notification)
        }
        shown = state
    }

    // 核心（LinkCore）留在进程里继续运行，由通知监听保活
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        AppLog.i(TAG, "前台服务已停止，通知栏不再显示")
        super.onDestroy()
    }
}
