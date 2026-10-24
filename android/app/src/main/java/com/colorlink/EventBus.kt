package com.colorlink

import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue

/** 把手机上发生的事（截图、通知、分享）推给所有已连接的 Mac。每个 SSE 连接对应一个队列。 */
object EventBus {
    private val subscribers = CopyOnWriteArrayList<LinkedBlockingQueue<String>>()

    /** 订阅数变化时回调（任意线程），用来更新常驻通知。 */
    @Volatile
    var onSubscribersChanged: ((Int) -> Unit)? = null

    val count: Int get() = subscribers.size

    fun subscribe(): LinkedBlockingQueue<String> {
        val q = LinkedBlockingQueue<String>(256)
        subscribers.add(q)
        onSubscribersChanged?.invoke(subscribers.size)
        return q
    }

    fun unsubscribe(q: LinkedBlockingQueue<String>) {
        if (subscribers.remove(q)) onSubscribersChanged?.invoke(subscribers.size)
    }

    /**
     * 马上给所有事件流发一行 ping。Mac 觉得事件流太久没动静时会请求 /api/info 问一下，
     * 这时手机多半刚从深睡里被叫醒：发 ping 的 20 秒计时只在 CPU 醒着时走，等不到它，要当场回一声
     */
    fun ping() = subscribers.forEach { it.offer(": ping\n\n") }

    fun publish(event: String, data: JSONObject) {
        // JSONObject.toString() 不含换行，正好是一行 SSE data
        val msg = "event: $event\ndata: $data\n\n"
        subscribers.forEach { it.offer(msg) }
    }
}
