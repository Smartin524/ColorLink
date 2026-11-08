package com.colorlink

import org.junit.Assert.*
import org.junit.Test
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class HttpServerTest {
    @Test fun stopClosesIdleKeepAliveClientAndAllowsNewServer() {
        val server = HttpServer { Response.text(200, "ok") }
        server.start(0)
        val port = server.port
        try {
            Socket("127.0.0.1", port).use { client ->
                client.soTimeout = 2_000
                client.getOutputStream().write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                val reader = client.getInputStream().bufferedReader()
                assertEquals("HTTP/1.1 200 OK", reader.readLine())
                while (reader.readLine().isNotEmpty()) { }
                assertEquals('o'.code, reader.read())
                assertEquals('k'.code, reader.read())
                server.stop()
                assertEquals(-1, reader.read())
            }
            val resumed = HttpServer { Response.text(200, "resumed") }
            try {
                resumed.start(port)
                assertEquals(port, resumed.port)
            } finally {
                resumed.stop()
            }
        } finally {
            server.stop()
        }
    }

    @Test fun stopInterruptsEventStreamAndClosesTransport() {
        val entered = CountDownLatch(1)
        val ended = CountDownLatch(1)
        val server = HttpServer {
            Response(200, body = Response.Body.Streaming {
                entered.countDown()
                try {
                    CountDownLatch(1).await()
                } catch (_: InterruptedException) {
                    // SSE 的订阅清理也在 writer 的 finally 中执行。
                } finally {
                    ended.countDown()
                }
            })
        }
        server.start(0)
        try {
            Socket("127.0.0.1", server.port).use { client ->
                client.soTimeout = 2_000
                client.getOutputStream().write("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                assertTrue(entered.await(2, TimeUnit.SECONDS))
                server.stop()
                assertTrue(ended.await(2, TimeUnit.SECONDS))
                try {
                    while (client.getInputStream().read() != -1) { }
                } catch (_: SocketException) {
                    // 关闭时 TCP reset 也意味着传输已经终止；超时不能通过。
                }
            }
        } finally {
            server.stop()
        }
    }
}
