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
 * - 展开：正中间是链环、名字和状态小灯；点下方「⌄」收起露出设置，在设置顶部下拉恢复
 * - 需要处理：只列出不满足的条件（权限给过一次就稳定，不必常驻），全部满足时整块隐藏
 * - 配对码：只在配对新电脑时需要，配对过之后收起
 * - 空闲保活开关、配对新电脑、取消所有配对
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
    private lateinit var logo: LinkLogoView
    private var logoConnected: Boolean? = null
    /** 浮在最上层的标志（链环 + 名字）：展开时在屏幕正中，收起时缩到顶部正中 */
    private lateinit var header: LinearLayout
    private lateinit var nameRow: View
    private lateinit var topBar: View
    private lateinit var scroll: ScrollView
    private var insetTop = 0
    private var insetBottom = 0
    /** 收起按钮（大链环下方的「⌄」） */
    private lateinit var collapseButton: View
    /** 0 = 展开（大链环），1 = 收起（小链环在顶部，设置卡片可见） */
    private var collapse = 0f
    private var collapseAnimator: android.animation.ValueAnimator? = null
    private var touchDownY = 0f
    private var pulling = false
    private lateinit var runText: TextView
    private lateinit var codeText: TextView
    /** 运行条件：只显示不满足的项，全部满足时整块隐藏 */
    private class Condition(val key: String, val view: View, val ok: () -> Boolean)
    private val conditions = mutableListOf<Condition>()
    private lateinit var conditionsTitle: View
    private lateinit var conditionsCard: LinearLayout
    private var shownConditions: List<String>? = null
    private lateinit var codeCard: View
    private lateinit var pairRowTitle: TextView
    /** 配对过之后配对码默认收起，点「配对新电脑」才显示 */
    private var showCode = false

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
            setPadding(dp(16), 0, dp(16), dp(24))
        }
        codeCard = codeCard()
        root.addView(codeCard)
        conditionsTitle = sectionTitle("需要处理")
        root.addView(conditionsTitle)
        conditionsCard = conditionsCard()
        root.addView(conditionsCard)
        root.addView(settingsCard())

        scroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(root)
        }
        topBar = View(this).apply {
            background = GradientDrawable().apply { setColor(bg) }
            alpha = 0f
        }
        header = header().apply {
            alpha = 0f // 首次摆好位置前先隐藏，免得闪一下左上角
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> applyCollapse() }
        }
        collapseButton = collapseButton()
        val screen = android.widget.FrameLayout(this).apply {
            setBackgroundColor(bg)
            addView(scroll)
            addView(topBar, android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)))
            addView(header, android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
            addView(collapseButton, android.widget.FrameLayout.LayoutParams(dp(48), dp(48), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
            // Android 15 起强制全面屏：内容避开状态栏和导航栏
            setOnApplyWindowInsetsListener { _, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                insetTop = bars.top
                insetBottom = bars.bottom
                scroll.setPadding(0, bars.top + dp(64), 0, bars.bottom)
                topBar.layoutParams = topBar.layoutParams.apply { height = bars.top + dp(56) }
                collapseButton.layoutParams = (collapseButton.layoutParams as android.widget.FrameLayout.LayoutParams)
                    .apply { bottomMargin = bars.bottom + dp(28) }
                insets
            }
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> applyCollapse() }
        }
        // 开关、勾选框抢到焦点时 ScrollView 会自动滚过去；让容器先拿焦点
        root.isFocusableInTouchMode = true
        root.requestFocus()
        setContentView(screen)
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

    /** 第一屏：正中间是图标、名字和状态小灯（绿：已连接；灰：待命中；红：没在运行），底部一个下滑提示 */
    /** 大链环下方的收起按钮：点一下收起，露出设置 */
    private fun collapseButton() = android.widget.FrameLayout(this).apply {
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(card)
        }
        foreground = rippleBackground()
        elevation = 0f
        contentDescription = "显示设置"
        addView(label("⌄", 24f, secondary).apply { gravity = Gravity.CENTER },
            android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        setOnClickListener { animateCollapse(1f) }
    }

    /** 浮层标志：链环（不加底板，融在背景里）+ 名字和状态小灯 */
    private fun header() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        logo = LinkLogoView(context).apply {
            layoutParams = LinearLayout.LayoutParams(dp(LOGO_DP), dp(LOGO_DP)).apply { bottomMargin = dp(8) }
        }
        addView(logo)
        nameRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            // 默认会跟随父容器（按图标宽度算）而被截断，明确按内容自适应
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            addView(label("ColorLink", 26f, primary, bold = true))
            statusDot = View(context).apply {
                layoutParams = LinearLayout.LayoutParams(dp(10), dp(10)).apply { marginStart = dp(10) }
            }
            addView(statusDot)
        }
        addView(nameRow)
    }

    /**
     * 按收起进度摆放：collapse = 0 时大标志在屏幕正中、设置在屏幕外；collapse = 1 时标志缩成 40dp 停在顶部正中，
     * 设置卡片升到顶部背景条下方。只改平移、缩放和透明度，不触发重新布局。
     */
    private fun applyCollapse() {
        val screenH = (scroll.parent as View).height
        if (screenH == 0 || header.width == 0) return
        val c = collapse
        val e = c * c * (3 - 2 * c)
        val collapsedLogo = dp(40).toFloat()
        val minScale = collapsedLogo / dp(LOGO_DP)
        val expandedTop = insetTop + (screenH - insetTop - insetBottom - header.height) / 2f
        val collapsedTop = insetTop + (dp(56) - collapsedLogo) / 2f

        header.alpha = 1f
        header.pivotX = header.width / 2f
        header.pivotY = 0f
        header.translationX = ((scroll.parent as View).width - header.width) / 2f
        header.translationY = expandedTop + (collapsedTop - expandedTop) * e
        val s = 1f + (minScale - 1f) * e
        header.scaleX = s
        header.scaleY = s
        nameRow.alpha = (1f - c * 2.5f).coerceIn(0f, 1f)
        topBar.alpha = ((c - 0.5f) / 0.5f).coerceIn(0f, 1f)
        // 设置从屏幕下方升上来
        scroll.translationY = (1f - e) * screenH * 0.6f
        scroll.alpha = ((c - 0.15f) / 0.6f).coerceIn(0f, 1f)
        scroll.visibility = if (c == 0f) View.INVISIBLE else View.VISIBLE
        collapseButton.alpha = (1f - c * 3f).coerceIn(0f, 1f)
        collapseButton.visibility = if (c >= 0.34f) View.INVISIBLE else View.VISIBLE
    }

    /** 收起 / 展开的过渡动画。期间把标志和设置交给 GPU 缓存成纹理，只做变换，不逐帧重绘，避免掉帧 */
    private fun animateCollapse(target: Float) {
        if (collapse == target && collapseAnimator?.isRunning != true) return
        collapseAnimator?.cancel()
        if (target == 0f) scroll.smoothScrollTo(0, 0)
        val layers = listOf(header, scroll)
        collapseAnimator = android.animation.ValueAnimator.ofFloat(collapse, target).apply {
            duration = 420
            interpolator = android.view.animation.PathInterpolator(0.2f, 0f, 0f, 1f)
            addUpdateListener {
                collapse = it.animatedValue as Float
                applyCollapse()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationStart(a: android.animation.Animator) {
                    layers.forEach { v -> v.setLayerType(View.LAYER_TYPE_HARDWARE, null) }
                }

                override fun onAnimationEnd(a: android.animation.Animator) {
                    layers.forEach { v -> v.setLayerType(View.LAYER_TYPE_NONE, null) }
                }
            })
            start()
        }
    }

    /** 收起状态下，在设置列表顶部往下拉 → 恢复大链环 */
    override fun dispatchTouchEvent(ev: android.view.MotionEvent): Boolean {
        when (ev.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> {
                touchDownY = ev.rawY
                pulling = collapse == 1f && scroll.scrollY == 0
            }
            android.view.MotionEvent.ACTION_MOVE -> if (pulling && ev.rawY - touchDownY > dp(72)) {
                pulling = false
                animateCollapse(0f)
                // 取消子视图正在处理的触摸，免得同时触发点击
                val cancel = android.view.MotionEvent.obtain(ev).apply { action = android.view.MotionEvent.ACTION_CANCEL }
                super.dispatchTouchEvent(cancel)
                cancel.recycle()
                return true
            }
        }
        return super.dispatchTouchEvent(ev)
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
        auto("media", "照片与视频", { granted(mediaPermission()) }) { requestRuntimePermissions() }
        auto("listener", "通知使用权", { NotifyListener.enabled(this@MainActivity) }) {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }
        auto("battery", "忽略电池优化", { ignoringBattery() }) { requestIgnoreBattery() }
        auto("bluetooth", "蓝牙", { BleWake.hasPermission(this@MainActivity) }) { requestRuntimePermissions() }
        auto("live", "流体云", { LiveUpdate.canPromote(this@MainActivity) != false }) { Notifications.openSettings(this@MainActivity) }
        manual("background", "完全允许后台行为") { ColorOS.openAppDetails(this@MainActivity) }
        manual("autostart", "自启动与关联启动") {
            if (!ColorOS.openAutoStart(this@MainActivity)) toast("应用 → 自启动管理 / 关联启动管理 → ColorLink")
        }
        manual("sleep", "关闭睡眠待机优化") { ColorOS.openBatterySettings(this@MainActivity) }
        manual("wifi", "WLAN 不自动切换流量") { ColorOS.openWifiSettings(this@MainActivity) }
    }

    private fun settingsCard() = card(padding = 0).apply {
        runText = label("", 14f, secondary).apply {
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            gravity = Gravity.END
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 2f)
        }
        addView(row("状态", trailing = runText))
        addView(separator())
        addView(row("空闲保活", trailing = Switch(context).apply {
            isChecked = Prefs.keepAlive(this@MainActivity)
            setOnCheckedChangeListener { _, on ->
                Prefs.setKeepAlive(this@MainActivity, on)
                LinkService.refresh(this@MainActivity)
            }
        }))
        addView(separator())
        addView(row("配对新电脑", titleColor = accent) {
            showCode = !showCode
            refresh()
        }.also { pairRowTitle = it.getChildAt(0) as TextView })
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
        statusDot.background = dot(if (connected) green else if (running) secondary else red, size = 10)
        // 连上时链环长出并扣合；断开时解扣分开；没连接时是分开的灰色链环
        // 只在状态真正变化时播放一次；刚打开页面时直接显示当前状态
        if (connected != logoConnected) {
            val first = logoConnected == null
            logoConnected = connected
            when {
                first && connected -> logo.showConnected()
                first -> logo.showIdle()
                connected -> logo.playConnect()
                else -> logo.playDisconnect()
            }
        }
        statusDot.contentDescription = when {
            connected -> "已连接 ${LinkCore.macName ?: "Mac"}"
            running -> "待命中"
            else -> "未运行"
        }
        val killed = ColorOS.recentExits(this, 8).count {
            it.wasRunningService && it.hint != null && it.time > System.currentTimeMillis() - 24 * 3600_000L
        }
        runText.text = buildString {
            append(
                when {
                    connected -> LinkCore.macName ?: "已连接"
                    running -> "待命中"
                    else -> "未运行"
                },
            )
            if (running) append(" · ${formatUptime(LinkCore.uptimeMillis)}")
            if (killed > 0) append(" · 被结束 $killed 次")
        }
        // 配对码：从没配对过就一直显示；配对过之后点「配对新电脑」才显示
        val code = Prefs.pairCode(this)
        codeText.text = "${code.take(3)} ${code.drop(3)}"
        val paired = Prefs.paired(this)
        codeCard.visibility = if (!paired || showCode) View.VISIBLE else View.GONE
        pairRowTitle.text = if (paired && showCode) "收起配对码" else "配对新电脑"

        // 运行条件：只列出不满足的；集合变了才重排，避免每秒重建
        val pending = conditions.filter { !it.ok() }
        val keys = pending.map { it.key }
        if (keys != shownConditions) {
            shownConditions = keys
            conditionsCard.removeAllViews()
            pending.forEachIndexed { i, c ->
                if (i > 0) conditionsCard.addView(separator())
                conditionsCard.addView(c.view)
            }
            val visible = if (pending.isEmpty()) View.GONE else View.VISIBLE
            conditionsTitle.visibility = visible
            conditionsCard.visibility = visible
        }
    }

    // endregion

    // region 行与小部件

    /** 能自动检测的条件：不满足时显示，点一下去授权 / 去设置 */
    private fun auto(key: String, title: String, ok: () -> Boolean, onClick: () -> Unit) {
        val icon = ImageView(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(22), dp(22))
            scaleType = ImageView.ScaleType.CENTER
            setImageDrawable(dot(red, size = 10))
        }
        conditions += Condition(key, row(title, trailing = icon, onClick = onClick), ok)
    }

    /** ColorOS 不让查询的条件：点一下去设置，设好后勾上就不再显示 */
    private fun manual(key: String, title: String, onClick: () -> Unit) {
        val box = CheckBox(this).apply {
            buttonTintList = android.content.res.ColorStateList.valueOf(accent)
            setOnCheckedChangeListener { _, on -> Prefs.setConfirmed(this@MainActivity, key, on) }
        }
        conditions += Condition(key, row(title, trailing = box, onClick = onClick)) { Prefs.confirmed(this, key) }
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

    private companion object {
        const val LOGO_DP = 140
    }
}
