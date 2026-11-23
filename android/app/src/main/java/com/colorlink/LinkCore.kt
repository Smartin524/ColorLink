package com.colorlink

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.MediaStore
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

private const val TAG = "ColorLink.Core"

/**
 * 连接核心：HTTP 服务器 + mDNS 广播 + 新照片/截图监听 + 敲门。
 *
 * 它不依赖前台服务，只要进程活着就能工作。平时由系统绑定的通知监听服务（NotifyListener）
 * 让进程保持存活，所以空闲时通知栏里什么都没有；只有 Mac 连上时才启动前台服务（LinkService），
 * 把通知显示成流体云。
 */
object LinkCore {
    const val PORT = 8765
    const val SERVICE_TYPE = "_colorlink._tcp"

    @Volatile
    var running = false
        private set

    /** Mac 刚连上时的“播报窗口”：流体云弹一下就收（像一次性通知），不常驻。 */
    private const val ANNOUNCE_MS = 2_500L
    private const val RECONNECT_QUIET_MS = 60_000L

    @Volatile
    private var announceUntil = 0L

    val announcing: Boolean get() = SystemClock.elapsedRealtime() < announceUntil

    /** 流体云这次弹出是因为哪台电脑连上了 */
    @Volatile
    var announcedName: String? = null
        private set

    /** 上次看到的已连接电脑；断开过的电脑什么时候断的（短时间内重连不再弹流体云） */
    private var lastNames = emptySet<String>()
    private val goneAt = HashMap<String, Long>()

    private lateinit var app: Application
    private val handler = Handler(Looper.getMainLooper())
    private var worker: ExecutorService = Executors.newSingleThreadExecutor()
    private lateinit var media: MediaRepo
    private var server: HttpServer? = null

    private var nsdListener: NsdManager.RegistrationListener? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    private var lastImageAdded = 0L
    private val seenImages = HashSet<Long>()
    private var startedAt = 0L

    val port: Int get() = server?.port ?: 0

    /** 本次连续运行了多久，设置页用它判断有没有被悄悄杀掉过。 */
    val uptimeMillis: Long get() = if (running) SystemClock.elapsedRealtime() - startedAt else 0

    /** 重复调用没关系。 */
    @Synchronized
    fun start(ctx: Context) {
        if (running || !Prefs.connectionEnabled(ctx)) return
        app = ctx.applicationContext as Application
        AppLog.init(app)
        // 把系统记录的最近几次退出原因写进日志，事后能看出是被谁、因为什么结束的
        ColorOS.recentExits(app, 3).forEach {
            AppLog.i(TAG, "上次退出 ${it.timeText}：${it.reason}${if (it.wasRunningService) "（当时在前台运行）" else ""} ${it.detail}")
        }
        if (worker.isShutdown) worker = Executors.newSingleThreadExecutor()
        media = MediaRepo(app)
        server = HttpServer(TlsIdentity.serverSocketFactory(), Api(app, media, ::transferStarted, ::transferFinished)::handle)
            .also { it.start(PORT) }
        registerNsd()
        watchNetwork()

        lastImageAdded = System.currentTimeMillis() / 1000
        app.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, mediaObserver)

        // Mac 连上 / 断开时，决定要不要开前台服务（流体云）
        EventBus.onSubscribersChanged = { n ->
            val computers = EventBus.computers().map { it.name }
            AppLog.i(TAG, if (n > 0) "已连接：${computers.joinToString("、")}（共 $n 个连接）" else "电脑都已断开")
            handler.post {
                if (!running) return@post
                val now = SystemClock.elapsedRealtime()
                val names = EventBus.computers().map { it.name }.toSet()
                (lastNames - names).forEach { goneAt[it] = now }
                // 有电脑新连上：弹一下流体云写上它的名字，到时间自动收起。
                // 同一台刚断开不到 1 分钟又连上的（网络抖一下、Mac 重连）不算新连接，不弹
                val fresh = (names - lastNames).firstOrNull { now - (goneAt[it] ?: -RECONNECT_QUIET_MS) > RECONNECT_QUIET_MS }
                if (fresh != null) {
                    announcedName = fresh
                    announceUntil = now + ANNOUNCE_MS
                    handler.postDelayed({ LinkService.refresh(app) }, ANNOUNCE_MS + 100)
                }
                lastNames = names
                LinkService.refresh(app)
                if (n > 0) MacNetworks.remember(app)
                BleWake.update(app)
            }
        }
        app.registerReceiver(
            powerReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
            },
        )
        // 开关热点时敲门：Mac 可能正要连上手机热点，而这对手机来说不算“网络变化”
        app.registerReceiver(tetherReceiver, IntentFilter("android.net.conn.TETHER_STATE_CHANGED"))
        worker.execute { media.prewarmIfCharging() }
        Watchdog.schedule(app)

        startedAt = SystemClock.elapsedRealtime()
        running = true
        knockSoon()
        AppLog.i(TAG, "核心已启动，版本 ${runCatching { app.packageManager.getPackageInfo(app.packageName, 0).versionName }.getOrNull()}，端口 $port")
    }

    @Synchronized
    fun stop() {
        if (!running) return
        running = false
        EventBus.onSubscribersChanged = null
        app.contentResolver.unregisterContentObserver(mediaObserver)
        runCatching { app.unregisterReceiver(powerReceiver) }
        runCatching { app.unregisterReceiver(tetherReceiver) }
        networkCallback?.let { app.getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        networkCallback = null
        unregisterNsd()
        server?.stop()
        server = null
        worker.shutdownNow()
        activeTransfers = 0
        handler.removeCallbacksAndMessages(null)
        lastKnockAt = -30_000L
        announceUntil = 0
        announcedName = null
        lastNames = emptySet()
        goneAt.clear()
        releaseLocks()
        AppLog.i(TAG, "核心已停止")
    }

    // region 省电：只在传输（列表、缩略图、原文件、收发文件）期间持锁，最后一个传输写完 3 秒后释放
    //
    // 探活、事件流这类轻请求不持锁：Mac 深睡探活每几分钟来一次，要是每次都醒 15 秒，手机整夜睡不踏实

    private var activeTransfers = 0
    private val idleRelease = Runnable { if (activeTransfers == 0) releaseLocks() }

    private fun transferStarted() {
        handler.post {
            if (!running) return@post
            activeTransfers++
            handler.removeCallbacks(idleRelease)
            acquireLocks()
        }
    }

    /** 响应（包括原文件的整个流）写完才算结束。连着来的缩略图请求之间不释放，免得锁反复开关 */
    private fun transferFinished() {
        handler.post {
            if (!running) return@post
            activeTransfers = (activeTransfers - 1).coerceAtLeast(0)
            if (activeTransfers == 0) handler.postDelayed(idleRelease, 3_000)
        }
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        if (wifiLock == null) {
            // 高性能模式是唯一能让后台传输时 Wi-Fi 不进省电模式的锁；只在传输期间持有，拖大视频时能跑满带宽
            wifiLock = app.getSystemService(WifiManager::class.java)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "colorlink:transfer")
                .apply { setReferenceCounted(false) }
        }
        if (wakeLock == null) {
            wakeLock = app.getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "colorlink:transfer")
                .apply { setReferenceCounted(false) }
        }
        wifiLock?.acquire()
        // 兜底超时，万一忘记释放也不会一直耗电；每个新传输开始都重新计时，传一个大视频不会中途掉锁
        wakeLock?.acquire(10 * 60_000)
    }

    private fun releaseLocks() {
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
    }

    // endregion

    // region mDNS

    private fun registerNsd() {
        val info = NsdServiceInfo().apply {
            serviceName = "ColorLink-${ColorOS.marketName ?: Build.MODEL}"
            serviceType = SERVICE_TYPE
            port = this@LinkCore.port
            setAttribute("id", Prefs.deviceId(app))
            setAttribute("name", Build.MODEL)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                AppLog.i(TAG, "mDNS 已广播：${info.serviceName}")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                AppLog.w(TAG, "mDNS 广播失败：$code")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) = Unit
        }
        nsdListener = listener
        app.getSystemService(NsdManager::class.java).registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun unregisterNsd() {
        nsdListener?.let {
            try {
                app.getSystemService(NsdManager::class.java).unregisterService(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        nsdListener = null
    }

    /** 换了 Wi-Fi 或者重新连上时重新广播，否则 Mac 可能还在找旧地址。 */
    private fun watchNetwork() {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        val cb = object : ConnectivityManager.NetworkCallback() {
            private var first = true
            override fun onAvailable(network: Network) {
                // 网卡地址要过一会儿才就绪，稍后再判断有没有局域网
                handler.postDelayed({ BleWake.update(app) }, 1_000)
                if (first) {
                    first = false
                    return
                }
                handler.postDelayed({
                    if (!running) return@postDelayed
                    unregisterNsd()
                    registerNsd()
                    // 换了网络，旧连接都已失效，不管当前有没有 Mac 连着都敲门
                    knockSoon(force = true)
                }, 1_000)
            }

            override fun onLost(network: Network) {
                handler.postDelayed({ BleWake.update(app) }, 1_000)
            }
        }
        cm.registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
            cb,
        )
        networkCallback = cb
    }

    // endregion

    // region 敲门

    private val knockRunnable = Runnable {
        if (running && EventBus.count == 0) worker.execute { Knock.send(app, port) }
    }

    private var lastKnockAt = -30_000L

    /**
     * 醒来、换网络、蓝牙再次发现 Mac 时调用。连敲三次（立即、3 秒、10 秒），
     * 应对 Mac 刚唤醒、Wi-Fi 还没连好的情况；已经有 Mac 连着就不敲。
     * force：第一下不管有没有 Mac 连着都敲（换网络后旧连接其实已经断了，只是手机还没察觉）。
     */
    fun knockSoon(force: Boolean = false) {
        handler.post {
            if (!running) return@post
            // 不支持硬件过滤的手机每收到一个蓝牙广播包都会调到这里，30 秒内只敲一轮
            val now = SystemClock.elapsedRealtime()
            if (!force && now - lastKnockAt < 30_000) return@post
            lastKnockAt = now
            handler.removeCallbacks(knockRunnable)
            if (force) worker.execute { Knock.send(app, port) } else handler.post(knockRunnable)
            handler.postDelayed(knockRunnable, 3_000)
            handler.postDelayed(knockRunnable, 10_000)
            NotifyListener.rebindIfNeeded(app)
        }
    }

    // endregion

    // region 新照片 / 截图监听

    private val checkNewImages = Runnable {
        if (!running) return@Runnable
        worker.execute {
            if (EventBus.count == 0) return@execute
            for (img in media.newImages(lastImageAdded)) {
                val id = img.json.getLong("id")
                if (seenImages.add(id)) {
                    if (img.isScreenshot) {
                        AppLog.i(TAG, "新截图 ${img.json.getString("name")}，推送给 Mac")
                        EventBus.publish("screenshot", img.json)
                    } else {
                        // 普通新照片：通知 Mac 刷新「最近照片」
                        EventBus.publish("media", img.json)
                    }
                }
                lastImageAdded = maxOf(lastImageAdded, img.added)
            }
        }
    }

    private val mediaObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) {
            // 保存图片时会连续触发好几次，合并成一次查询
            handler.removeCallbacks(checkNewImages)
            handler.postDelayed(checkNewImages, 400)
        }
    }

    // endregion

    private val tetherReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (isInitialStickyBroadcast) return // 注册时系统会立刻补发一次上次的状态
            AppLog.i(TAG, "热点状态变化，敲门")
            handler.postDelayed({
                BleWake.update(app)
                knockSoon(force = true)
            }, 2_000)
        }
    }

    /**
     * 插拔电源：告诉 Mac 充电状态变了。Mac 只在手机充电时在后台补缩略图，靠这个事件开始和停下，
     * 不用隔一会儿来问一次（每问一次都会把深睡的手机叫醒）。
     */
    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!running) return
            val charging = intent.action == Intent.ACTION_POWER_CONNECTED
            if (EventBus.count > 0) {
                val battery = app.getSystemService(BatteryManager::class.java)
                    ?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                EventBus.publish("power", JSONObject().put("charging", charging).put("battery", battery))
            }
            if (charging) worker.execute { media.prewarmIfCharging() }
        }
    }
}

/** 手机的局域网地址；同时开着 Wi-Fi 和热点时用“ / ”隔开。 */
@Suppress("UNUSED_PARAMETER")
fun localIpv4(ctx: Context): String? = lanIpv4s().joinToString(" / ").ifEmpty { null }
