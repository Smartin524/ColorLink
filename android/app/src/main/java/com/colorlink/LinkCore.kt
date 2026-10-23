package com.colorlink

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
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.MediaStore
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

    @Volatile
    private var announceUntil = 0L
    private var lastSubscribers = 0

    val announcing: Boolean get() = SystemClock.elapsedRealtime() < announceUntil

    /** 最近一次连上来的 Mac 的名字，显示在流体云里。 */
    @Volatile
    var macName: String? = null

    private lateinit var app: Context
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
        if (running) return
        app = ctx.applicationContext
        AppLog.init(app)
        // 把系统记录的最近几次退出原因写进日志，事后能看出是被谁、因为什么结束的
        ColorOS.recentExits(app, 3).forEach {
            AppLog.i(TAG, "上次退出 ${it.timeText}：${it.reason}${if (it.wasRunningService) "（当时在前台运行）" else ""} ${it.detail}")
        }
        if (worker.isShutdown) worker = Executors.newSingleThreadExecutor()
        media = MediaRepo(app)
        server = HttpServer(Api(app, media, ::touch)::handle).also { it.start(PORT) }
        registerNsd()
        watchNetwork()

        lastImageAdded = System.currentTimeMillis() / 1000
        app.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, mediaObserver)

        // Mac 连上 / 断开时，决定要不要开前台服务（流体云）
        EventBus.onSubscribersChanged = { n ->
            AppLog.i(TAG, if (n > 0) "Mac 已连接（${macName ?: "?"}，共 $n 个连接）" else "Mac 已断开")
            handler.post {
                if (lastSubscribers == 0 && n > 0) {
                    // 从没连接到连上：弹一下流体云，到时间自动收起
                    announceUntil = SystemClock.elapsedRealtime() + ANNOUNCE_MS
                    handler.postDelayed({ LinkService.refresh(app) }, ANNOUNCE_MS + 100)
                }
                lastSubscribers = n
                LinkService.refresh(app)
                BleWake.update(app)
            }
        }
        app.registerReceiver(powerReceiver, IntentFilter(Intent.ACTION_POWER_CONNECTED))
        // 开关热点时敲门：Mac 可能正要连上手机热点，而这对手机来说不算“网络变化”
        app.registerReceiver(tetherReceiver, IntentFilter("android.net.conn.TETHER_STATE_CHANGED"))
        worker.execute { media.prewarmIfCharging() }

        startedAt = SystemClock.elapsedRealtime()
        running = true
        knockSoon()
        AppLog.i(TAG, "核心已启动，端口 $port")
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
        releaseLocks()
        AppLog.i(TAG, "核心已停止")
    }

    // region 省电：只在有请求时短暂持锁，空闲 15 秒后释放

    private val idleRelease = Runnable { releaseLocks() }

    private fun touch() {
        handler.post {
            acquireLocks()
            handler.removeCallbacks(idleRelease)
            handler.postDelayed(idleRelease, 15_000)
        }
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        if (wifiLock == null) {
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
        wakeLock?.acquire(60_000) // 兜底超时，万一忘记释放也不会一直耗电
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

    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            worker.execute { media.prewarmIfCharging() }
        }
    }
}

/** 手机的局域网地址；同时开着 Wi-Fi 和热点时用“ / ”隔开。 */
@Suppress("UNUSED_PARAMETER")
fun localIpv4(ctx: Context): String? = lanIpv4s().joinToString(" / ").ifEmpty { null }
