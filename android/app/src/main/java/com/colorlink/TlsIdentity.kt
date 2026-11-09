package com.colorlink

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.spec.ECGenParameterSpec
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLServerSocketFactory
import javax.security.auth.x500.X500Principal

private const val TAG = "ColorLink.Tls"
private const val ALIAS = "colorlink-tls"

/**
 * 手机端 HTTPS 用的身份：Android 密钥库里的一对 EC 密钥和系统给它签的自签名证书。
 * 私钥不出密钥库。Mac 不看证书链，配对时记下这张证书的指纹，以后只认它（见 PROTOCOL.md「加密」）
 */
object TlsIdentity {
    fun serverSocketFactory(): SSLServerSocketFactory {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(ALIAS)) generate()
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(ks, null)
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(kmf.keyManagers, null, null)
        ks.getCertificate(ALIAS)?.let { AppLog.i(TAG, "证书指纹 ${fingerprint(it.encoded).take(16)}…") }
        return RestrictedFactory(ctx.serverSocketFactory)
    }

    private fun generate() {
        // DIGEST_NONE：TLS 握手时由 Conscrypt 先算好摘要，再交给密钥库签名
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
            .setCertificateSubject(X500Principal("CN=ColorLink"))
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
        AppLog.i(TAG, "已生成 TLS 密钥")
    }

    fun fingerprint(der: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02x".format(it) }

    /** 只开 TLS 1.2 / 1.3 */
    private class RestrictedFactory(private val base: SSLServerSocketFactory) : SSLServerSocketFactory() {
        override fun getDefaultCipherSuites(): Array<String> = base.defaultCipherSuites
        override fun getSupportedCipherSuites(): Array<String> = base.supportedCipherSuites
        override fun createServerSocket() = restrict(base.createServerSocket())
        override fun createServerSocket(port: Int) = restrict(base.createServerSocket(port))
        override fun createServerSocket(port: Int, backlog: Int) = restrict(base.createServerSocket(port, backlog))
        override fun createServerSocket(port: Int, backlog: Int, addr: java.net.InetAddress?) =
            restrict(base.createServerSocket(port, backlog, addr))

        private fun restrict(s: java.net.ServerSocket) = s.also {
            (it as SSLServerSocket).enabledProtocols = arrayOf("TLSv1.3", "TLSv1.2")
        }
    }
}
