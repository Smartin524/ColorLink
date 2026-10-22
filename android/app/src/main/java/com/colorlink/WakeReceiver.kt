package com.colorlink

import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

private const val TAG = "ColorLink.Wake"

/** 所有“把 App 拉起来”的入口：开机、App 更新、蓝牙扫到 Mac。 */
class WakeReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                // 系统扫描在重启后会丢失，要重新注册
                BleWake.register(ctx)
                LinkCore.start(ctx)
                LinkService.refresh(ctx)
            }

            BleWake.ACTION -> {
                val error = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
                if (error != 0) {
                    Log.w(TAG, "蓝牙扫描出错：$error")
                    return
                }
                val type = intent.getIntExtra(BluetoothLeScanner.EXTRA_CALLBACK_TYPE, ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                if (type == ScanSettings.CALLBACK_TYPE_MATCH_LOST) {
                    Log.i(TAG, "Mac 离开了")
                } else if (!LinkCore.running) {
                    Log.i(TAG, "发现 Mac，启动连接核心")
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
