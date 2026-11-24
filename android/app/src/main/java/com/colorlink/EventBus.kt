package com.colorlink

import org.json.JSONObject
import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue

/**
 * 把手机上发生的事（截图、通知、分享）推给已连接的电脑。每个 SSE 连接对应一个订阅：
 * 带着电脑的名字（事件流请求里的 name）和地址，可以连着好几台，界面上分开显示。
 */
object EventBus {
    /** mac：是不是 Mac（按请求的 User-Agent 认：macOS 的网络库会带上 Darwin）；不是 Mac 的就是 Windows 那台 */
    class Subscriber(val name: String, val address: InetAddress?, val since: Long, val mac: Boolean) {
        val queue = LinkedBlockingQueue<String>(256)
    }

    /** 一台已连接的电脑：同名的几个连接算一台 */
    data class Computer(val name: String, val address: String?, val since: Long, val mac: Boolean)

    private val subscribers = CopyOnWriteArrayList<Subscriber>()

    /** 订阅数变化时回调（任意线程），用来更新常驻通知。 */
    @Volatile
    var onSubscribersChanged: ((Int) -> Unit)? = null

    private val connectionListeners = java.util.concurrent.CopyOnWriteArraySet<() -> Unit>()

    fun addConnectionListener(listener: () -> Unit) { connectionListeners.add(listener) }
    fun removeConnectionListener(listener: () -> Unit) { connectionListeners.remove(listener) }

    private fun connectionChanged() {
        onSubscribersChanged?.invoke(subscribers.size)
        connectionListeners.forEach { it() }
    }

    val count: Int get() = subscribers.size

    /** 已连接的电脑，按连上的先后排 */
    fun computers(): List<Computer> = subscribers.groupBy { it.name }
        .map { (name, subs) -> subs.minBy { it.since }.let { Computer(name, it.address?.hostAddress, it.since, it.mac) } }
        .sortedBy { it.since }

    /** 这个地址上连着的电脑叫什么（收文件、删照片时标出是哪台电脑） */
    fun nameFor(address: InetAddress?): String? =
        address?.let { a -> subscribers.firstOrNull { it.address == a }?.name }

    fun subscribe(name: String, address: InetAddress?, mac: Boolean = true): Subscriber {
        val s = Subscriber(name, address, System.currentTimeMillis(), mac)
        subscribers.add(s)
        connectionChanged()
        return s
    }

    fun unsubscribe(s: Subscriber) {
        if (subscribers.remove(s)) connectionChanged()
    }

    /**
     * 马上给所有事件流发一行 ping。Mac 觉得事件流太久没动静时会请求 /api/info 问一下，
     * 这时手机多半刚从深睡里被叫醒：发 ping 的 20 秒计时只在 CPU 醒着时走，等不到它，要当场回一声
     */
    fun ping() = subscribers.forEach { it.queue.offer(": ping\n\n") }

    /** toMac：true 只发给 Mac，false 只发给不是 Mac 的（分享菜单选了入口）；null 发给所有 */
    fun publish(event: String, data: JSONObject, toMac: Boolean? = null) {
        // JSONObject.toString() 不含换行，正好是一行 SSE data
        val msg = "event: $event\ndata: $data\n\n"
        subscribers.forEach { if (toMac == null || it.mac == toMac) it.queue.offer(msg) }
    }
}
