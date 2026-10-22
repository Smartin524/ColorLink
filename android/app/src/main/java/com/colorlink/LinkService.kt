package com.colorlink

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log

private const val TAG = "ColorLink.Service"

/**
 * 前台服务，只在需要时运行，通知栏里的那条通知就是它：
 * - Mac 连着时：通知显示成流体云（左边 Mac 图标、右边绿灯）；
 * - 用户打开了「空闲时也用前台服务保活」，或没开通知使用权时：一条折叠的静默通知。
 * 其余时间（空闲且通知监听在保活）它不运行，通知栏里什么都没有。
 *
 * 类型用 connectedDevice 而不是 dataSync：Android 15 起 dataSync 每天最多只能跑 6 小时。
 */
class LinkService : Service() {

    companion object {
        /** 现在需不需要前台服务：有 Mac 连着、用户要求常驻、或者没有通知监听保活。 */
        fun needed(ctx: Context) = EventBus.count > 0 || Prefs.keepAlive(ctx) || !NotifyListener.connected

        /** 根据当前状态启动或停止前台服务。随时可以调用。 */
        fun refresh(ctx: Context) {
            if (needed(ctx)) {
                try {
                    ctx.startForegroundService(Intent(ctx, LinkService::class.java))
                } catch (e: Exception) {
                    // Android 12+ 不允许从后台随意启动前台服务；忽略电池优化后就没有这个限制
                    Log.w(TAG, "无法启动前台服务（是否已忽略电池优化？）", e)
                }
            } else {
                ctx.stopService(Intent(ctx, LinkService::class.java))
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, LinkService::class.java))
        }
    }

    private var shownConnected: Boolean? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        LinkCore.start(this)
        show()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        show()
        // 兜底：启动请求发出后情况可能已经变了（例如通知监听刚绑定好），不需要就自己退出
        if (!needed(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        // 只有用户要求常驻时，被系统杀掉后才自动重启
        return if (Prefs.keepAlive(this)) START_STICKY else START_NOT_STICKY
    }

    /** 状态变了才重新发通知：先撤掉再发，流体云才会重新播放弹出动画。 */
    private fun show() {
        val connected = EventBus.count > 0
        if (connected == shownConnected) return
        if (shownConnected != null) stopForeground(STOP_FOREGROUND_REMOVE)
        startForeground(
            Notifications.ID_LINK,
            Notifications.link(this, connected),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        shownConnected = connected
    }

    // 核心（LinkCore）留在进程里继续运行，由通知监听保活
    override fun onDestroy() = super.onDestroy()
}
