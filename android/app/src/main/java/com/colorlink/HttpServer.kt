package com.colorlink

import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URLDecoder
import java.util.concurrent.Executors
import kotlin.concurrent.thread

private const val TAG = "ColorLink.Http"

class Request(
    val method: String,
    val path: String,
    val query: Map<String, String>,
    private val headers: Map<String, String>,
    val remote: InetAddress,
    /** 请求体（按 Content-Length 截断）。处理完没读完的部分由服务器丢弃。 */
    val body: InputStream,
) {
    fun header(name: String): String? = headers[name.lowercase()]
    fun q(name: String): String? = query[name]
}

class Response(
    val status: Int,
    val headers: MutableMap<String, String> = mutableMapOf(),
    val body: Body,
) {
    sealed class Body {
        class Bytes(val data: ByteArray) : Body()
        class Stream(val input: InputStream, val length: Long) : Body()
        /** 长连接（SSE）：写完即关闭连接。 */
        class Streaming(val writer: (OutputStream) -> Unit) : Body()
    }

    companion object {
        fun json(obj: Any, status: Int = 200) = Response(
            status,
            mutableMapOf("Content-Type" to "application/json; charset=utf-8"),
            Body.Bytes(obj.toString().toByteArray()),
        )

        fun text(status: Int, msg: String) = Response(
            status,
            mutableMapOf("Content-Type" to "text/plain; charset=utf-8"),
            Body.Bytes(msg.toByteArray()),
        )

        fun bytes(data: ByteArray, type: String, extra: Map<String, String> = emptyMap()) =
            Response(200, (mapOf("Content-Type" to type) + extra).toMutableMap(), Body.Bytes(data))
    }
}

/**
 * 极简 HTTP/1.1 服务器：支持 keep-alive、Range（由 Api 处理）和 SSE 长连接。
 * 只服务局域网里的一台 Mac，所以用线程池 + 阻塞 IO 就够了，不引入第三方库。
 */
class HttpServer(private val handler: (Request) -> Response) {
    private var socket: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool()

    @Volatile
    var port = 0
        private set

    fun start(preferredPort: Int) {
        val s = try {
            ServerSocket(preferredPort)
        } catch (e: IOException) {
            Log.w(TAG, "端口 $preferredPort 被占用，改用随机端口")
            ServerSocket(0)
        }
        socket = s
        port = s.localPort
        thread(name = "http-accept", isDaemon = true) {
            while (!s.isClosed) {
                val client = try {
                    s.accept()
                } catch (e: IOException) {
                    break
                }
                pool.execute { serve(client) }
            }
        }
        Log.i(TAG, "监听端口 $port")
    }

    fun stop() {
        try {
            socket?.close()
        } catch (_: IOException) {
        }
        pool.shutdownNow()
    }

    private fun serve(client: Socket) {
        try {
            client.use { s ->
                s.tcpNoDelay = true
                s.soTimeout = 15_000
                val input = BufferedInputStream(s.getInputStream())
                val output = BufferedOutputStream(s.getOutputStream(), 64 * 1024)
                while (true) {
                    val req = readRequest(input, s.inetAddress) ?: break
                    val resp = try {
                        handler(req)
                    } catch (e: Exception) {
                        Log.w(TAG, "处理 ${req.path} 出错", e)
                        Response.text(500, e.toString())
                    }
                    // 读掉没用完的请求体，保证 keep-alive 下一个请求能对齐
                    (req.body as BoundedInputStream).drain()
                    if (!write(output, req, resp)) break
                    if (req.header("connection").equals("close", ignoreCase = true)) break
                }
            }
        } catch (_: IOException) {
            // 对方断开，正常情况
        }
    }

    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val c = input.read()
            if (c == -1) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(c.toChar())
            if (sb.length > 16 * 1024) throw IOException("请求行过长")
        }
    }

    private fun readRequest(input: InputStream, remote: InetAddress): Request? {
        var line: String
        do {
            line = try {
                readLine(input)
            } catch (_: SocketTimeoutException) {
                null
            } ?: return null
        } while (line.isEmpty())

        val parts = line.split(" ")
        if (parts.size < 2) return null

        val headers = mutableMapOf<String, String>()
        while (true) {
            val h = readLine(input) ?: return null
            if (h.isEmpty()) break
            val i = h.indexOf(':')
            if (i > 0) headers[h.substring(0, i).trim().lowercase()] = h.substring(i + 1).trim()
        }
        val body = BoundedInputStream(input, headers["content-length"]?.toLongOrNull() ?: 0)

        val target = parts[1]
        val qi = target.indexOf('?')
        val path = URLDecoder.decode(if (qi >= 0) target.substring(0, qi) else target, "UTF-8")
        val query = if (qi >= 0) parseQuery(target.substring(qi + 1)) else emptyMap()
        return Request(parts[0].uppercase(), path, query, headers, remote, body)
    }

    private fun parseQuery(s: String): Map<String, String> = s.split('&')
        .filter { it.isNotEmpty() }
        .associate {
            val i = it.indexOf('=')
            if (i < 0) URLDecoder.decode(it, "UTF-8") to ""
            else URLDecoder.decode(it.substring(0, i), "UTF-8") to URLDecoder.decode(it.substring(i + 1), "UTF-8")
        }

    /** 返回 true 表示连接可以复用。 */
    private fun write(out: OutputStream, req: Request, resp: Response): Boolean {
        val body = resp.body
        val length: Long? = when (body) {
            is Response.Body.Bytes -> body.data.size.toLong()
            is Response.Body.Stream -> body.length
            is Response.Body.Streaming -> null
        }
        val keepAlive = length != null
        val head = StringBuilder("HTTP/1.1 ${resp.status} ${reason(resp.status)}\r\n")
        if (length != null) head.append("Content-Length: $length\r\n")
        head.append(if (keepAlive) "Connection: keep-alive\r\n" else "Connection: close\r\n")
        resp.headers.forEach { (k, v) -> head.append(k).append(": ").append(v).append("\r\n") }
        head.append("\r\n")
        out.write(head.toString().toByteArray(Charsets.UTF_8))

        if (req.method == "HEAD") {
            if (body is Response.Body.Stream) body.input.close()
        } else {
            when (body) {
                is Response.Body.Bytes -> out.write(body.data)
                is Response.Body.Stream -> body.input.use { copy(it, out, body.length) }
                is Response.Body.Streaming -> {
                    out.flush()
                    body.writer(out)
                }
            }
        }
        out.flush()
        return keepAlive
    }

    private fun copy(input: InputStream, out: OutputStream, length: Long) {
        val buf = ByteArray(64 * 1024)
        var left = length
        while (left > 0) {
            val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (n < 0) break
            out.write(buf, 0, n)
            left -= n
        }
    }

    private fun reason(status: Int) = when (status) {
        200 -> "OK"
        206 -> "Partial Content"
        400 -> "Bad Request"
        405 -> "Method Not Allowed"
        401 -> "Unauthorized"
        403 -> "Forbidden"
        404 -> "Not Found"
        416 -> "Range Not Satisfiable"
        else -> "Error"
    }
}

/** 只允许读 length 个字节，读完返回 -1；关闭时不关底层连接。 */
private class BoundedInputStream(private val src: InputStream, private var left: Long) : InputStream() {
    override fun read(): Int {
        if (left <= 0) return -1
        val c = src.read()
        if (c >= 0) left-- else left = 0
        return c
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (left <= 0) return -1
        val n = src.read(b, off, minOf(len.toLong(), left).toInt())
        if (n > 0) left -= n else left = 0
        return n
    }

    override fun available(): Int = minOf(src.available().toLong(), left).toInt()

    override fun close() = Unit

    fun drain() {
        val buf = ByteArray(8192)
        while (read(buf, 0, buf.size) >= 0) Unit
    }
}
