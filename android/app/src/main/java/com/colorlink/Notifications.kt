package com.colorlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.provider.Settings
import android.util.Size

private const val TAG = "ColorLink.Notify"

object Notifications {
    const val ID_LINK = 1

    private const val CH_IDLE = "idle"
    private const val CH_CONNECTED = "connected"
    private const val CH_LINKED = "linked"
    private const val CH_RECEIVED = "received"

    private fun createChannels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            // MIN：折叠在通知栏最底部，状态栏不显示图标，不响不振
            NotificationChannel(CH_IDLE, "待命（保活）", NotificationManager.IMPORTANCE_MIN).apply {
                description = "没连电脑时让 ColorLink 保持运行，折叠显示、不打扰"
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            // 实况通知（流体云）要求重要性高于 MIN；用 DEFAULT 但不响不振，避免再弹一条横幅
            NotificationChannel(CH_CONNECTED, "已连接电脑（流体云）", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "连上 Mac 时显示，断开后自动消失"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_LINKED, "已连接电脑（常驻）", NotificationManager.IMPORTANCE_LOW).apply {
                description = "连着 Mac 期间一直显示，断开后自动消失"
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_RECEIVED, "收到的文件", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Mac 发来图片或文件时提醒"
            },
        )
    }

    private fun openApp(ctx: Context) = PendingIntent.getActivity(
        ctx, 0, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
    )

    enum class LinkState {
        /** 没连电脑（只在要求常驻或没有通知监听时出现）：折叠的静默通知 */
        IDLE,
        /** 刚连上的几秒：流体云 */
        ANNOUNCING,
        /** 连着电脑：普通常驻通知 */
        CONNECTED,
    }

    /** 前台服务的通知 */
    fun link(ctx: Context, state: LinkState): Notification {
        createChannels(ctx)
        if (state == LinkState.IDLE) {
            return Notification.Builder(ctx, CH_IDLE)
                .setSmallIcon(R.drawable.ic_link)
                .setContentTitle("ColorLink 待命中")
                .setContentText("等待电脑连接")
                .setShowWhen(false)
                .setContentIntent(openApp(ctx))
                .setOngoing(true)
                .build()
        }
        val mac = LinkCore.macName ?: "Mac"
        val announcing = state == LinkState.ANNOUNCING
        val b = Notification.Builder(ctx, if (announcing) CH_CONNECTED else CH_LINKED)
            .setSmallIcon(R.drawable.ic_mac) // 流体云胶囊左边的图标
            .setContentTitle("已连接 $mac")
            .setContentText("可以在 Mac 上浏览照片、接收截图和文件")
            .setContentIntent(openApp(ctx))
            .setCategory(Notification.CATEGORY_STATUS)
            .setOngoing(true)
        if (announcing) LiveUpdate.apply(ctx, b, shortText = "已连接")
        return b.build()
    }

    /** Mac 发来了文件。图片带大图预览，点一下用相册打开。 */
    fun received(ctx: Context, saved: MediaRepo.Saved) {
        createChannels(ctx)
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(saved.uri, saved.mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        val b = Notification.Builder(ctx, CH_RECEIVED)
            .setSmallIcon(R.drawable.ic_mac)
            .setContentTitle("收到 ${LinkCore.macName ?: "Mac"} 发来的${if (saved.mime.startsWith("image/")) "图片" else "文件"}")
            .setContentText("${saved.name} · 已保存到 ${saved.dir}")
            .setContentIntent(PendingIntent.getActivity(ctx, saved.uri.hashCode(), view, PendingIntent.FLAG_IMMUTABLE))
            .setAutoCancel(true)
        if (saved.mime.startsWith("image/")) {
            runCatching { ctx.contentResolver.loadThumbnail(saved.uri, Size(1024, 1024), null) }
                .getOrNull()
                ?.let { b.setStyle(Notification.BigPictureStyle().bigPicture(it)).setLargeIcon(it) }
        }
        ctx.getSystemService(NotificationManager::class.java).notify(saved.uri.hashCode(), b.build())
    }

    /** 打开本 App 的通知设置（用户在这里开关实况通知 / 流体云）。 */
    fun openSettings(ctx: Context) {
        ctx.startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName),
        )
    }
}

/**
 * Android 16 的实况通知（Live Updates）。ColorOS 16 起会把它显示成流体云。
 *
 * 这些接口在 Android 16 QPR1（API 36.1）才加入，而项目用 compileSdk 35 编译
 * （当前的 Gradle 插件还不认 android-37.0 这种带小版本号的 SDK），所以通过反射调用。
 * 它们都是公开 API，不是隐藏接口；低版本系统上直接跳过，退化成普通通知。
 */
object LiveUpdate {
    private const val GREEN = 0xFF34C759.toInt()

    /** null 表示系统不支持实况通知；false 表示用户在通知设置里关掉了。 */
    fun canPromote(ctx: Context): Boolean? {
        if (Build.VERSION.SDK_INT < 36) return null
        return try {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            NotificationManager::class.java.getMethod("canPostPromotedNotifications").invoke(nm) as Boolean
        } catch (_: Exception) {
            null
        }
    }

    fun apply(ctx: Context, b: Notification.Builder, shortText: String) {
        if (Build.VERSION.SDK_INT < 36) return
        // 一条满格的绿色进度条：左端 Mac 图标，右端绿灯
        try {
            val styleCls = Class.forName("android.app.Notification\$ProgressStyle")
            val segCls = Class.forName("android.app.Notification\$ProgressStyle\$Segment")
            val segment = segCls.getConstructor(Int::class.javaPrimitiveType).newInstance(100)
            segCls.getMethod("setColor", Int::class.javaPrimitiveType).invoke(segment, GREEN)
            val style = styleCls.getConstructor().newInstance()
            styleCls.getMethod("setProgressSegments", List::class.java).invoke(style, listOf(segment))
            styleCls.getMethod("setProgress", Int::class.javaPrimitiveType).invoke(style, 100)
            styleCls.getMethod("setProgressStartIcon", Icon::class.java)
                .invoke(style, Icon.createWithResource(ctx, R.drawable.ic_mac))
            styleCls.getMethod("setProgressEndIcon", Icon::class.java)
                .invoke(style, Icon.createWithResource(ctx, R.drawable.ic_dot_green))
            b.setStyle(style as Notification.Style)
        } catch (e: Exception) {
            AppLog.w(TAG, "ProgressStyle 不可用，用普通样式", e)
        }
        try {
            val cls = Notification.Builder::class.java
            cls.getMethod("setShortCriticalText", String::class.java).invoke(b, shortText) // 胶囊里的文字
            cls.getMethod("setRequestPromotedOngoing", Boolean::class.javaPrimitiveType).invoke(b, true)
        } catch (_: Exception) {
            // Android 16.0（没有 QPR1）只认 extras
            b.extras.putBoolean("android.requestPromotedOngoing", true)
        }
    }
}
