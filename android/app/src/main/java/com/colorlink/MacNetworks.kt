package com.colorlink

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

private const val TAG = "ColorLink.Net"

/**
 * 连过 Mac 的网络。蓝牙唤醒只在这些网络里（或开着热点时）扫描：咖啡店、公司这类 Mac 不在的地方不扫，
 * 既省电，也免得长时间后台扫描让 ColorOS 把 ColorLink 当成耗电应用结束掉。
 *
 * 用「网段 + 网关 + DNS」认网络，不需要定位权限（读 Wi-Fi 名称要定位）。
 * 别处碰巧完全一样的话只是多扫一会儿，没有坏处。一个都没记过时照旧：有局域网就扫。
 */
object MacNetworks {
    private const val KEY = "macNetworks"
    private const val MAX = 8

    private class Lan(val iface: String, val signature: String, val network: Int, val mask: Int)

    /** 手机当前连着的 Wi-Fi（不含自己开的热点） */
    @Suppress("DEPRECATION")
    private fun wifiLans(ctx: Context): List<Lan> {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        return cm.allNetworks.mapNotNull { n ->
            if (cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) != true) return@mapNotNull null
            val lp = cm.getLinkProperties(n) ?: return@mapNotNull null
            val la = lp.linkAddresses.firstOrNull { it.address is Inet4Address } ?: return@mapNotNull null
            val mask = if (la.prefixLength == 0) 0 else -1 shl (32 - la.prefixLength)
            val network = toInt(la.address) and mask
            val gateway = lp.routes.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress ?: "-"
            val dns = lp.dnsServers.filterIsInstance<Inet4Address>().mapNotNull { it.hostAddress }.sorted().joinToString(",")
            Lan(lp.interfaceName ?: "", "${toIp(network)}/${la.prefixLength}|$gateway|$dns", network, mask)
        }
    }

    /** Mac 刚连上：它所在的那个 Wi-Fi 记下来（Mac 连的是手机热点就不用记） */
    fun remember(ctx: Context) {
        val mac = Prefs.lastMac(ctx)?.let { runCatching { InetAddress.getByName(it) }.getOrNull() } as? Inet4Address ?: return
        val lan = wifiLans(ctx).firstOrNull { (toInt(mac) and it.mask) == it.network } ?: return
        val known = known(ctx)
        if (lan.signature in known) return
        val updated = (known.toList() + lan.signature).takeLast(MAX).toSet()
        Prefs.sp(ctx).edit().putStringSet(KEY, updated).apply()
        AppLog.i(TAG, "记住 Mac 所在的网络：${lan.signature}（共 ${updated.size} 个）")
    }

    /** 现在值不值得扫描蓝牙：在连过 Mac 的网络里，或者开着热点 */
    fun shouldScan(ctx: Context): Boolean {
        val known = known(ctx)
        if (known.isEmpty()) return hasLan()
        val lans = wifiLans(ctx)
        return lans.any { it.signature in known } || hotspotOn(lans.map { it.iface }.toSet())
    }

    private fun known(ctx: Context): Set<String> = Prefs.sp(ctx).getStringSet(KEY, emptySet()).orEmpty()

    /** 除了连着的 Wi-Fi 之外还有局域网网卡（有 IPv4、不是流量和 VPN），就是手机在开热点 */
    private fun hotspotOn(wifiIfaces: Set<String>): Boolean = runCatching {
        NetworkInterface.getNetworkInterfaces().toList().any { nif ->
            nif.isUp && !nif.isLoopback && !isCellular(nif.name) && nif.name !in wifiIfaces &&
                !nif.name.startsWith("tun") && !nif.name.startsWith("ppp") && !nif.name.startsWith("ipsec") &&
                nif.inetAddresses.toList().any { it is Inet4Address }
        }
    }.getOrDefault(false)

    private fun toInt(a: InetAddress) = a.address.fold(0) { acc, b -> (acc shl 8) or (b.toInt() and 0xFF) }

    private fun toIp(n: Int) = "${n ushr 24 and 0xFF}.${n ushr 16 and 0xFF}.${n ushr 8 and 0xFF}.${n and 0xFF}"
}
