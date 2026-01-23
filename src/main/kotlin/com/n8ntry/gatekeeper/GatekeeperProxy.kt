package com.n8ntry.gatekeeper

import io.ktor.client.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.websocket.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.plugins.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.websocket.*
import io.ktor.util.*
import io.ktor.utils.io.*
import io.ktor.utils.io.jvm.javaio.*
import io.ktor.websocket.*
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.launch
import java.io.IOException

class GatekeeperProxy(private val app: Application) {
    private val targetHost = "127.0.0.1"
    private val targetPort = 5679
    
    companion object {
        private const val TAG = "GatekeeperProxy"
    }

    private val client = HttpClient(CIO) {
        install(io.ktor.client.plugins.websocket.WebSockets)
        followRedirects = false
    }

    fun setup() {
        app.routing {
            // WebSocket Tunneling
            webSocket("/{...}") {
                val remoteIp = call.request.origin.remoteHost
                val path = call.request.uri
                android.util.Log.d(TAG, "WS Connect: $remoteIp -> $path")
                
                if (!WhitelistDatabase.isWhitelisted(remoteIp)) {
                    android.util.Log.w(TAG, "WS BLOCKED: $remoteIp")
                    call.respond(HttpStatusCode.Forbidden)
                    ConnectionWatchdog.notifySecurityEvent(remoteIp)
                    close(CloseReason(CloseReason.Codes.VIOLATED_POLICY, "Forbidden"))
                    return@webSocket
                }
                
                android.util.Log.d(TAG, "WS Allowed: Proxying to ws://$targetHost:$targetPort$path")

                try {
                    client.webSocket("ws://$targetHost:$targetPort$path") {
                        val serverSession = this
                        val clientSession = this@webSocket

                        val serverToClient = launch {
                            try {
                                for (frame in serverSession.incoming) {
                                    clientSession.outgoing.send(frame)
                                }
                            } catch (e: Exception) {
                                // Ignore closing errors
                            }
                        }

                        val clientToServer = launch {
                            try {
                                for (frame in clientSession.incoming) {
                                    serverSession.outgoing.send(frame)
                                }
                            } catch (e: Exception) {
                                // Ignore closing errors
                            }
                        }

                        serverToClient.join()
                        clientToServer.join()
                    }
                } catch (e: Exception) {
                    android.util.Log.e(TAG, "WS Proxy Error", e)
                    ConnectionWatchdog.reportFailure()
                }
            }

            // HTTP Streaming Proxy
            get("/{...}") { handleHttp(call) }
            post("/{...}") { handleHttp(call) }
            put("/{...}") { handleHttp(call) }
            delete("/{...}") { handleHttp(call) }
            patch("/{...}") { handleHttp(call) }
            options("/{...}") { handleHttp(call) }
            head("/{...}") { handleHttp(call) }
        }
    }

    private suspend fun handleHttp(call: ApplicationCall) {
        val remoteIp = call.request.origin.remoteHost
        val path = call.request.uri
        val method = call.request.httpMethod.value
        
        android.util.Log.d(TAG, "HTTP $method: $remoteIp -> $path")

        if (!WhitelistDatabase.isWhitelisted(remoteIp)) {
            android.util.Log.w(TAG, "HTTP BLOCKED: $remoteIp")
            call.respond(HttpStatusCode.Forbidden, "Access Denied")
            ConnectionWatchdog.notifySecurityEvent(remoteIp)
            return
        }

        try {
            val response = client.request("http://$targetHost:$targetPort$path") {
                this.method = call.request.httpMethod
                headers {
                    appendAll(call.request.headers)
                    set("X-Forwarded-For", remoteIp)
                    set("X-Forwarded-Proto", "http")
                    set("Host", "127.0.0.1") // Crucial for some backend checks
                }
                if (call.request.httpMethod.value in listOf("POST", "PUT", "PATCH")) {
                   setBody(call.receiveChannel())
                }
            }

            call.respondOutputStream(
                status = response.status,
                contentType = response.contentType()
            ) {
                val buffer = ByteArray(8192) // 8KB buffer
                val inputStream = response.bodyAsChannel().toInputStream()
                var bytesRead: Int
                while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                    write(buffer, 0, bytesRead)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "HTTP Proxy Error to $path", e)
            if (e is IOException) {
                ConnectionWatchdog.reportFailure()
            }
            call.respond(HttpStatusCode.BadGateway)
        }
    }
}
