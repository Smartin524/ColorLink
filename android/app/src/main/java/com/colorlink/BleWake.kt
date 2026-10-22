package com.colorlink

import android.Manifest
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid

private const val TAG = "ColorLink.Ble"

/**
 * 蓝牙唤醒：把“扫描 Mac 的广播”这件事交给系统做。
 *
 * 用 PendingIntent 方式注册后，扫描由系统（通常是蓝牙芯片的硬件过滤器）执行，
 * 我们的进程死了也照样有效；扫到 Mac 时系统发广播给 WakeReceiver，把 App 拉起来。
 *
 * 没用 CompanionDeviceManager：它按蓝牙地址识别设备，而 Mac 广播用的是会定期变化的随机地址。
 * 这里按服务 UUID 过滤，不受地址变化影响。
 */
object BleWake {
    const val ACTION = "com.colorlink.BLE_WAKE"

    /** 与 Mac 端 BLEBeacon.serviceUUID 保持一致。 */
    val SERVICE_UUID: ParcelUuid = ParcelUuid.fromString("7A1C3F0E-5B2D-4E8A-9C61-3D4F2B8E9A10")

    fun hasPermission(ctx: Context) = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
        ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED

    /** 返回是否注册成功。重复调用没关系，系统会替换掉旧的。 */
    fun register(ctx: Context): Boolean {
        if (!hasPermission(ctx)) {
            AppLog.i(TAG, "未授予蓝牙扫描权限（或系统低于 Android 12），跳过蓝牙唤醒")
            return false
        }
        val adapter = ctx.getSystemService(BluetoothManager::class.java)?.adapter ?: return false
        val scanner = adapter.bluetoothLeScanner ?: return false // 蓝牙关着

        // 支持硬件过滤时只在“出现 / 消失”各通知一次，否则每个广播包都会唤醒一次
        val callbackType = if (adapter.isOffloadedFilteringSupported) {
            ScanSettings.CALLBACK_TYPE_FIRST_MATCH or ScanSettings.CALLBACK_TYPE_MATCH_LOST
        } else {
            ScanSettings.CALLBACK_TYPE_ALL_MATCHES
        }
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .setCallbackType(callbackType)
            .build()
        val filters = listOf(ScanFilter.Builder().setServiceUuid(SERVICE_UUID).build())

        return try {
            val code = scanner.startScan(filters, settings, pendingIntent(ctx))
            AppLog.i(TAG, "蓝牙唤醒已注册（硬件过滤：${adapter.isOffloadedFilteringSupported}），结果 $code")
            code == 0
        } catch (e: SecurityException) {
            AppLog.w(TAG, "注册蓝牙唤醒失败", e)
            false
        }
    }

    private fun pendingIntent(ctx: Context): PendingIntent = PendingIntent.getBroadcast(
        ctx,
        1,
        Intent(ctx, WakeReceiver::class.java).setAction(ACTION),
        // 必须可变：系统要往里面塞扫描结果
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )
}
