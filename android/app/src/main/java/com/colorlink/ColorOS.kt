package com.colorlink

import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * ColorOS 专项：识别系统、直达设置页、解释 App 被杀的原因。
 *
 * ColorOS 自己的设置页（自启动管理、耗电保护）组件名随版本变化，部分还要求 OPPO 签名权限，
 * 第三方 App 不一定打得开。所以每个入口都是“依次尝试候选页面，全部失败就退回通用页面”。
 *
 * ColorOS 17（PKJ110，Android 17）实测：
 * - 单个应用的「耗电管理」= com.oplus.battery/…fuelgaue.PowerControlActivity，exported=false
 * - 「自启动管理」「关联启动管理」= com.oplus.battery/com.oplus.startupapp.view.*，
 *   要求 oplus.permission.OPLUS_COMPONENT_SAFE（signature 级）
 * - 「设置 → 应用」页 = com.android.settings/…OplusSettingsActivity$AppSettingsActivity，exported=false
 * 都打不开，只能打开应用详情页和设置首页，再用文字引导。
 * 下面的旧组件名来自社区整理，对应 ColorOS 11 及更早版本，留着给老机型用。
 */
object ColorOS {

    /** OPPO、一加、realme 的国行系统都基于 ColorOS。 */
    val isOplus: Boolean by lazy {
        Build.MANUFACTURER.lowercase(Locale.ROOT) in setOf("oppo", "oneplus", "realme") || version != null
    }

    /** 例如 "V15.0.0"；非 ColorOS 返回 null。 */
    val version: String? by lazy {
        prop("ro.build.version.oplusrom") ?: prop("ro.build.version.opporom")
    }

    /** 商品名，例如 "OPPO Find X8 Ultra"；读不到时为 null（工程型号见 Build.MODEL，例如 PKJ110）。 */
    val marketName: String? by lazy {
        prop("ro.vendor.oplus.market.name") ?: prop("ro.product.marketname") ?: prop("ro.oppo.market.name")
    }

    private fun prop(key: String): String? = try {
        Runtime.getRuntime().exec(arrayOf("getprop", key)).inputStream.bufferedReader()
            .use { it.readLine()?.trim() }
            ?.takeIf { it.isNotEmpty() }
    } catch (_: Exception) {
        null
    }

    // region 设置页直达

    private val autoStartPages = listOf(
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
        ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
    )

    private val batteryPages = listOf(
        ComponentName("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"),
        ComponentName("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerSaverModeActivity"),
    )

    /**
     * 应用详情页。ColorOS 12 以后，「耗电管理」里的允许后台运行、自启动、关联启动都在这里，
     * 这是最稳的入口。
     */
    fun openAppDetails(ctx: Context) {
        start(ctx, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}")))
    }

    /**
     * 返回 true 表示打开了 ColorOS 专门的自启动管理页；false 表示打不开，已退回设置首页，
     * 需要提示用户手动进入「设置 → 应用 → 自启动管理」。
     */
    fun openAutoStart(ctx: Context): Boolean {
        if (autoStartPages.any { start(ctx, Intent().setComponent(it)) }) return true
        start(ctx, Intent(Settings.ACTION_SETTINGS))
        return false
    }

    /** 电池设置（关闭「睡眠待机优化」在这里）。 */
    fun openBatterySettings(ctx: Context) {
        if (batteryPages.any { start(ctx, Intent().setComponent(it)) }) return
        if (start(ctx, Intent(Intent.ACTION_POWER_USAGE_SUMMARY))) return
        start(ctx, Intent(Settings.ACTION_SETTINGS))
    }

    fun openWifiSettings(ctx: Context) {
        start(ctx, Intent(Settings.ACTION_WIFI_SETTINGS))
    }

    private fun start(ctx: Context, intent: Intent): Boolean = try {
        // 从 App 界面打开时不加 NEW_TASK：否则会复用设置已有的任务栈，可能直接显示上次停留的页面，
        // 按返回也回不到 ColorLink
        if (ctx !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        // 需要 OPPO 签名权限的页面会走到这里
        false
    }

    // endregion

    // region 被杀诊断

    class Exit(
        val time: Long,
        val reason: String,
        val hint: String?,
        val detail: String,
        /** 死的时候是不是正以前台服务运行；是的话说明被系统强杀了，不是正常回收。 */
        val wasRunningService: Boolean,
    ) {
        val timeText: String get() = SimpleDateFormat("MM-dd HH:mm", Locale.ROOT).format(Date(time))
    }

    /** 读取系统记录的最近几次进程退出原因（Android 11+）。 */
    fun recentExits(ctx: Context, max: Int = 8): List<Exit> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val am = ctx.getSystemService(ActivityManager::class.java) ?: return emptyList()
        return am.getHistoricalProcessExitReasons(ctx.packageName, 0, max).map { info ->
            val (reason, hint) = describe(info.reason)
            Exit(
                time = info.timestamp,
                reason = reason,
                hint = hint,
                detail = info.description.orEmpty(),
                wasRunningService = info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE,
            )
        }
    }

    private fun describe(reason: Int): Pair<String, String?> = when (reason) {
        ApplicationExitReason.EXIT_SELF -> "App 自己退出" to null
        ApplicationExitReason.SIGNALED -> "被系统发信号结束" to "多半是 ColorOS 后台清理。检查「完全允许后台行为」和「自启动」"
        ApplicationExitReason.LOW_MEMORY -> "内存不足被回收" to "内存紧张时难免发生，通知监听会在内存恢复后把它拉起来"
        ApplicationExitReason.CRASH, ApplicationExitReason.CRASH_NATIVE -> "崩溃" to "这是 App 自身的问题，请用 adb logcat 抓日志"
        ApplicationExitReason.ANR -> "无响应（ANR）" to "这是 App 自身的问题，请用 adb logcat 抓日志"
        ApplicationExitReason.PERMISSION_CHANGE -> "权限被修改" to null
        ApplicationExitReason.EXCESSIVE_RESOURCE_USAGE -> "资源占用过多被结束" to "系统认为耗电过高；检查「允许完全后台行为」"
        ApplicationExitReason.USER_REQUESTED -> "被强行停止或一键清理" to "如果不是你手动结束的，检查是否被手机管家等清理工具清理了"
        ApplicationExitReason.USER_STOPPED -> "用户被停止" to null
        ApplicationExitReason.OTHER -> "系统其他原因（常见于厂商省电策略）" to "检查「允许完全后台行为」「自启动」，并关闭「睡眠待机优化」"
        ApplicationExitReason.FREEZER -> "被冻结后结束" to "ColorOS 冻结了后台进程；检查「允许完全后台行为」"
        ApplicationExitReason.PACKAGE_STATE_CHANGE -> "应用状态变化" to null
        ApplicationExitReason.PACKAGE_UPDATED -> "App 更新" to null
        else -> "未知原因（$reason）" to null
    }

    // endregion
}

/** ApplicationExitInfo.REASON_* 的数值。直接写数字，避免较新的常量在低版本上编译告警。 */
private object ApplicationExitReason {
    const val EXIT_SELF = 1
    const val SIGNALED = 2
    const val LOW_MEMORY = 3
    const val CRASH = 4
    const val CRASH_NATIVE = 5
    const val ANR = 6
    const val PERMISSION_CHANGE = 8
    const val EXCESSIVE_RESOURCE_USAGE = 9
    const val USER_REQUESTED = 10
    const val USER_STOPPED = 11
    const val OTHER = 13
    const val FREEZER = 14
    const val PACKAGE_STATE_CHANGE = 15
    const val PACKAGE_UPDATED = 16
}
