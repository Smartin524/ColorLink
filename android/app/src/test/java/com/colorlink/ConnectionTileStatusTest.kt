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
        val first = EventBus.subscribe()
        val second = EventBus.subscribe()
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
}
