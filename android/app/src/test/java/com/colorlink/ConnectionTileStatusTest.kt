package com.colorlink

import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectionTileStatusTest {
    @Test fun pauseWinsOverLingeringConnectionDuringShutdown() {
        assertEquals(ConnectionTileStatus.PAUSED, ConnectionTileStatus.resolve(false, true, true))
    }

    @Test fun enabledDoesNotImplyConnected() {
        assertEquals(ConnectionTileStatus.DISCONNECTED, ConnectionTileStatus.resolve(true, true, false))
        assertEquals(ConnectionTileStatus.CONNECTED, ConnectionTileStatus.resolve(true, true, true))
    }

    @Test fun unpairedDeviceShowsSetupState() {
        assertEquals(ConnectionTileStatus.UNPAIRED, ConnectionTileStatus.resolve(true, false, false))
    }

    @Test fun multipleSubscribersAndListenerRemovalAreHandled() {
        var notifications = 0
        val listener: () -> Unit = { notifications++ }
        EventBus.addConnectionListener(listener)
        val first = EventBus.subscribe("A", null)
        val second = EventBus.subscribe("A", null)
        try {
            assertEquals(2, notifications)
            EventBus.unsubscribe(first)
            assertEquals(1, EventBus.count)
            assertEquals(3, notifications)
            EventBus.removeConnectionListener(listener)
            EventBus.unsubscribe(second)
            assertEquals(3, notifications)
        } finally {
            EventBus.removeConnectionListener(listener)
            EventBus.unsubscribe(first)
            EventBus.unsubscribe(second)
        }
    }

    @Test fun twoComputersAreTrackedSeparately() {
        val macA = java.net.InetAddress.getByName("192.168.1.10")
        val macB = java.net.InetAddress.getByName("192.168.1.20")
        val a1 = EventBus.subscribe("MacBook", macA)
        val a2 = EventBus.subscribe("MacBook", macA) // 同一台电脑的第二个连接
        val b = EventBus.subscribe("iMac", macB)
        try {
            assertEquals(listOf("MacBook", "iMac"), EventBus.computers().map { it.name })
            assertEquals("192.168.1.20", EventBus.computers()[1].address)
            assertEquals("iMac", EventBus.nameFor(macB))
            assertEquals(null, EventBus.nameFor(java.net.InetAddress.getByName("192.168.1.30")))
            // 只发给 iMac
            EventBus.publish("clipboard", org.json.JSONObject(), to = "iMac")
            assertEquals(0, a1.queue.size)
            assertEquals(1, b.queue.size)
            // 不指定就都发
            EventBus.publish("clipboard", org.json.JSONObject())
            assertEquals(1, a1.queue.size)
            assertEquals(1, a2.queue.size)
            assertEquals(2, b.queue.size)
        } finally {
            EventBus.unsubscribe(a1)
            EventBus.unsubscribe(a2)
            EventBus.unsubscribe(b)
        }
    }
}
