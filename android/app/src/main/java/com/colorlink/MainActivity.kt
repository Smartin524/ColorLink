package com.colorlink

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.widget.CheckBox
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast

/**
 * 设置页：卡片式，只放状态和开关，不放说明文字（排查靠日志）。
 * - 顶部：图标、名字、连接状态
 * - 配对码
 * - 运行条件：能检测的自动打勾；ColorOS 不让查询的，设好后手动打勾。点一行跳到对应设置
 * - 空闲保活开关、更换配对码、取消所有配对
 */
class MainActivity : Activity() {

    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            refresh()
            handler.postDelayed(this, 1_000)
        }
    }

    private lateinit var statusDot: View
    private lateinit var statusText: TextView
    private lateinit var detailText: TextView
    private lateinit var codeText: TextView
    private val autoRows = mutableListOf<Pair<() -> Boolean, ImageView>>()

    // 配色：跟随系统日间 / 暗色，强调色取系统主题色
    private val night by lazy {
        resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }
    private val bg by lazy { if (night) Color.BLACK else 0xFFF2F3F5.toInt() }
    private val card by lazy { if (night) 0xFF1C1C1E.toInt() else Color.WHITE }
    private val primary by lazy { if (night) Color.WHITE else 0xFF111111.toInt() }
    private val secondary by lazy { if (night) 0xFF8E8E93.toInt() else 0xFF6B6B70.toInt() }
    private val divider by lazy { if (night) 0xFF2C2C2E.toInt() else 0xFFE5E5EA.toInt() }
    private val accent by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) getColor(android.R.color.system_accent1_500) else 0xFF0A84FF.toInt()
    }
    private val green = 0xFF34C759.toInt()
    private val red = 0xFFFF453A.toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppLog.init(this)
        // 清单里已设 excludeFromRecents，但覆盖安装前就存在的旧任务不会自动带上这个标记，这里再标一次
        getSystemService(android.app.ActivityManager::class.java).appTasks.forEach { it.setExcludeFromRecents(true) }
        actionBar?.hide()
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !night) {
            window.insetsController?.setSystemBarsAppearance(
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            )
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(24))
        }
        root.addView(headerCard())
        root.addView(codeCard())
        root.addView(sectionTitle("运行条件"))
        root.addView(conditionsCard())
        root.addView(sectionTitle("设置"))
        root.addView(settingsCard())

        val scroll = ScrollView(this).apply {
            setBackgroundColor(bg)
            isFillViewport = true
            addView(root)
            // Android 15 起强制全面屏：内容避开状态栏和导航栏
            setOnApplyWindowInsetsListener { v, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                v.setPadding(0, bars.top, 0, bars.bottom)
                insets
            }
        }
        // 开关、勾选框抢到焦点时 ScrollView 会自动滚过去；让容器先拿焦点，打开时停在顶部
        root.isFocusableInTouchMode = true
        root.requestFocus()
        setContentView(scroll)
        startAll()
    }

    override fun onResume() {
        super.onResume()
        handler.post(tick)
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

    // region 卡片

    private fun headerCard() = card().apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(ImageView(context).apply {
            setImageResource(R.mipmap.ic_launcher)
            layoutParams = LinearLayout.LayoutParams(dp(56), dp(56)).apply { marginEnd = dp(14) }
        })
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            addView(label("ColorLink", 20f, primary, bold = true))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(4), 0, 0)
                statusDot = View(context).apply {
                    layoutParams = LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(6) }
                }
                addView(statusDot)
                statusText = label("", 14f, primary)
                addView(statusText)
            })
            detailText = label("", 12f, secondary).apply { setPadding(0, dp(2), 0, 0) }
            addView(detailText)
        })
    }

    private fun codeCard() = card().apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(label("配对码", 15f, secondary).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        codeText = label("", 26f, primary, bold = true).apply {
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            letterSpacing = 0.12f
        }
        addView(codeText)
    }

    private fun conditionsCard() = card(padding = 0).apply {
        val rows = listOf<View>(
            autoRow("照片与视频", { granted(mediaPermission()) }) { requestRuntimePermissions() },
            autoRow("通知使用权", { NotifyListener.enabled(this@MainActivity) }) {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            },
            autoRow("忽略电池优化", { ignoringBattery() }) { requestIgnoreBattery() },
            autoRow("蓝牙", { BleWake.hasPermission(this@MainActivity) }) { requestRuntimePermissions() },
            autoRow("流体云", { LiveUpdate.canPromote(this@MainActivity) != false }) { Notifications.openSettings(this@MainActivity) },
            manualRow("background", "完全允许后台行为") { ColorOS.openAppDetails(this@MainActivity) },
            manualRow("autostart", "自启动与关联启动") {
                if (!ColorOS.openAutoStart(this@MainActivity)) toast("应用 → 自启动管理 / 关联启动管理 → ColorLink")
            },
            manualRow("sleep", "关闭睡眠待机优化") { ColorOS.openBatterySettings(this@MainActivity) },
            manualRow("wifi", "WLAN 不自动切换流量") { ColorOS.openWifiSettings(this@MainActivity) },
        )
        rows.forEachIndexed { i, row ->
            if (i > 0) addView(separator())
            addView(row)
        }
    }

    private fun settingsCard() = card(padding = 0).apply {
        addView(row("空闲保活", trailing = Switch(context).apply {
            isChecked = Prefs.keepAlive(this@MainActivity)
            setOnCheckedChangeListener { _, on ->
                Prefs.setKeepAlive(this@MainActivity, on)
                LinkService.refresh(this@MainActivity)
            }
        }))
        addView(separator())
        addView(row("更换配对码", titleColor = accent) {
            Prefs.resetPairCode(this@MainActivity)
            refresh()
        })
        addView(separator())
        addView(row("取消所有电脑的配对", titleColor = red) {
            Prefs.resetToken(this@MainActivity)
            toast("已取消，电脑需要重新配对")
        })
    }

    // endregion

    // region 刷新

    private fun refresh() {
        val connected = EventBus.count > 0
        val running = LinkCore.running
        statusDot.background = dot(if (connected) green else if (running) secondary else red)
        statusText.text = when {
            connected -> "已连接 ${LinkCore.macName ?: "Mac"}"
            running -> "待命中"
            else -> "未运行"
        }
        val killed = ColorOS.recentExits(this, 8).count {
            it.wasRunningService && it.hint != null && it.time > System.currentTimeMillis() - 24 * 3600_000L
        }
        detailText.text = buildString {
            if (running) append("已运行 ${formatUptime(LinkCore.uptimeMillis)}")
            if (killed > 0) append(" · 近 24 小时被结束 $killed 次")
        }
        val code = Prefs.pairCode(this)
        codeText.text = "${code.take(3)} ${code.drop(3)}"
        for ((check, icon) in autoRows) setStatus(icon, check())
    }

    // endregion

    // region 行与小部件

    private fun autoRow(title: String, check: () -> Boolean, onClick: () -> Unit): View {
        val icon = ImageView(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(22), dp(22))
            scaleType = ImageView.ScaleType.CENTER
        }
        autoRows += check to icon
        return row(title, trailing = icon) { if (!check()) onClick() }
    }

    private fun manualRow(key: String, title: String, onClick: () -> Unit): View {
        val box = CheckBox(this).apply {
            isChecked = Prefs.confirmed(this@MainActivity, key)
            buttonTintList = android.content.res.ColorStateList.valueOf(accent)
            setOnCheckedChangeListener { _, on -> Prefs.setConfirmed(this@MainActivity, key, on) }
        }
        return row(title, trailing = box, onClick = onClick)
    }

    private fun row(title: String, trailing: View? = null, titleColor: Int = primary, onClick: (() -> Unit)? = null) =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(52)
            setPadding(dp(16), dp(4), dp(12), dp(4))
            addView(label(title, 16f, titleColor).apply {
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            })
            trailing?.let { addView(it) }
            if (onClick != null) {
                isClickable = true
                background = rippleBackground()
                setOnClickListener { onClick() }
            }
        }

    /** 满足：绿色对勾；不满足：红点 */
    private fun setStatus(icon: ImageView, ok: Boolean) {
        icon.setImageDrawable(if (ok) checkmark() else dot(red, size = 10))
    }

    private fun checkmark() = TextDrawable("✓", green, dp(18).toFloat())

    private fun card(padding: Int = 16) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(padding), dp(padding), dp(padding), dp(padding))
        background = GradientDrawable().apply {
            setColor(card)
            cornerRadius = dp(20).toFloat()
        }
        clipToOutline = true
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            .apply { bottomMargin = dp(12) }
    }

    private fun sectionTitle(s: String) = label(s, 13f, secondary).apply {
        setPadding(dp(16), dp(10), 0, dp(8))
    }

    private fun separator() = View(this).apply {
        setBackgroundColor(divider)
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1).apply { marginStart = dp(16) }
    }

    private fun label(s: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = s
        textSize = size
        setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun dot(color: Int, size: Int = 8) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
        setSize(dp(size), dp(size))
    }

    private fun rippleBackground(): android.graphics.drawable.Drawable? {
        val attrs = obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground))
        return attrs.getDrawable(0).also { attrs.recycle() }
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_LONG).show()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun formatUptime(ms: Long): String {
        val m = ms / 60_000
        return when {
            m < 1 -> "不到 1 分钟"
            m < 60 -> "$m 分钟"
            else -> "${m / 60} 小时 ${m % 60} 分钟"
        }
    }

    // endregion

    // region 权限

    private fun mediaPermission() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) Manifest.permission.READ_MEDIA_IMAGES
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun ignoringBattery() = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

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
}

/** 把一个字符画成图标（用来显示绿色对勾，免得再加图片资源） */
private class TextDrawable(private val text: String, color: Int, private val size: Float) : android.graphics.drawable.Drawable() {
    override fun getIntrinsicWidth() = (size * 1.2f).toInt()
    override fun getIntrinsicHeight() = (size * 1.2f).toInt()

    private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        textSize = size
        typeface = Typeface.DEFAULT_BOLD
        textAlign = android.graphics.Paint.Align.CENTER
    }

    override fun draw(canvas: android.graphics.Canvas) {
        val b = bounds
        canvas.drawText(text, b.exactCenterX(), b.exactCenterY() - (paint.descent() + paint.ascent()) / 2, paint)
    }

    override fun setAlpha(alpha: Int) {
        paint.alpha = alpha
    }

    override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) {
        paint.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity() = android.graphics.PixelFormat.TRANSLUCENT
}
