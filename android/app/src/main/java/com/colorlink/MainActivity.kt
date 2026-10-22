package com.colorlink

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast

/**
 * 设置页，做成一张检查清单：
 * - 能查到状态的权限自动打勾；
 * - ColorOS 不让查询的后台设置，给出直达入口和说明，设好后由用户手动打勾；
 * - 底部显示系统记录的被杀原因，帮你定位还缺哪一项。
 */
class MainActivity : Activity() {

    private lateinit var status: TextView
    private lateinit var diagnosis: TextView
    private val autoRows = mutableListOf<AutoRow>()
    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            refresh()
            handler.postDelayed(this, 1_000)
        }
    }

    private class AutoRow(val label: TextView, val button: Button, val name: String, val check: () -> Boolean)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppLog.init(this)
        // 清单里已设 excludeFromRecents，但覆盖安装前就存在的旧任务不会自动带上这个标记，这里再标一次
        getSystemService(android.app.ActivityManager::class.java).appTasks.forEach { it.setExcludeFromRecents(true) }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(28), dp(20), dp(28))
        }
        status = TextView(this).apply {
            textSize = 15f
            setLineSpacing(0f, 1.35f)
            setTextIsSelectable(true)
        }
        root.addView(text("ColorLink", 26f))
        root.addView(status)

        // 一、能自动检测的权限
        root.addView(header("一、基础权限（自动检测）"))
        root.addView(autoRow("读取照片、视频、录音", "授权", { granted(mediaPermission()) }) { requestRuntimePermissions() })
        root.addView(autoRow("通知使用权（同步短信验证码 + 平时免通知栏保活）", "去开启", { NotifyListener.enabled(this) }) {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        })
        root.addView(autoRow("流体云（实况通知）", "去开启", { LiveUpdate.canPromote(this) != false }) {
            Notifications.openSettings(this)
        })
        root.addView(autoRow("忽略电池优化", "去设置", { ignoringBattery() }) { requestIgnoreBattery() })
        root.addView(autoRow("蓝牙唤醒（靠近 Mac 自动启动）", "授权", { BleWake.hasPermission(this) }) { requestRuntimePermissions() })

        // 二、ColorOS 后台设置
        root.addView(header("二、ColorOS 后台设置（系统不让 App 查询，设好后请手动打勾）"))
        root.addView(manualRow(
            key = "background",
            title = "完全允许后台行为",
            how = "应用详情 → 耗电管理 → 选「完全允许后台行为」（旧版叫「允许完全后台行为」或「允许后台运行」）。最重要的一项：不开的话锁屏几分钟后服务会被冻结或结束。",
            action = "打开应用详情",
        ) { ColorOS.openAppDetails(this) })
        root.addView(manualRow(
            key = "autostart",
            title = "允许自启动、允许关联启动",
            how = "设置 → 应用 → 自启动管理，打开 ColorLink；再到「关联启动管理」里也打开（ColorOS 17 的路径；旧版在应用详情的「耗电管理」里）。不开的话，开机自启和蓝牙唤醒发来的广播会被 ColorOS 拦下，App 没法被拉起来。",
            action = "打开设置",
        ) {
            if (!ColorOS.openAutoStart(this)) toast("ColorOS 不允许直接打开自启动页，请依次点：应用 → 自启动管理 → ColorLink")
        })
        root.addView(manualRow(
            key = "sleep",
            title = "关闭「睡眠待机优化」",
            how = "设置 → 电池 → 更多设置 → 关闭「睡眠待机优化」。开着的话，夜间或长时间不用手机时会断网。",
            action = "打开电池设置",
        ) { ColorOS.openBatterySettings(this) })
        root.addView(manualRow(
            key = "wifi",
            title = "Wi-Fi 保持连接",
            how = "WLAN → 高级设置：打开「休眠时保持 WLAN 连接」（新版没有这项就跳过）；关闭「WLAN 助理 / 智能切换到移动数据」，否则信号一般时会切到流量，Mac 就连不上手机了。",
            action = "打开 WLAN 设置",
        ) { ColorOS.openWifiSettings(this) })

        // 三、存活诊断
        root.addView(header("三、存活诊断"))
        diagnosis = TextView(this).apply {
            textSize = 13f
            setLineSpacing(0f, 1.3f)
            setTextIsSelectable(true)
        }
        root.addView(diagnosis)

        // 四、运行
        root.addView(header("四、运行"))
        root.addView(Switch(this).apply {
            text = "空闲时也用前台服务保活（通知栏会多一条折叠的静默通知；只在经常被杀时打开）"
            isChecked = Prefs.keepAlive(this@MainActivity)
            setOnCheckedChangeListener { _, on ->
                Prefs.setKeepAlive(this@MainActivity, on)
                LinkService.refresh(this@MainActivity)
            }
            setPadding(0, dp(8), 0, dp(8))
        })
        root.addView(button("启动服务") { startAll() })
        root.addView(button("停止服务") {
            LinkService.stop(this)
            LinkCore.stop()
        })
        root.addView(button("更换配对码") { Prefs.resetPairCode(this); refresh() })
        root.addView(button("取消所有电脑的配对") { Prefs.resetToken(this); refresh() })

        setContentView(ScrollView(this).apply { addView(root) })
        startAll()
    }

    override fun onResume() {
        super.onResume()
        handler.post(tick)
        refreshDiagnosis()
    }

    override fun onPause() {
        handler.removeCallbacks(tick)
        super.onPause()
    }

    private fun startAll() {
        LinkCore.start(this)
        LinkService.refresh(this)
        BleWake.register(this)
        NotifyListener.rebindIfNeeded(this)
    }

    private fun refresh() {
        val lines = mutableListOf<String>()
        lines += if (LinkCore.running) {
            "● 服务运行中  ${localIpv4(this) ?: "未连接 Wi-Fi"}:${LinkCore.port}  已连续运行 ${formatUptime(LinkCore.uptimeMillis)}"
        } else {
            "○ 服务未运行"
        }
        lines += "已连接电脑：${EventBus.count} 台"
        lines += "通知栏：" + when {
            EventBus.count > 0 -> "已连接，显示流体云"
            Prefs.keepAlive(this) || !NotifyListener.connected -> "前台服务保活中（折叠的静默通知）"
            else -> "空闲时不显示（由通知使用权保活）"
        }
        when (LiveUpdate.canPromote(this)) {
            null -> lines += "流体云：系统低于 Android 16，连接时显示普通通知"
            false -> lines += "⚠ 流体云：已在通知设置里关闭"
            true -> Unit
        }
        lines += "配对码：${Prefs.pairCode(this)}"
        lines += "系统：" + (ColorOS.version?.let { "ColorOS $it" } ?: if (ColorOS.isOplus) "ColorOS" else "${Build.MANUFACTURER}（非 ColorOS）") +
            " · Android ${Build.VERSION.RELEASE}"
        if (NotifyListener.enabled(this) && !NotifyListener.connected) lines += "⚠ 通知使用权已开但系统没绑定，已请求重新绑定"
        status.text = lines.joinToString("\n")

        for (row in autoRows) {
            val ok = row.check()
            row.label.text = (if (ok) "✓ " else "✗ ") + row.name
            row.button.visibility = if (ok) View.GONE else View.VISIBLE
        }
    }

    private fun refreshDiagnosis() {
        val exits = ColorOS.recentExits(this)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            diagnosis.text = "需要 Android 11 以上才能读取被杀记录。"
            return
        }
        val sb = StringBuilder()
        sb.append(ColorOS.diagnose(exits) ?: "过去 24 小时没有发现服务被系统强行结束。").append("\n\n")
        if (exits.isEmpty()) {
            sb.append("（暂无退出记录）")
        } else {
            sb.append("最近的退出记录（★ 表示当时服务正在运行）：\n")
            for (e in exits) {
                sb.append(if (e.wasRunningService) "★ " else "· ").append(e.timeText).append("  ").append(e.reason)
                if (e.detail.isNotBlank()) sb.append("（").append(e.detail.take(60)).append("）")
                sb.append('\n')
            }
        }
        diagnosis.text = sb.toString().trimEnd()
    }

    // region 状态检测

    private fun mediaPermission() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) Manifest.permission.READ_MEDIA_IMAGES
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun ignoringBattery() = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

    // endregion

    // region 操作

    private fun requestRuntimePermissions() {
        val perms = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms += listOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_AUDIO,
                Manifest.permission.POST_NOTIFICATIONS,
            )
        } else {
            perms += Manifest.permission.READ_EXTERNAL_STORAGE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) perms += Manifest.permission.BLUETOOTH_SCAN
        requestPermissions(perms.toTypedArray(), 1)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        startAll()
        refresh()
    }

    @SuppressLint("BatteryLife")
    private fun requestIgnoreBattery() {
        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
    }

    // endregion

    // region 界面小工具

    private fun autoRow(name: String, action: String, check: () -> Boolean, onClick: (View) -> Unit): View {
        val label = TextView(this).apply {
            textSize = 15f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val btn = button(action, onClick)
        autoRows += AutoRow(label, btn, name, check)
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            addView(label)
            addView(btn)
        }
    }

    private fun manualRow(key: String, title: String, how: String, action: String?, onClick: (View) -> Unit): View {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(6), 0, dp(10))
        }
        box.addView(CheckBox(this).apply {
            text = title
            textSize = 15f
            isChecked = Prefs.confirmed(this@MainActivity, key)
            setOnCheckedChangeListener { _, on -> Prefs.setConfirmed(this@MainActivity, key, on) }
        })
        box.addView(TextView(this).apply {
            text = how
            textSize = 13f
            alpha = 0.75f
            setPadding(dp(32), 0, 0, 0)
        })
        if (action != null) {
            box.addView(button(action, onClick).apply {
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { marginStart = dp(28) }
            })
        }
        return box
    }

    private fun header(s: String) = text(s, 17f, top = 24).apply { setTypeface(typeface, Typeface.BOLD) }

    private fun text(s: String, size: Float, top: Int = 0) = TextView(this).apply {
        text = s
        textSize = size
        setPadding(0, dp(top), 0, dp(6))
    }

    private fun button(label: String, onClick: (View) -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        setOnClickListener(onClick)
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_LONG).show()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun formatUptime(ms: Long): String {
        val m = ms / 60_000
        return if (m < 60) "$m 分钟" else "${m / 60} 小时 ${m % 60} 分钟"
    }

    // endregion
}
