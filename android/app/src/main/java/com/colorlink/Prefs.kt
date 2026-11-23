package com.colorlink

import android.content.Context
import java.security.SecureRandom
import java.util.UUID

/** 本机持久化配置：设备 ID、访问令牌、配对码、运行模式。 */
object Prefs {
    private const val NAME = "colorlink"
    private val random = SecureRandom()

    fun sp(ctx: Context) = ctx.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    private fun getOrCreate(ctx: Context, key: String, create: () -> String): String {
        val p = sp(ctx)
        p.getString(key, null)?.let { return it }
        return create().also { p.edit().putString(key, it).apply() }
    }

    fun deviceId(ctx: Context) = getOrCreate(ctx, "deviceId") { UUID.randomUUID().toString() }

    /** 已配对的电脑共用这个令牌；重置它等于取消所有电脑的配对。 */
    fun token(ctx: Context) = getOrCreate(ctx, "token") { randomHex(32) }

    fun resetToken(ctx: Context) {
        sp(ctx).edit().putString("token", randomHex(32)).putBoolean("paired", false).apply()
    }

    /** 有没有电脑配对过；配对过之后设置页就不再常驻显示配对码 */
    fun paired(ctx: Context) = sp(ctx).getBoolean("paired", false)

    fun setPaired(ctx: Context) {
        sp(ctx).edit().putBoolean("paired", true).apply()
    }

    fun pairCode(ctx: Context) = getOrCreate(ctx, "pairCode") { randomCode() }

    fun resetPairCode(ctx: Context) {
        sp(ctx).edit().putString("pairCode", randomCode()).apply()
    }

    /** 总开关默认开启，升级不改变现有使用习惯；关闭不清除配对。 */
    fun connectionEnabled(ctx: Context) = sp(ctx).getBoolean("connectionEnabled", true)

    fun setConnectionEnabled(ctx: Context, value: Boolean) {
        sp(ctx).edit().putBoolean("connectionEnabled", value).apply()
    }

    /**
     * 空闲时也用前台服务保活。默认开：前台服务的进程优先级更高，ColorOS 清理和冻结时都会放过它；
     * 代价是通知栏底部多一条折叠、不显示状态栏图标、不响不振的「待命中」通知。
     */
    fun keepAlive(ctx: Context) = sp(ctx).getBoolean("keepAlive", true)

    fun setKeepAlive(ctx: Context, value: Boolean) {
        sp(ctx).edit().putBoolean("keepAlive", value).apply()
    }

    /** 最近一次连上来的 Mac 的 IP，手机醒来时直接给它“敲门”。 */
    fun lastMac(ctx: Context): String? = sp(ctx).getString("lastMac", null)

    /** 最近连上来过的几台电脑的 IP（最新的在前），手机醒来时都敲一下 */
    fun recentMacs(ctx: Context): List<String> =
        sp(ctx).getString("recentMacs", null)?.split(',')?.filter { it.isNotBlank() } ?: listOfNotNull(lastMac(ctx))

    fun setLastMac(ctx: Context, host: String) {
        val recent = (listOf(host) + recentMacs(ctx).filter { it != host }).take(4)
        if (host == lastMac(ctx) && recent == recentMacs(ctx)) return
        sp(ctx).edit().putString("lastMac", host).putString("recentMacs", recent.joinToString(",")).apply()
    }

    /** ColorOS 不让 App 查询的设置项，只能由用户设好后手动打勾。 */
    fun confirmed(ctx: Context, key: String) = sp(ctx).getBoolean("ok_$key", false)

    fun setConfirmed(ctx: Context, key: String, value: Boolean) {
        sp(ctx).edit().putBoolean("ok_$key", value).apply()
    }

    private fun randomCode() = "%06d".format(random.nextInt(1_000_000))

    private fun randomHex(bytes: Int): String {
        val b = ByteArray(bytes).also { random.nextBytes(it) }
        return b.joinToString("") { "%02x".format(it) }
    }
}
