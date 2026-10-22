package com.colorlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Size

private const val TAG = "ColorLink.Notify"

object Notifications {
    const val ID_LINK = 1
    private const val ID_TRANSFER = 2
    private const val ID_TRASH = 3
    private val main = android.os.Handler(android.os.Looper.getMainLooper())

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

    /**
     * 流体云左边的彩色链环（静态图）。ColorOS 会把图标裁成圆形，斜放的链环两端会被切掉，
     * 所以画小一点、四周留白，让它整个落在圆里。
     */
    private var chain: android.graphics.drawable.Icon? = null
    private fun chainIcon(ctx: Context): android.graphics.drawable.Icon = chain ?: run {
        val px = (48 * ctx.resources.displayMetrics.density).toInt()
        val inner = (px * 0.68f).toInt()
        val bmp = android.graphics.Bitmap.createBitmap(px, px, android.graphics.Bitmap.Config.ARGB_8888)
        android.graphics.Canvas(bmp).drawBitmap(LinkLogoView.render(ctx, inner, 1f), (px - inner) / 2f, (px - inner) / 2f, null)
        android.graphics.drawable.Icon.createWithBitmap(bmp).also { chain = it }
    }

    /** 前台服务的通知 */
    fun link(ctx: Context, state: LinkState): Notification {
        createChannels(ctx)
        if (state == LinkState.IDLE) {
            return Notification.Builder(ctx, CH_IDLE)
                .setSmallIcon(R.drawable.ic_link)
                .setContentTitle("ColorLink 待命中")
                .setShowWhen(false)
                .setContentIntent(openApp(ctx))
                .setOngoing(true)
                .build()
        }
        val announcing = state == LinkState.ANNOUNCING
        val b = Notification.Builder(ctx, if (announcing) CH_CONNECTED else CH_LINKED)
            .setContentTitle("ColorLink 已连接")
            .setShowWhen(false)
            .setContentIntent(openApp(ctx))
            .setCategory(Notification.CATEGORY_STATUS)
            .setOngoing(true)
        if (announcing) {
            // 流体云：左边是彩色链环，右边「已连接」。
            // ColorOS 的胶囊右边只显示文字（不认大图标），所以没法放自绘的小绿灯或环形进度
            b.setSmallIcon(chainIcon(ctx))
            LiveUpdate.apply(ctx, b, shortText = "已连接")
        } else {
            b.setSmallIcon(R.drawable.ic_link)
        }
        return b.build()
    }

    /** 一批文件（Mac 一次拖过来的那几个）。收完最后一个才弹「已收到 N 个文件」 */
    private class Batch(val id: String, val count: Int) {
        val saved = ArrayList<MediaRepo.Saved>()
    }
    private var batch: Batch? = null

    /**
     * 正在接收：流体云左边是链环，右边是百分比。progress 是整批的进度（0..1），多个文件时按「第几个 + 当前文件进度」算。
     */
    fun receiving(ctx: Context, name: String, index: Int, count: Int, fileProgress: Float?) {
        createChannels(ctx)
        main.removeCallbacksAndMessages(ID_TRANSFER)
        val progress = ((index + (fileProgress ?: 0f)) / count).coerceIn(0f, 1f)
        val pct = (progress * 100).toInt()
        val b = Notification.Builder(ctx, CH_CONNECTED)
            .setSmallIcon(chainIcon(ctx))
            .setContentTitle(if (count > 1) "正在接收 ${index + 1}/$count" else "正在接收 $name")
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
        // 不用 ProgressStyle：展开后是导航式的分段进度条；普通进度条就够了
        b.setProgress(100, pct, fileProgress == null && count == 1)
        LiveUpdate.apply(ctx, b, shortText = "$pct%")
        ctx.getSystemService(NotificationManager::class.java).notify(ID_TRANSFER, b.build())
    }

    /** 一个文件收完。不是这批的最后一个就继续显示进度；最后一个收完弹「已收到」 */
    fun receivedOne(ctx: Context, saved: MediaRepo.Saved, batchId: String, index: Int, count: Int) {
        val current = batch?.takeIf { it.id == batchId && it.count == count } ?: Batch(batchId, count).also { batch = it }
        current.saved += saved
        if (index < count - 1) {
            receiving(ctx, saved.name, index + 1, count, 0f)
            return
        }
        batch = null
        receivedAll(ctx, current.saved)
    }

    /**
     * 整批收完：流体云弹出「已收到 N 个文件」，点一下打开（一个文件直接打开，多个打开所在文件夹），
     * 点过或 10 秒后自动消失。实况通知必须是常驻的，所以点击后由 OpenReceivedActivity 负责撤掉它。
     */
    private fun receivedAll(ctx: Context, saved: List<MediaRepo.Saved>) {
        if (saved.isEmpty()) return
        val allImages = saved.all { it.mime.startsWith("image/") }
        val what = when {
            saved.size == 1 && allImages -> "图片"
            saved.size == 1 -> "文件"
            allImages -> "${saved.size} 张图片"
            else -> "${saved.size} 个文件"
        }
        val b = Notification.Builder(ctx, CH_CONNECTED)
            .setSmallIcon(chainIcon(ctx))
            .setContentTitle("已收到$what")
            .setContentText(if (saved.size == 1) saved[0].name else "已保存到 ${saved.map { it.dir }.distinct().joinToString("、")}")
            .setContentIntent(PendingIntent.getActivity(
                ctx, ID_TRANSFER,
                Intent(ctx, OpenReceivedActivity::class.java).putExtra(OpenReceivedActivity.EXTRA_TARGET, openIntent(ctx, saved)),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ))
            .setOngoing(true)
            .setTimeoutAfter(10_000)
            .setShowWhen(false)
        if (saved.size == 1 && allImages) {
            runCatching { ctx.contentResolver.loadThumbnail(saved[0].uri, Size(256, 256), null) }.getOrNull()
                ?.let { b.setLargeIcon(it) }
        }
        // 胶囊里放得下「2 张图片」这样的短句；单个文件就写「已收到」
        LiveUpdate.apply(ctx, b, shortText = if (saved.size == 1) "已收到" else what)
        ctx.getSystemService(NotificationManager::class.java).notify(ID_TRANSFER, b.build())
    }

    /** 一个文件：用对应的 App 打开；多个：在文件管理里打开它们所在的文件夹（不在同一处就打开第一个文件） */
    private fun openIntent(ctx: Context, saved: List<MediaRepo.Saved>): Intent {
        val dirs = saved.map { it.dir }.distinct()
        if (saved.size > 1 && dirs.size == 1) {
            val folder = android.provider.DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents", "primary:${dirs[0]}",
            )
            val intent = Intent(Intent.ACTION_VIEW).setDataAndType(folder, android.provider.DocumentsContract.Document.MIME_TYPE_DIR)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // 直接交给系统「文件」，不弹选择框（网盘之类的 App 也会声明能打开文件夹）
            val files = Intent(intent).setPackage("com.android.documentsui")
            return if (files.resolveActivity(ctx.packageManager) != null) files else intent
        }
        return Intent(Intent.ACTION_VIEW).setDataAndType(saved[0].uri, saved[0].mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    /** Mac 要删的照片系统需要确认：点通知弹出系统的「移到回收站」确认框 */
    fun confirmTrash(ctx: Context, request: PendingIntent, count: Int) {
        createChannels(ctx)
        val b = Notification.Builder(ctx, CH_RECEIVED)
            .setSmallIcon(R.drawable.ic_link)
            .setContentTitle("${LinkCore.macName ?: "Mac"} 想删除 $count 项")
            .setContentText("点按确认移到「最近删除」；在 ColorLink 里打开「媒体管理」后就不用再确认")
            .setContentIntent(request)
            .setAutoCancel(true)
            .setTimeoutAfter(5 * 60_000)
        ctx.getSystemService(NotificationManager::class.java).notify(ID_TRASH, b.build())
    }

    /** 撤掉传输的流体云（点开「已收到」后调用） */
    fun dismissTransfer(ctx: Context) {
        ctx.getSystemService(NotificationManager::class.java).cancel(ID_TRANSFER)
    }

    fun receiveFailed(ctx: Context) {
        batch = null
        main.removeCallbacksAndMessages(ID_TRANSFER)
        ctx.getSystemService(NotificationManager::class.java).cancel(ID_TRANSFER)
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

    /**
     * 请求把通知提升为实况通知（ColorOS 显示为流体云）。不加进度条样式，展开后只显示标题；
     * Android 规定普通样式也可以提升，如果 ColorOS 不认，需要换回 ProgressStyle。
     */
    fun apply(ctx: Context, b: Notification.Builder, shortText: String?) {
        if (Build.VERSION.SDK_INT < 36) return
        try {
            val cls = Notification.Builder::class.java
            if (shortText != null) cls.getMethod("setShortCriticalText", String::class.java).invoke(b, shortText) // 胶囊里的文字
            cls.getMethod("setRequestPromotedOngoing", Boolean::class.javaPrimitiveType).invoke(b, true)
        } catch (_: Exception) {
            // Android 16.0（没有 QPR1）只认 extras
            b.extras.putBoolean("android.requestPromotedOngoing", true)
        }
    }
}
