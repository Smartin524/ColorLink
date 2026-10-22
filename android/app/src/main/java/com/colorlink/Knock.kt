package com.colorlink

import android.content.Context
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

private const val TAG = "ColorLink.Knock"

/**
 * 手机主动“敲门”：醒来、换网络时发一个 UDP 包给 Mac，Mac 收到就立刻来连，不用等它的重试计时。
 *
 * 为什么需要：ColorOS 锁屏后 Wi-Fi 芯片会过滤组播包，Mac 发来的 mDNS 查询手机收不到，
 * Mac 就只能按退避间隔（最长 15 秒）盲目重试。发包不受这个限制。
 *
 * 包里带 HMAC 签名（密钥是配对令牌），Mac 验证通过才会去连，防止别人冒充手机骗走令牌。
 */
object Knock {
    const val PORT = 8766

    fun send(ctx: Context, httpPort: Int) {
        // 没有 Wi-Fi / 热点（飞行模式、只开流量）时 Mac 不可能在局域网里；
        // 不跳过的话，发给 Mac 旧地址的那一包会走流量，白白唤醒蜂窝基带
        if (!hasLan()) {
            AppLog.i(TAG, "没有 Wi-Fi 或热点，不敲门")
            return
        }
        val id = Prefs.deviceId(ctx)
        val ts = System.currentTimeMillis() / 1000
        val payload = JSONObject()
            .put("v", 1)
            .put("id", id)
            .put("port", httpPort)
            .put("ts", ts)
            .put("sig", sign(Prefs.token(ctx), "$id|$httpPort|$ts"))
            .toString()
            .toByteArray()

        val targets = buildList {
            Prefs.lastMac(ctx)?.let { host -> runCatching { InetAddress.getByName(host) }.getOrNull()?.let(::add) }
            addAll(broadcastAddresses()) // Mac 换了 IP 时靠广播找到它
        }.distinct()
        if (targets.isEmpty()) return
        try {
            DatagramSocket().use { s ->
                s.broadcast = true
                for (t in targets) {
                    runCatching { s.send(DatagramPacket(payload, payload.size, t, PORT)) }
                        .onFailure { AppLog.w(TAG, "敲门 $t 失败：${it.message}") }
                }
            }
            AppLog.i(TAG, "已敲门：${targets.joinToString { it.hostAddress ?: "?" }}")
        } catch (e: Exception) {
            AppLog.w(TAG, "敲门失败", e)
        }
    }

    fun sign(token: String, message: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(token.toByteArray(), "HmacSHA256"))
        return mac.doFinal(message.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    /**
     * 所有局域网网卡的广播地址：Wi-Fi，以及开热点时的热点网卡（Mac 连着手机热点时只能靠它）。
     * 不能只看“当前上网的网络”：开热点时那是移动数据，广播发不到热点里的 Mac。
     */
    private fun broadcastAddresses(): List<InetAddress> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !isCellular(it.name) }
            .flatMap { it.interfaceAddresses }
            .filter { it.address is Inet4Address }
            .mapNotNull { it.broadcast }
    }.getOrDefault(emptyList())
}

/** 移动数据网卡（高通 rmnet、联发科 ccmni 等），不是局域网。 */
fun isCellular(ifName: String) = ifName.startsWith("rmnet") || ifName.startsWith("ccmni") ||
    ifName.startsWith("v4-") || ifName.startsWith("dummy") || ifName.startsWith("tun")

/** 手机所有局域网 IPv4 地址（Wi-Fi、热点），设置页和通知里显示用。 */
/** 有没有可能找到 Mac 的局域网（Wi-Fi 或热点）。VPN 隧道不算 */
fun hasLan(): Boolean = runCatching {
    NetworkInterface.getNetworkInterfaces().toList().any { nif ->
        nif.isUp && !nif.isLoopback && !isCellular(nif.name) &&
            !nif.name.startsWith("tun") && !nif.name.startsWith("ppp") && !nif.name.startsWith("ipsec") &&
            nif.inetAddresses.toList().any { it is Inet4Address }
    }
}.getOrDefault(true)

fun lanIpv4s(): List<String> = runCatching {
    NetworkInterface.getNetworkInterfaces().toList()
        .filter { it.isUp && !it.isLoopback && !isCellular(it.name) }
        .flatMap { it.inetAddresses.toList() }
        .filterIsInstance<Inet4Address>()
        .mapNotNull { it.hostAddress }
}.getOrDefault(emptyList())
