package com.colorlink

import android.content.Context
import java.security.SecureRandom
import java.util.UUID

/** 本机持久化配置：设备 ID、访问令牌、配对码、运行模式。 */
object Prefs {
    private const val NAME = "colorlink"
    private val random = SecureRandom()

    private fun sp(ctx: Context) = ctx.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    private fun getOrCreate(ctx: Context, key: String, create: () -> String): String {
        val p = sp(ctx)
        p.getString(key, null)?.let { return it }
        return create().also { p.edit().putString(key, it).apply() }
    }

    fun deviceId(ctx: Context) = getOrCreate(ctx, "deviceId") { UUID.randomUUID().toString() }

    /** 已配对的电脑共用这个令牌；重置它等于取消所有电脑的配对。 */
    fun token(ctx: Context) = getOrCreate(ctx, "token") { randomHex(32) }

    fun resetToken(ctx: Context) {
        sp(ctx).edit().putString("token", randomHex(32)).apply()
    }

    fun pairCode(ctx: Context) = getOrCreate(ctx, "pairCode") { randomCode() }

    fun resetPairCode(ctx: Context) {
        sp(ctx).edit().putString("pairCode", randomCode()).apply()
    }

    /** 空闲时也用前台服务保活（通知栏会多一条折叠的静默通知）。默认关：平时靠通知监听保活，通知栏里什么都没有。 */
    fun keepAlive(ctx: Context) = sp(ctx).getBoolean("keepAlive", false)

    fun setKeepAlive(ctx: Context, value: Boolean) {
        sp(ctx).edit().putBoolean("keepAlive", value).apply()
    }

    /** 最近一次连上来的 Mac 的 IP，手机醒来时直接给它“敲门”。 */
    fun lastMac(ctx: Context): String? = sp(ctx).getString("lastMac", null)

    fun setLastMac(ctx: Context, host: String) {
        if (host != lastMac(ctx)) sp(ctx).edit().putString("lastMac", host).apply()
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
