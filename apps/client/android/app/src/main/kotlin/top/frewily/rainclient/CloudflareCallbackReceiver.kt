package top.frewily.rainclient

import android.net.Uri
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors
import java.util.Timer
import java.util.TimerTask

/** Socket I/O stays off Flutter's UI isolate. OAuth values never enter logs/files. */
object CloudflareCallbackReceiver {
    private var window: Window? = null

    @Synchronized fun start(owner: String, state: String) {
        window?.close()
        window = Window(owner, state).also { it.start() }
    }
    @Synchronized fun await(owner: String, result: MethodChannel.Result) {
        val active = window
        if (active == null || active.owner != owner) {
            result.error("callback_cancelled", "本次授权已停止", null)
        } else active.await(result)
    }
    @Synchronized fun stop(owner: String): Boolean {
        val active = window
        if (active == null || active.owner != owner) return false
        window = null
        active.close()
        return true
    }

    private class Window(val owner: String, private var expectedState: String) {
        private val server = ServerSocket().apply {
            reuseAddress = false
            bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 8765))
        }
        private val clients = CopyOnWriteArraySet<Socket>()
        private val workers = Executors.newFixedThreadPool(2)
        private val expiry = Timer("rain-auth-expiry", true)
        @Volatile private var closed = false
        private var handled = false
        private var savedUri: String? = null
        private var waiter: MethodChannel.Result? = null

        fun start() {
            expiry.schedule(object : TimerTask() { override fun run() { close() } }, 10 * 60 * 1000L)
            Thread({
                while (!closed) {
                    try {
                        val socket = server.accept()
                        clients.add(socket)
                        workers.execute { handle(socket) }
                    } catch (_: Exception) { if (!closed) close(); break }
                }
            }, "rain-auth-return").apply { isDaemon = true; start() }
        }

        @Synchronized fun await(result: MethodChannel.Result) {
            if (closed || waiter != null) {
                result.error("callback_cancelled", "本次授权已停止", null)
            } else if (savedUri != null) {
                val value = savedUri; savedUri = null
                result.success(value)
            } else waiter = result
        }

        private fun line(input: java.io.InputStream): String? {
            val bytes = ArrayList<Byte>()
            while (bytes.size <= 4096) {
                val value = input.read()
                if (value < 0) return null
                if (value == 10) return bytes.toByteArray().toString(Charsets.US_ASCII).trimEnd('\r')
                bytes.add(value.toByte())
            }
            return null
        }

        private fun handle(socket: Socket) {
            try {
                socket.soTimeout = 3000
                val input = socket.getInputStream()
                val request = line(input)?.split(' ') ?: return
                if (request.size != 3) return
                var host: String? = null
                var end = false
                for (index in 0 until 32) {
                    val header = line(input) ?: return
                    if (header.isEmpty()) { end = true; break }
                    if (header.startsWith("Host:", true)) {
                        if (host != null) return
                        host = header.substringAfter(':').trim()
                    }
                }
                if (!end) return
                val target = request[1]
                if (request[0] != "GET" || host != "127.0.0.1:8765" ||
                    !target.startsWith("/") || target.startsWith("//")) {
                    respond(socket, 404); return
                }
                val uri = Uri.parse("http://127.0.0.1:8765$target")
                if (uri.path != "/cloudflare/callback") { respond(socket, 404); return }
                val states = uri.getQueryParameters("state")
                val codes = uri.getQueryParameters("code")
                val errors = uri.getQueryParameters("error")
                synchronized(this) {
                    if (closed) return
                    if (handled) { respond(socket, 200); return }
                    if (states.size != 1 || states.single() != expectedState ||
                        (errors.isEmpty() && (codes.size != 1 || !Regex("^[!-~]{1,2048}$").matches(codes.single())))) {
                        respond(socket, 403); return
                    }
                    handled = true
                    savedUri = uri.toString()
                    expectedState = ""
                    respond(socket, 200)
                    waiter?.let { pending ->
                        val value = savedUri; savedUri = null; waiter = null
                        pending.success(value)
                    }
                }
            } catch (_: Exception) {
                // No URL, state, code, headers or third-party error text is logged.
            } finally {
                clients.remove(socket)
                try { socket.close() } catch (_: Exception) { }
            }
        }

        private fun respond(socket: Socket, status: Int) {
            val page = if (status == 200) """<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>返回雨课堂管理</title><body style="font:18px system-ui;padding:32px;line-height:1.8"><h2>已收到授权结果</h2><p>请返回雨课堂管理应用，查看账号验证结果。</p><script nonce="return">history.replaceState(null,'','/cloudflare/complete');</script>""" else ""
            val data = page.toByteArray(Charsets.UTF_8)
            val headers = "HTTP/1.1 $status ${if(status==200) "OK" else "Not found"}\r\n" +
                "Content-Type: text/html; charset=utf-8\r\nContent-Length: ${data.size}\r\n" +
                "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n" +
                "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-return'; base-uri 'none'; form-action 'none'\r\nConnection: close\r\n\r\n"
            socket.getOutputStream().apply { write(headers.toByteArray(Charsets.US_ASCII)); write(data); flush() }
        }

        @Synchronized fun close() {
            if (closed) return
            closed = true; savedUri = null; expectedState = ""
            try { server.close() } catch (_: Exception) { }
            clients.forEach { try { it.close() } catch (_: Exception) { } }
            clients.clear(); workers.shutdownNow(); expiry.cancel()
            waiter?.error("callback_cancelled", "本次授权已停止", null); waiter = null
        }
    }
}
