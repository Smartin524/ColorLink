package com.colorlink

import android.content.SharedPreferences
import android.graphics.drawable.Icon
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Connection switch and live status. Refresh whenever the shade opens, including after process death. */
class StatusTileService : TileService() {
    private val main = Handler(Looper.getMainLooper())
    private var listening = false
    private val connectionListener: () -> Unit = { requestRender() }
    private val preferencesListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == "connectionEnabled" || key == "paired") requestRender()
    }

    override fun onStartListening() {
        super.onStartListening()
        if (!listening) {
            listening = true
            EventBus.addConnectionListener(connectionListener)
            Prefs.sp(this).registerOnSharedPreferenceChangeListener(preferencesListener)
        }
        render()
    }

    override fun onStopListening() {
        stopListening()
        super.onStopListening()
    }

    override fun onDestroy() {
        stopListening()
        super.onDestroy()
    }

    private fun stopListening() {
        listening = false
        EventBus.removeConnectionListener(connectionListener)
        Prefs.sp(this).unregisterOnSharedPreferenceChangeListener(preferencesListener)
        main.removeCallbacksAndMessages(null)
    }

    private fun requestRender() {
        main.post { if (listening) render() }
    }

    private fun render() {
        val tile = qsTile ?: return
        val enabled = Prefs.connectionEnabled(this)
        val status = ConnectionTileStatus.resolve(
            enabled = enabled,
            paired = Prefs.paired(this),
            connected = LinkCore.running && EventBus.count > 0,
        )
        tile.label = getString(R.string.app_name)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tile_link)
        tile.subtitle = status.label
        tile.stateDescription = status.label
        tile.contentDescription = "${tile.label}，${status.label}"
        // Highlight reflects the switch, while subtitle reports the actual connection.
        tile.state = if (enabled) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        val toggle = Runnable {
            ConnectionControl.setEnabled(this, !Prefs.connectionEnabled(this))
            render()
        }
        if (isLocked) unlockAndRun(toggle) else toggle.run()
    }
}

internal enum class ConnectionTileStatus(val label: String) {
    PAUSED("已暂停"), UNPAIRED("待配对"), CONNECTED("已连接"), DISCONNECTED("未连接");

    companion object {
        fun resolve(enabled: Boolean, paired: Boolean, connected: Boolean) = when {
            !enabled -> PAUSED
            !paired -> UNPAIRED
            connected -> CONNECTED
            else -> DISCONNECTED
        }
    }
}
