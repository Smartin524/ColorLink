package com.colorlink

import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

private const val TAG = "ColorLink.Wake"

/** 所有“把 App 拉起来”的入口：开机、App 更新、蓝牙扫到 Mac。 */
class WakeReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (!Prefs.connectionEnabled(ctx)) return
        AppLog.init(ctx)
        AppLog.i(TAG, "收到广播 ${intent.action}")
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                // 系统扫描在重启后会丢失，要重新注册（开机时 Wi-Fi 可能还没连上，那就等网络回调再注册）
                LinkCore.start(ctx)
                BleWake.update(ctx)
                LinkService.refresh(ctx)
            }

            BleWake.ACTION -> {
                val error = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
                if (error != 0) {
                    AppLog.w(TAG, "蓝牙扫描出错：$error")
                    return
                }
                val type = intent.getIntExtra(BluetoothLeScanner.EXTRA_CALLBACK_TYPE, ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                if (type == ScanSettings.CALLBACK_TYPE_MATCH_LOST) {
                    AppLog.i(TAG, "Mac 离开了")
                } else if (!hasLan()) {
                    // Mac 就在旁边，但手机没连 Wi-Fi / 热点，连不上；等 Wi-Fi 回来时网络回调会自己敲门
                    AppLog.i(TAG, "发现 Mac，但没有 Wi-Fi 或热点，先不启动")
                } else if (!LinkCore.running) {
                    AppLog.i(TAG, "发现 Mac，启动连接核心")
                    LinkCore.start(ctx) // 启动时会自动敲门
                    LinkService.refresh(ctx)
                } else {
                    // 核心本来就在跑：Mac 可能刚从睡眠中醒来，主动敲门让它马上连
                    LinkCore.knockSoon()
                }
            }
        }
    }
}
