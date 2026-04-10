package com.codexisland.android.shell.runtime

import com.codexisland.android.shell.storage.HostProfile
import com.codexisland.android.shell.storage.HostConnectionMode
import com.codexisland.android.shell.storage.GeneratedSshKeyPair
import com.codexisland.android.shell.storage.SecureShellStore
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.transport.verification.PromiscuousVerifier
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import uniffi.codex_island_client.ClientConnectionState
import uniffi.codex_island_client.ClientRuntimeConfig
import uniffi.codex_island_client.CommandKind
import uniffi.codex_island_client.EngineRuntime
import uniffi.codex_island_client.EngineRuntimeState
import uniffi.codex_island_client.QueuedCommandRecord
import uniffi.codex_island_client.uniffiEnsureInitialized
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

data class EngineRuntimeProbeResult(
    val runtimeLinked: Boolean,
    val engineStatus: String,
    val bindingSurface: String,
    val connection: String,
    val commandQueue: String,
    val pairedDevices: String,
    val reconnect: String,
    val diagnostics: String,
    val lastError: String,
    val helloCommandPreview: String,
    val pairStartCommandPreview: String,
    val pairConfirmCommandPreview: String,
    val reconnectCommandPreview: String,
    val threadListCommandPreview: String,
    val threadStartCommandPreview: String,
    val threadResumeCommandPreview: String,
    val turnStartCommandPreview: String,
    val turnSteerCommandPreview: String,
    val interruptCommandPreview: String,
    val nextSteps: String,
    val authToken: String?,
    val pairingCode: String?,
    val threadListSummary: String,
    val activeThreadSummary: String,
    val chatTranscript: String,
    val approvalSummary: String,
    val userInputSummary: String,
)

interface EngineRuntimeGateway {
    fun probe(
        hostProfile: HostProfile?,
        deviceName: String,
        pairingCode: String,
        draftMessage: String,
    ): EngineRuntimeProbeResult

    fun refresh()
    fun startThread()
    fun selectNextThread()
    fun resumeThread()
    fun sendMessage(message: String)
    fun interruptThread()
    fun respondToApproval(allow: Boolean)
    fun submitUserInput(answer: String)
    fun close() {}
}

class UniffiEngineRuntimeGateway(
    private val clientName: String,
    private val clientVersion: String,
    private val nativeLibraryDir: String?,
) : EngineRuntimeGateway {
    private val lock = Any()
    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(
        ThreadFactory {
            Thread(it, "codex-island-android-hostd").apply { isDaemon = true }
        }
    )
    private val httpClient = OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build()

    private var runtime: EngineRuntime? = null
    private var currentHost: HostProfile? = null
    private var currentDeviceName: String = DEFAULT_DEVICE_NAME
    private var currentPairingCode: String = ""
    private var lastDraftMessage: String = ""
    private var nativeLoadFailure: Throwable? = null
    private var socket: WebSocket? = null
    private var socketState: SocketState = SocketState.DISCONNECTED
    private var directSession: DirectSshAppServerSession? = null
    private var directState: DirectSessionState = DirectSessionState.DISCONNECTED
    private var directInitialized: Boolean = false
    private var directBootstrapTask: ScheduledFuture<*>? = null
    private var lastDirectError: String? = null
    private var reconnectTask: ScheduledFuture<*>? = null
    private val threads = LinkedHashMap<String, AndroidThreadState>()
    private var selectedThreadId: String? = null

    override fun probe(
        hostProfile: HostProfile?,
        deviceName: String,
        pairingCode: String,
        draftMessage: String,
    ): EngineRuntimeProbeResult = synchronized(lock) {
        currentDeviceName = deviceName.trim().ifBlank { DEFAULT_DEVICE_NAME }
        currentPairingCode = pairingCode.trim()
        lastDraftMessage = draftMessage
        syncHostLocked(hostProfile)
        renderLocked()
    }

    override fun refresh() {
        synchronized(lock) {
            if (currentHost == null) {
                return
            }

            if (activeConnectionModeLocked() == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
                connectDirectSessionLocked()
                return
            }

            val runtime = ensureRuntimeLocked() ?: return

            requestConnectionLocked(runtime)
            val state = runtime.state()
            when {
                state.authenticated -> enqueueThreadListLocked(runtime)
                currentPairingCode.isNotBlank() -> runtime.enqueuePairConfirm(
                    currentPairingCode,
                    currentDeviceName,
                    ANDROID_PLATFORM
                )

                state.snapshot.activePairing == null -> runtime.enqueuePairStart(
                    currentDeviceName,
                    ANDROID_PLATFORM
                )
            }
            runtime.enqueueGetSnapshot()
            drainCommandsLocked(runtime)
        }
    }

    override fun startThread() {
        synchronized(lock) {
            if (currentHost == null) {
                return
            }
            if (activeConnectionModeLocked() == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
                connectDirectSessionLocked()
                sendDirectRequestLocked(
                    nextRequestId(REQUEST_THREAD_START),
                    "thread/start",
                    JSONObject()
                )
                return
            }
            val runtime = ensureRuntimeLocked() ?: return
            requestConnectionLocked(runtime)
            runtime.enqueueAppServerRequest(
                nextRequestId(REQUEST_THREAD_START),
                "thread/start",
                "{}"
            )
            drainCommandsLocked(runtime)
        }
    }

    override fun selectNextThread() {
        synchronized(lock) {
            if (threads.isEmpty()) {
                return
            }
            val ids = threads.keys.toList()
            val currentIndex = ids.indexOf(selectedThreadId).coerceAtLeast(0)
            selectedThreadId = ids[(currentIndex + 1) % ids.size]
        }
    }

    override fun resumeThread() {
        synchronized(lock) {
            if (currentHost == null) {
                return
            }
            if (activeConnectionModeLocked() == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
                val thread = currentThreadLocked() ?: return
                connectDirectSessionLocked()
                sendDirectRequestLocked(
                    nextRequestId(REQUEST_THREAD_RESUME),
                    "thread/resume",
                    JSONObject().put("threadId", thread.threadId)
                )
                return
            }
            val runtime = ensureRuntimeLocked() ?: return
            val thread = currentThreadLocked() ?: return
            requestConnectionLocked(runtime)
            runtime.enqueueAppServerRequest(
                nextRequestId(REQUEST_THREAD_RESUME),
                "thread/resume",
                JSONObject().put("threadId", thread.threadId).toString()
            )
            drainCommandsLocked(runtime)
        }
    }

    override fun sendMessage(message: String) {
        val trimmed = message.trim()
        if (trimmed.isEmpty()) {
            return
        }

        synchronized(lock) {
            if (currentHost == null) {
                return
            }
            if (activeConnectionModeLocked() == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
                val thread = currentThreadLocked() ?: return
                connectDirectSessionLocked()

                val payload = JSONObject()
                    .put("threadId", thread.threadId)
                    .put("input", JSONArray().put(textInput(trimmed)))

                val method: String
                if (thread.activeTurnId.isNullOrBlank()) {
                    method = "turn/start"
                } else {
                    method = "turn/steer"
                    payload.put("expectedTurnId", thread.activeTurnId)
                }

                upsertThreadLocked(
                    thread.copy(
                        status = "sending",
                        history = thread.history + AndroidChatEntry(role = "user", text = trimmed)
                    )
                )

                sendDirectRequestLocked(
                    nextRequestId(
                        if (method == "turn/start") REQUEST_TURN_START else REQUEST_TURN_STEER
                    ),
                    method,
                    payload
                )
                return
            }
            val runtime = ensureRuntimeLocked() ?: return
            val thread = currentThreadLocked() ?: return
            requestConnectionLocked(runtime)

            val payload = JSONObject()
                .put("threadId", thread.threadId)
                .put("input", JSONArray().put(textInput(trimmed)))

            val method: String
            if (thread.activeTurnId.isNullOrBlank()) {
                method = "turn/start"
            } else {
                method = "turn/steer"
                payload.put("expectedTurnId", thread.activeTurnId)
            }

            upsertThreadLocked(
                thread.copy(
                    status = "sending",
                    history = thread.history + AndroidChatEntry(role = "user", text = trimmed)
                )
            )

            runtime.enqueueAppServerRequest(
                nextRequestId(
                    if (method == "turn/start") REQUEST_TURN_START else REQUEST_TURN_STEER
                ),
                method,
                payload.toString()
            )
            drainCommandsLocked(runtime)
        }
    }

    override fun interruptThread() {
        synchronized(lock) {
            if (currentHost == null) {
                return
            }
            if (activeConnectionModeLocked() == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
                val thread = currentThreadLocked() ?: return
                val turnId = thread.activeTurnId ?: return
                connectDirectSessionLocked()
                sendDirectRequestLocked(
                    nextRequestId("turn-interrupt"),
                    "turn/interrupt",
                    JSONObject()
                        .put("threadId", thread.threadId)
                        .put("turnId", turnId)
                )
                return
            }
            val runtime = ensureRuntimeLocked() ?: return
            val thread = currentThreadLocked() ?: return
            val turnId = thread.activeTurnId ?: return
            requestConnectionLocked(runtime)
            runtime.enqueueAppServerInterrupt(thread.threadId, turnId)
            drainCommandsLocked(runtime)
        }
    }

    override fun respondToApproval(allow: Boolean) {
        synchronized(lock) {
            if (currentHost == null) {
                return
            }
            if (activeConnectionModeLocked() == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
                val thread = currentThreadLocked() ?: return
                val approval = thread.pendingApproval ?: return
                connectDirectSessionLocked()
                sendDirectResponseLocked(approval.requestId, approval.responsePayload(allow))
                upsertThreadLocked(
                    thread.copy(
                        status = "active",
                        pendingApproval = null,
                        history = thread.history + AndroidChatEntry(
                            role = "approval",
                            text = if (allow) "Approval accepted." else "Approval declined."
                        )
                    )
                )
                return
            }
            val runtime = ensureRuntimeLocked() ?: return
            val thread = currentThreadLocked() ?: return
            val approval = thread.pendingApproval ?: return
            requestConnectionLocked(runtime)

            runtime.enqueueAppServerResponse(
                approval.requestId,
                approval.responsePayload(allow).toString()
            )

            upsertThreadLocked(
                thread.copy(
                    status = "active",
                    pendingApproval = null,
                    history = thread.history + AndroidChatEntry(
                        role = "approval",
                        text = if (allow) "Approval accepted." else "Approval declined."
                    )
                )
            )
            drainCommandsLocked(runtime)
        }
    }

    override fun submitUserInput(answer: String) {
        val trimmed = answer.trim()
        if (trimmed.isEmpty()) {
            return
        }

        synchronized(lock) {
            if (currentHost == null) {
                return
            }
            if (activeConnectionModeLocked() == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
                val thread = currentThreadLocked() ?: return
                val userInput = thread.pendingUserInput ?: return
                connectDirectSessionLocked()
                sendDirectResponseLocked(userInput.requestId, userInput.responsePayload(trimmed))
                upsertThreadLocked(
                    thread.copy(
                        status = "active",
                        pendingUserInput = null,
                        history = thread.history + AndroidChatEntry(
                            role = "user-input",
                            text = trimmed
                        )
                    )
                )
                return
            }
            val runtime = ensureRuntimeLocked() ?: return
            val thread = currentThreadLocked() ?: return
            val userInput = thread.pendingUserInput ?: return
            requestConnectionLocked(runtime)

            runtime.enqueueAppServerResponse(
                userInput.requestId,
                userInput.responsePayload(trimmed).toString()
            )

            upsertThreadLocked(
                thread.copy(
                    status = "active",
                    pendingUserInput = null,
                    history = thread.history +
                        AndroidChatEntry(role = "user-input", text = trimmed)
                )
            )
            drainCommandsLocked(runtime)
        }
    }

    override fun close() {
        synchronized(lock) {
            reconnectTask?.cancel(false)
            reconnectTask = null
            directBootstrapTask?.cancel(false)
            directBootstrapTask = null
            socket?.close(1000, "gateway closed")
            socket = null
            socketState = SocketState.DISCONNECTED
            directSession?.close()
            directSession = null
            directState = DirectSessionState.DISCONNECTED
            runtime?.close()
            runtime = null
            threads.clear()
            selectedThreadId = null
        }
        scheduler.shutdownNow()
        httpClient.dispatcher.executorService.shutdown()
        httpClient.connectionPool.evictAll()
    }

    private fun syncHostLocked(hostProfile: HostProfile?) {
        if (hostProfile == null) {
            if (currentHost != null) {
                resetSessionLocked()
            }
            currentHost = null
            return
        }

        val needsReset = currentHost?.id != hostProfile.id || currentHost?.hostAddress != hostProfile.hostAddress
        currentHost = hostProfile

        if (needsReset) {
            resetSessionLocked()
            currentHost = hostProfile
        } else {
            runtime?.replaceAuthToken(hostProfile.authToken)
        }
    }

    private fun activeConnectionModeLocked(): HostConnectionMode {
        val host = currentHost ?: return HostConnectionMode.HOSTD_WEBSOCKET
        return SecureShellStore.inferConnectionMode(host.hostAddress)
    }

    private fun resetSessionLocked() {
        reconnectTask?.cancel(false)
        reconnectTask = null
        directBootstrapTask?.cancel(false)
        directBootstrapTask = null
        socket?.cancel()
        socket = null
        socketState = SocketState.DISCONNECTED
        directSession?.close()
        directSession = null
        directState = DirectSessionState.DISCONNECTED
        directInitialized = false
        lastDirectError = null
        runtime?.close()
        runtime = null
        threads.clear()
        selectedThreadId = null
    }

    private fun ensureRuntimeLocked(): EngineRuntime? {
        if (nativeLoadFailure != null) {
            return null
        }
        runtime?.let { return it }

        return try {
            ensureNativeLibraryLoaded()
            uniffiEnsureInitialized()
            EngineRuntime(
                ClientRuntimeConfig(
                    clientName = clientName,
                    clientVersion = clientVersion,
                    authToken = currentHost?.authToken
                )
            ).also { runtime = it }
        } catch (throwable: Throwable) {
            nativeLoadFailure = throwable
            null
        }
    }

    private fun requestConnectionLocked(runtime: EngineRuntime) {
        if (activeConnectionModeLocked() == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
            connectDirectSessionLocked()
            return
        }

        runtime.requestConnection()
        if (socketState == SocketState.DISCONNECTED) {
            connectSocketLocked()
        }
    }

    private fun connectSocketLocked() {
        val host = currentHost ?: return
        if (socketState == SocketState.CONNECTING || socketState == SocketState.OPEN) {
            return
        }

        val request = Request.Builder()
            .url(webSocketUrl(host.hostAddress))
            .build()
        socketState = SocketState.CONNECTING
        socket = httpClient.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    scheduler.execute {
                        synchronized(lock) {
                            if (socket !== webSocket) {
                                return@synchronized
                            }
                            socketState = SocketState.OPEN
                            runtime?.let(::drainCommandsLocked)
                        }
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    scheduler.execute {
                        synchronized(lock) {
                            if (socket !== webSocket) {
                                return@synchronized
                            }
                            handleServerMessageLocked(text)
                        }
                    }
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(code, reason)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    scheduler.execute {
                        synchronized(lock) {
                            if (socket === webSocket) {
                                socket = null
                                socketState = SocketState.DISCONNECTED
                                handleTransportDropLocked(reason.ifBlank { "socket closed ($code)" })
                            }
                        }
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    scheduler.execute {
                        synchronized(lock) {
                            if (socket === webSocket) {
                                socket = null
                                socketState = SocketState.DISCONNECTED
                                handleTransportDropLocked(t.message ?: "websocket failure")
                            }
                        }
                    }
                }
            }
        )
    }

    private fun connectDirectSessionLocked() {
        val host = currentHost ?: return
        if (directState == DirectSessionState.CONNECTING || directState == DirectSessionState.OPEN) {
            return
        }

        val target = normalizeSshTarget(host.hostAddress)
        val password = host.sshPassword?.takeIf { it.isNotBlank() }
        val keyPair = host.sshKeyPair()
        if (target == null || (password == null && keyPair == null)) {
            lastDirectError = "SSH direct 模式需要 user@host，且至少提供 SSH key 或 password。"
            directState = DirectSessionState.FAILED
            return
        }

        directState = DirectSessionState.CONNECTING
        lastDirectError = null
        directSession = DirectSshAppServerSession(
            sshTarget = target,
            password = password,
            keyPair = keyPair,
            onLine = { line ->
                scheduler.execute {
                    synchronized(lock) {
                        handleDirectMessageLocked(line)
                    }
                }
            },
            onFailure = { message ->
                scheduler.execute {
                    synchronized(lock) {
                        directSession = null
                        directState = DirectSessionState.DISCONNECTED
                        directInitialized = false
                        lastDirectError = message
                        scheduleDirectReconnectLocked()
                    }
                }
            },
            onOpen = {
                scheduler.execute {
                    synchronized(lock) {
                        directState = DirectSessionState.OPEN
                        lastDirectError = null
                        sendDirectRequestLocked(
                            requestId = REQUEST_INITIALIZE,
                            method = "initialize",
                            params = JSONObject()
                                .put(
                                    "capabilities",
                                    JSONObject().put("experimentalApi", true)
                                )
                                .put(
                                    "clientInfo",
                                    JSONObject()
                                        .put("name", clientName)
                                        .put("title", "Codex Island")
                                        .put("version", clientVersion)
                                )
                        )
                    }
                }
            }
        ).also { session ->
            session.open()
        }
    }

    private fun handleTransportDropLocked(reason: String) {
        val runtime = runtime ?: return
        runtime.transportDisconnected(reason)
        scheduleReconnectLocked(runtime)
    }

    private fun scheduleReconnectLocked(runtime: EngineRuntime) {
        reconnectTask?.cancel(false)
        reconnectTask = null
        val state = runtime.state()
        if (!state.reconnect.reconnectPending) {
            return
        }
        val delayMs = state.reconnect.nextBackoffMs?.toLong() ?: 1_000L
        reconnectTask = scheduler.schedule(
            {
                synchronized(lock) {
                    val activeRuntime = runtime ?: return@synchronized
                    if (activeRuntime.activateReconnectNow()) {
                        connectSocketLocked()
                        drainCommandsLocked(activeRuntime)
                    }
                }
            },
            delayMs,
            TimeUnit.MILLISECONDS
        )
    }

    private fun scheduleDirectReconnectLocked() {
        directBootstrapTask?.cancel(false)
        directBootstrapTask = null
        directBootstrapTask = scheduler.schedule(
            {
                synchronized(lock) {
                    connectDirectSessionLocked()
                }
            },
            1_000L,
            TimeUnit.MILLISECONDS
        )
    }

    private fun sendDirectRequestLocked(requestId: String, method: String, params: JSONObject) {
        try {
            directSession?.send(
                JSONObject()
                    .put("id", requestId)
                    .put("method", method)
                    .put("params", params)
                    .toString()
            ) ?: run {
                lastDirectError = "SSH direct session is unavailable."
            }
        } catch (throwable: Throwable) {
            lastDirectError = throwable.message ?: "Failed to send SSH direct request."
        }
    }

    private fun sendDirectNotificationLocked(method: String, params: JSONObject?) {
        try {
            val payload = JSONObject().put("method", method)
            if (params == null) {
                payload.put("params", JSONObject.NULL)
            } else {
                payload.put("params", params)
            }
            directSession?.send(payload.toString()) ?: run {
                lastDirectError = "SSH direct session is unavailable."
            }
        } catch (throwable: Throwable) {
            lastDirectError = throwable.message ?: "Failed to send SSH direct notification."
        }
    }

    private fun sendDirectResponseLocked(requestId: String, result: JSONObject) {
        try {
            directSession?.send(
                JSONObject()
                    .put("id", requestId)
                    .put("result", result)
                    .toString()
            ) ?: run {
                lastDirectError = "SSH direct session is unavailable."
            }
        } catch (throwable: Throwable) {
            lastDirectError = throwable.message ?: "Failed to send SSH direct response."
        }
    }

    private fun handleDirectMessageLocked(rawMessage: String) {
        val event = JSONObject(rawMessage)
        if (event.optString("id") == REQUEST_INITIALIZE && event.has("result")) {
            directInitialized = true
            sendDirectNotificationLocked("initialized", null)
            enqueueDirectThreadListLocked()
            return
        }

        if (event.has("id") && event.has("result")) {
            handleAppServerResponseLocked(event.optString("id"), event.optJSONObject("result"))
            return
        }

        if (event.has("method")) {
            handleAppServerPayloadLocked(event)
            return
        }

        if (event.has("error")) {
            lastDirectError = event.optJSONObject("error")?.optString("message")
        }
    }

    private fun normalizeSshTarget(rawTarget: String): String? {
        val trimmed = rawTarget.trim()
        if (trimmed.isEmpty()) {
            return null
        }
        return trimmed.removePrefix("ssh://").takeIf { it.contains('@') }
    }

    private fun enqueueDirectThreadListLocked() {
        if (!directInitialized) {
            return
        }
        sendDirectRequestLocked(
            nextRequestId(REQUEST_THREAD_LIST),
            "thread/list",
            JSONObject().put("limit", 100)
        )
    }

    private fun HostProfile.sshKeyPair(): GeneratedSshKeyPair? {
        val publicKey = sshPublicKeyPkcs8 ?: return null
        val privateKey = sshPrivateKeyPkcs8 ?: return null
        return GeneratedSshKeyPair(
            publicKeyOpenSsh = sshPublicKey.orEmpty(),
            publicKeyPkcs8Base64 = publicKey,
            privateKeyPkcs8Base64 = privateKey
        )
    }

    private fun handleServerMessageLocked(rawMessage: String) {
        val runtime = runtime ?: return
        val eventJson = unwrapServerEvent(rawMessage)
        inspectServerEventLocked(eventJson)
        runtime.applyServerEventJson(eventJson)
        val state = runtime.state()
        if (state.authenticated && socketState == SocketState.OPEN) {
            if (threads.isEmpty()) {
                enqueueThreadListLocked(runtime)
            }
        }
        drainCommandsLocked(runtime)
    }

    private fun drainCommandsLocked(runtime: EngineRuntime) {
        if (socketState != SocketState.OPEN) {
            return
        }

        while (true) {
            val nextCommand = runtime.popNextCommandJson() ?: break
            val openSocket = socket ?: break
            val sent = openSocket.send(nextCommand)
            if (!sent) {
                handleTransportDropLocked("failed to send websocket frame")
                break
            }
            if (runtime.state().inFlightCommand != null) {
                break
            }
        }
    }

    private fun inspectServerEventLocked(eventJson: String) {
        val event = JSONObject(eventJson)
        when (event.optString("type")) {
            "pairing_started" -> {
                currentPairingCode = event.optJSONObject("pairing")?.optString("pairing_code").orEmpty()
            }

            "pairing_completed" -> {
                currentPairingCode = ""
            }

            "snapshot" -> {
                val pairing = event.optJSONObject("snapshot")?.optJSONObject("active_pairing")
                if (pairing != null) {
                    currentPairingCode = pairing.optString("pairing_code").orEmpty()
                }
            }

            "app_server_response" -> {
                val requestId = event.optString("request_id")
                handleAppServerResponseLocked(requestId, event.optJSONObject("result"))
            }

            "app_server_event" -> {
                handleAppServerPayloadLocked(event.optJSONObject("payload"))
            }

            "error" -> {
                val message = event.optJSONObject("error")?.optString("message")
                if (!message.isNullOrBlank()) {
                    appendSystemMessageLocked(currentThreadLocked()?.threadId, message)
                }
            }
        }
    }

    private fun handleAppServerResponseLocked(requestId: String, result: JSONObject?) {
        when {
            requestId.startsWith(REQUEST_THREAD_LIST) -> {
                applyThreadListResultLocked(result)
            }

            requestId.startsWith(REQUEST_THREAD_START) || requestId.startsWith(REQUEST_THREAD_RESUME) -> {
                result?.optJSONObject("thread")?.let(::parseThread)?.let { thread ->
                    upsertThreadLocked(thread)
                    selectedThreadId = thread.threadId
                }
                if (threads.isEmpty()) {
                    result?.optJSONArray("data")?.let(::applyThreadArrayLocked)
                }
            }

            requestId.startsWith(REQUEST_TURN_START) || requestId.startsWith(REQUEST_TURN_STEER) -> {
                currentThreadLocked()?.let { thread ->
                    upsertThreadLocked(thread.copy(status = "running"))
                }
            }
        }
    }

    private fun handleAppServerPayloadLocked(payload: JSONObject?) {
        payload ?: return
        when (payload.optString("method")) {
            "thread/started" -> {
                val params = payload.optJSONObject("params")
                val thread = params?.optJSONObject("thread")?.let(::parseThread)
                    ?: parseThreadFromFallback(params)
                if (thread != null) {
                    upsertThreadLocked(thread)
                    selectedThreadId = thread.threadId
                }
            }

            "thread/status/changed" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId")
                val status = params.optJSONObject("status")?.optString("type")
                    ?: params.optString("status")
                updateThreadLocked(threadId) { it.copy(status = status.ifBlank { it.status }) }
            }

            "turn/started" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId")
                val turnId = params.optJSONObject("turn")?.optString("id")
                    ?: params.optString("turnId")
                ensureThreadLocked(threadId).let { thread ->
                    upsertThreadLocked(thread.copy(status = "active", activeTurnId = turnId))
                    selectedThreadId = threadId
                }
            }

            "turn/completed" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId")
                updateThreadLocked(threadId) { it.copy(status = "idle", activeTurnId = null) }
            }

            "turn/interrupted" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId")
                updateThreadLocked(threadId) {
                    it.copy(
                        status = "interrupted",
                        activeTurnId = null,
                        history = it.history + AndroidChatEntry(
                            role = "system",
                            text = "Turn interrupted."
                        )
                    )
                }
            }

            "item/agentMessage/delta" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId")
                val delta = params.optString("delta")
                if (delta.isNotBlank()) {
                    updateThreadLocked(threadId) { it.appendAssistantDelta(delta) }
                }
            }

            "item/completed" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId")
                val item = params.optJSONObject("item")
                val text = item?.optString("text").orEmpty()
                if (text.isNotBlank()) {
                    updateThreadLocked(threadId) { thread ->
                        thread.copy(history = thread.history + AndroidChatEntry("assistant", text))
                    }
                }
            }

            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId")
                val approval = parseApproval(
                    method = payload.optString("method"),
                    requestId = payload.optString("id"),
                    params = params
                )
                updateThreadLocked(threadId) {
                    it.copy(status = "waiting_approval", pendingApproval = approval)
                }
            }

            "item/tool/requestUserInput" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId")
                val request = parseUserInput(payload.optString("id"), params)
                updateThreadLocked(threadId) {
                    it.copy(status = "waiting_input", pendingUserInput = request)
                }
            }

            "serverRequest/resolved" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId")
                val requestId = params.optString("requestId")
                updateThreadLocked(threadId) { thread ->
                    thread.copy(
                        pendingApproval = thread.pendingApproval?.takeUnless { it.requestId == requestId },
                        pendingUserInput = thread.pendingUserInput?.takeUnless { it.requestId == requestId },
                        status = if (thread.activeTurnId.isNullOrBlank()) "idle" else "active"
                    )
                }
            }

            "error",
            "codex/event/error" -> {
                val params = payload.optJSONObject("params") ?: return
                val threadId = params.optString("threadId").ifBlank {
                    params.optString("conversationId")
                }
                val message = params.optJSONObject("error")?.optString("message")
                    ?: params.optJSONObject("msg")?.optString("message")
                    ?: payload.toString()
                appendSystemMessageLocked(threadId, message)
            }
        }
    }

    private fun applyThreadListResultLocked(result: JSONObject?) {
        if (result == null) {
            return
        }
        when {
            result.has("data") -> applyThreadArrayLocked(result.optJSONArray("data"))
            result.has("threads") -> applyThreadArrayLocked(result.optJSONArray("threads"))
        }
    }

    private fun applyThreadArrayLocked(array: JSONArray?) {
        array ?: return
        for (index in 0 until array.length()) {
            val thread = parseThread(array.optJSONObject(index)) ?: continue
            upsertThreadLocked(thread)
            if (selectedThreadId == null) {
                selectedThreadId = thread.threadId
            }
        }
    }

    private fun parseThread(json: JSONObject?): AndroidThreadState? {
        json ?: return null
        val threadId = json.optString("id").ifBlank { json.optString("threadId") }
        if (threadId.isBlank()) {
            return null
        }
        val title = json.optString("title").ifBlank { "Thread ${threadId.take(8)}" }
        val status = json.optJSONObject("status")?.optString("type")
            ?: json.optString("status").ifBlank { "idle" }
        return AndroidThreadState(
            threadId = threadId,
            title = title,
            status = status,
            activeTurnId = null,
            history = emptyList(),
            pendingApproval = null,
            pendingUserInput = null
        )
    }

    private fun parseThreadFromFallback(json: JSONObject?): AndroidThreadState? {
        json ?: return null
        val threadId = json.optString("threadId")
        if (threadId.isBlank()) {
            return null
        }
        return AndroidThreadState(
            threadId = threadId,
            title = json.optString("title").ifBlank { "Thread ${threadId.takeLast(6)}" },
            status = "active",
            activeTurnId = null,
            history = emptyList(),
            pendingApproval = null,
            pendingUserInput = null
        )
    }

    private fun parseApproval(method: String, requestId: String, params: JSONObject): AndroidPendingApproval {
        val title = when (method) {
            "item/fileChange/requestApproval" -> "File Change"
            "item/permissions/requestApproval" -> "Permissions Request"
            else -> "Command Execution"
        }
        val kind = when (method) {
            "item/fileChange/requestApproval" -> ApprovalKind.FILE_CHANGE
            "item/permissions/requestApproval" -> ApprovalKind.PERMISSIONS
            else -> ApprovalKind.COMMAND_EXECUTION
        }
        val itemId = params.optString("itemId").ifBlank { UUID.randomUUID().toString() }
        val turnId = params.optString("turnId").ifBlank { null }
        val detail = params.optString("command").ifBlank {
            params.optString("reason").ifBlank { title }
        }
        return AndroidPendingApproval(
            requestId = requestId.ifBlank { itemId },
            itemId = itemId,
            threadId = params.optString("threadId"),
            turnId = turnId,
            title = title,
            detail = detail,
            kind = kind,
            requestedPermissions = PermissionGrant(
                networkEnabled = params.optJSONObject("permissions")
                    ?.optJSONObject("network")
                    ?.takeIf { it.has("enabled") }
                    ?.optBoolean("enabled"),
                readRoots = jsonArrayStrings(
                    params.optJSONObject("permissions")
                        ?.optJSONObject("fileSystem")
                        ?.optJSONArray("read")
                ),
                writeRoots = jsonArrayStrings(
                    params.optJSONObject("permissions")
                        ?.optJSONObject("fileSystem")
                        ?.optJSONArray("write")
                )
            )
        )
    }

    private fun parseUserInput(requestId: String, params: JSONObject): AndroidPendingUserInput {
        val itemId = params.optString("itemId").ifBlank { UUID.randomUUID().toString() }
        val questions = params.optJSONArray("questions")
        val questionId = questions?.optJSONObject(0)?.optString("id").orEmpty().ifBlank { "answer" }
        val questionText = questions?.optJSONObject(0)?.optString("question")
            ?: params.optString("question")
            ?: "Codex needs your input."
        return AndroidPendingUserInput(
            requestId = requestId.ifBlank { itemId },
            itemId = itemId,
            threadId = params.optString("threadId"),
            questionId = questionId,
            question = questionText
        )
    }

    private fun appendSystemMessageLocked(threadId: String?, message: String) {
        if (message.isBlank()) {
            return
        }
        val resolvedThreadId = threadId?.takeIf { it.isNotBlank() } ?: currentThreadLocked()?.threadId ?: return
        updateThreadLocked(resolvedThreadId) { thread ->
            thread.copy(history = thread.history + AndroidChatEntry("system", message))
        }
    }

    private fun ensureThreadLocked(threadId: String): AndroidThreadState {
        return threads[threadId] ?: AndroidThreadState(
            threadId = threadId,
            title = "Thread ${threadId.take(8)}",
            status = "idle",
            activeTurnId = null,
            history = emptyList(),
            pendingApproval = null,
            pendingUserInput = null
        ).also {
            upsertThreadLocked(it)
        }
    }

    private fun updateThreadLocked(threadId: String, transform: (AndroidThreadState) -> AndroidThreadState) {
        if (threadId.isBlank()) {
            return
        }
        val current = ensureThreadLocked(threadId)
        upsertThreadLocked(transform(current))
    }

    private fun upsertThreadLocked(thread: AndroidThreadState) {
        val existing = threads[thread.threadId]
        threads[thread.threadId] = if (existing == null) {
            thread
        } else {
            existing.merge(thread)
        }
        if (selectedThreadId == null) {
            selectedThreadId = thread.threadId
        }
    }

    private fun currentThreadLocked(): AndroidThreadState? {
        val selected = selectedThreadId?.let(threads::get)
        return selected ?: threads.values.firstOrNull()
    }

    private fun enqueueThreadListLocked(runtime: EngineRuntime) {
        runtime.enqueueAppServerRequest(
            nextRequestId(REQUEST_THREAD_LIST),
            "thread/list",
            JSONObject().put("limit", 100).toString()
        )
    }

    private fun renderLocked(): EngineRuntimeProbeResult {
        val host = currentHost
        val nativeError = nativeLoadFailure
        if (activeConnectionModeLocked() == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
            return renderDirectSshResult(host)
        }
        val runtime = ensureRuntimeLocked()
        if (runtime == null) {
            return fallbackResult(host, nativeError)
        }

        val state = runtime.state()
        val pairingCode = state.snapshot.activePairing?.pairingCode?.ifBlank { null }
            ?: currentPairingCode.ifBlank { null }
        val authToken = state.authToken ?: host?.authToken
        val thread = currentThreadLocked()
        val threadId = thread?.threadId ?: state.snapshot.activeThreadId ?: "thread-preview"
        val turnId = thread?.activeTurnId ?: state.snapshot.activeTurnId ?: "turn-preview"
        val queueState = formatQueue(state)
        val hostState = when {
            socketState == SocketState.OPEN -> "open"
            socketState == SocketState.CONNECTING -> "connecting"
            else -> "disconnected"
        }

        return EngineRuntimeProbeResult(
            runtimeLinked = true,
            engineStatus = "UniFFI runtime 已初始化，client=${runtime.clientName()} ${runtime.clientVersion()}",
            bindingSurface = "surface ${runtime.bindingSurfaceVersion()}",
            connection = "${state.connection.name.lowercase()} / websocket=$hostState",
            commandQueue = queueState,
            pairedDevices = "${state.snapshot.pairedDevices.size} paired / host reports ${state.snapshot.health.pairedDeviceCount}",
            reconnect = if (state.reconnect.reconnectPending) {
                "pending, next=${state.reconnect.nextBackoffMs ?: state.reconnect.currentBackoffMs}ms"
            } else {
                "idle, shouldReconnect=${state.reconnect.shouldReconnect}"
            },
            diagnostics = buildDiagnostics(state),
            lastError = state.lastError?.message ?: nativeError?.message ?: "none",
            helloCommandPreview = runtime.helloCommandJson().take(180),
            pairStartCommandPreview = host?.let {
                runtime.pairStartCommandJson(currentDeviceName, ANDROID_PLATFORM)
            } ?: "Select a host profile first.",
            pairConfirmCommandPreview = if (host == null) {
                "Select a host profile first."
            } else {
                runtime.pairConfirmCommandJson(
                    pairingCode ?: currentPairingCode.ifBlank { "PAIR-123" },
                    currentDeviceName,
                    ANDROID_PLATFORM
                )
            }.take(220),
            reconnectCommandPreview = host?.let {
                "ws ${webSocketUrl(it.hostAddress)} / token=" +
                    if (authToken.isNullOrBlank()) "pending" else "stored"
            } ?: "Select a host profile first.",
            threadListCommandPreview = appServerRequestPreview(
                runtime,
                host,
                nextRequestId(REQUEST_THREAD_LIST),
                "thread/list",
                JSONObject().put("limit", 100).toString()
            ),
            threadStartCommandPreview = appServerRequestPreview(
                runtime,
                host,
                nextRequestId(REQUEST_THREAD_START),
                "thread/start",
                "{}"
            ),
            threadResumeCommandPreview = appServerRequestPreview(
                runtime,
                host,
                nextRequestId(REQUEST_THREAD_RESUME),
                "thread/resume",
                JSONObject().put("threadId", threadId).toString()
            ),
            turnStartCommandPreview = appServerRequestPreview(
                runtime,
                host,
                nextRequestId(REQUEST_TURN_START),
                "turn/start",
                JSONObject()
                    .put("threadId", threadId)
                    .put("input", JSONArray().put(textInput(lastDraftMessage.ifBlank { "Android live message" })))
                    .toString()
            ).take(260),
            turnSteerCommandPreview = appServerRequestPreview(
                runtime,
                host,
                nextRequestId(REQUEST_TURN_STEER),
                "turn/steer",
                JSONObject()
                    .put("threadId", threadId)
                    .put("expectedTurnId", turnId)
                    .put("input", JSONArray().put(textInput(lastDraftMessage.ifBlank { "Android live message" })))
                    .toString()
            ).take(260),
            interruptCommandPreview = host?.let {
                runtime.appServerInterruptCommandJson(threadId, turnId)
            } ?: "Select a host profile first.",
            nextSteps = nextSteps(state, host),
            authToken = authToken,
            pairingCode = pairingCode,
            threadListSummary = threadListSummary(),
            activeThreadSummary = thread?.summary()
                ?: "尚未从 hostd 拉到 thread。点击 Refresh 建连，然后 Start thread 或 thread/list。",
            chatTranscript = thread?.history?.joinToString("\n\n") { "[${it.role}] ${it.text}" }
                ?: "No chat yet.",
            approvalSummary = thread?.pendingApproval?.let { "${it.title}\n${it.detail}" }
                ?: "No pending approvals.",
            userInputSummary = thread?.pendingUserInput?.question ?: "No pending user-input requests."
        )
    }

    private fun threadListSummary(): String {
        if (threads.isEmpty()) {
            return "No live threads yet."
        }
        return threads.values.joinToString("\n") { thread ->
            val marker = if (thread.threadId == selectedThreadId) "• active" else "• saved"
            "$marker ${thread.title}  [${thread.status}]"
        }
    }

    private fun buildDiagnostics(state: EngineRuntimeState): String {
        val diagnostics = state.diagnostics
        return "connect=${diagnostics.connectAttempts}, " +
            "success=${diagnostics.successfulConnects}, " +
            "disconnect=${diagnostics.disconnectCount}, " +
            "transport=${diagnostics.transportErrorCount}, " +
            "lastResponse=${diagnostics.lastResponseRequestId ?: "none"}"
    }

    private fun formatQueue(state: EngineRuntimeState): String {
        val inFlight = state.inFlightCommand?.let(::describeQueuedCommand) ?: "none"
        val pending = state.pendingCommands.joinToString(", ") { describeQueuedCommand(it) }
            .ifBlank { "none" }
        return "${state.pendingCommands.size} pending / in-flight=$inFlight / queue=$pending"
    }

    private fun describeQueuedCommand(command: QueuedCommandRecord): String {
        val suffix = if (command.kind == CommandKind.APP_SERVER_RESPONSE) " fire-and-forget" else ""
        return "${command.kind.name.lowercase()}#${command.queueId}$suffix"
    }

    private fun nextSteps(state: EngineRuntimeState, host: HostProfile?): String {
        if (host == null) {
            return "1. 先保存一个 host profile。\n2. 点击 Refresh 建立 websocket。\n3. 然后再走 pairing / thread / chat。"
        }
        if (!state.authenticated) {
            return "1. Refresh 会在无 token 时自动发起 pair_start。\n2. 把 pairing code 填回输入框后再次 Refresh 做 pair_confirm。\n3. 认证成功后再拉 thread/list。"
        }
        return "1. Refresh 会连到 live hostd 并拉 thread/list。\n2. Start thread / Send message 直接走 websocket + EngineRuntime queue。\n3. 审批、user-input 和 interrupt 也会回写到同一条 live transport。"
    }

    private fun appServerRequestPreview(
        runtime: EngineRuntime,
        hostProfile: HostProfile?,
        requestId: String,
        method: String,
        paramsJson: String,
    ): String {
        if (hostProfile == null) {
            return "Select a host profile first."
        }
        return runtime.appServerRequestCommandJson(
            requestId = requestId,
            method = method,
            paramsJson = paramsJson
        ).take(220)
    }

    private fun fallbackResult(hostProfile: HostProfile?, nativeError: Throwable?): EngineRuntimeProbeResult {
        return EngineRuntimeProbeResult(
            runtimeLinked = false,
            engineStatus = "未能装载 Rust runtime",
            bindingSurface = "native library missing",
            connection = "disconnected",
            commandQueue = "0 pending",
            pairedDevices = "0 paired",
            reconnect = "idle",
            diagnostics = "等待集成 host transport",
            lastError = nativeError?.message ?: "native library missing",
            helloCommandPreview = "{}",
            pairStartCommandPreview = hostProfile?.let {
                "pair_start ${it.hostAddress} as $currentDeviceName"
            } ?: "Select a host profile first.",
            pairConfirmCommandPreview = hostProfile?.let {
                "pair_confirm ${currentPairingCode.ifBlank { "<pairing-code>" }} for ${it.hostAddress}"
            } ?: "Select a host profile first.",
            reconnectCommandPreview = hostProfile?.let {
                "Reconnect entry point ready for ${it.displayName} (${it.hostAddress})"
            } ?: "Select a host profile first.",
            threadListCommandPreview = if (hostProfile == null) {
                "Select a host profile first."
            } else {
                """thread/list {"limit":100}"""
            },
            threadStartCommandPreview = if (hostProfile == null) {
                "Select a host profile first."
            } else {
                """thread/start {}"""
            },
            threadResumeCommandPreview = if (hostProfile == null) {
                "Select a host profile first."
            } else {
                """thread/resume {"threadId":"thread-preview"}"""
            },
            turnStartCommandPreview = if (hostProfile == null) {
                "Select a host profile first."
            } else {
                """turn/start {"threadId":"thread-preview","input":[{"type":"text","text":"Android live message"}]}"""
            },
            turnSteerCommandPreview = if (hostProfile == null) {
                "Select a host profile first."
            } else {
                """turn/steer {"threadId":"thread-preview","expectedTurnId":"turn-preview"}"""
            },
            interruptCommandPreview = if (hostProfile == null) {
                "Select a host profile first."
            } else {
                "turn/interrupt thread-preview turn-preview"
            },
            nextSteps = "1. 先确保 Android 可加载 Rust FFI so。\n2. 然后重新运行 app 并点击 Refresh。\n3. live transport 会在 runtime 装载成功后启用。",
            authToken = hostProfile?.authToken,
            pairingCode = hostProfile?.lastPairingCode,
            threadListSummary = "No live threads yet.",
            activeThreadSummary = "尚未创建 thread。",
            chatTranscript = "No chat yet.",
            approvalSummary = "No pending approvals.",
            userInputSummary = "No pending user-input requests."
        )
    }

    private fun renderDirectSshResult(hostProfile: HostProfile?): EngineRuntimeProbeResult {
        val thread = currentThreadLocked()
        val connection = when (directState) {
            DirectSessionState.OPEN -> "ssh-direct / app-server=connected"
            DirectSessionState.CONNECTING -> "ssh-direct / app-server=connecting"
            DirectSessionState.FAILED -> "ssh-direct / app-server=failed"
            DirectSessionState.DISCONNECTED -> "ssh-direct / app-server=disconnected"
        }
        val sshTarget = hostProfile?.hostAddress ?: "Select a host profile first."
        return EngineRuntimeProbeResult(
            runtimeLinked = true,
            engineStatus = "SSH direct mode: Android will launch remote codex app-server on demand.",
            bindingSurface = "ssh-direct-app-server",
            connection = connection,
            commandQueue = "direct session / initialized=$directInitialized",
            pairedDevices = "not used in ssh direct mode",
            reconnect = if (directState == DirectSessionState.OPEN) "idle" else "retry on failure",
            diagnostics = "threads=${threads.size}, lastError=${lastDirectError ?: "none"}",
            lastError = lastDirectError ?: "none",
            helloCommandPreview = """ssh $sshTarget 'exec codex app-server --listen stdio://'""",
            pairStartCommandPreview = "not used in ssh direct mode",
            pairConfirmCommandPreview = "not used in ssh direct mode",
            reconnectCommandPreview = "Reconnect will reopen SSH and relaunch codex app-server.",
            threadListCommandPreview = """{"method":"thread/list","params":{"limit":100}}""",
            threadStartCommandPreview = """{"method":"thread/start","params":{}}""",
            threadResumeCommandPreview = """{"method":"thread/resume","params":{"threadId":"thread-preview"}}""",
            turnStartCommandPreview = """{"method":"turn/start","params":{"threadId":"thread-preview","input":[{"type":"text","text":"Android live message"}]}}""",
            turnSteerCommandPreview = """{"method":"turn/steer","params":{"threadId":"thread-preview","expectedTurnId":"turn-preview","input":[{"type":"text","text":"Android live message"}]}}""",
            interruptCommandPreview = """{"method":"turn/interrupt","params":{"threadId":"thread-preview","turnId":"turn-preview"}}""",
            nextSteps = if (hostProfile == null) {
                "1. 保存一个 SSH host，例如 ssh://user@host。\n2. 在 Auth token 输入 SSH password。\n3. 点击 Refresh，Android 会直连 SSH 并拉起 codex app-server。"
            } else {
                "1. Refresh 会通过 SSH 拉起远端 codex app-server。\n2. thread/chat/approval/user-input 将直接走 app-server。\n3. 当前模式不需要预先手动启动 hostd。"
            },
            authToken = hostProfile?.authToken,
            pairingCode = null,
            threadListSummary = threadListSummary(),
            activeThreadSummary = thread?.summary() ?: "尚未创建 thread。",
            chatTranscript = thread?.history?.joinToString("\n\n") { "[${it.role}] ${it.text}" } ?: "No chat yet.",
            approvalSummary = thread?.pendingApproval?.let { "${it.title}\n${it.detail}" } ?: "No pending approvals.",
            userInputSummary = thread?.pendingUserInput?.question ?: "No pending user-input requests."
        )
    }

    private fun unwrapServerEvent(rawMessage: String): String {
        val root = JSONObject(rawMessage)
        return if (root.has("payload") && root.has("id") && !root.has("type")) {
            root.getJSONObject("payload").toString()
        } else {
            rawMessage
        }
    }

    private fun ensureNativeLibraryLoaded() {
        synchronized(nativeLoadLock) {
            if (nativeLibraryLoaded) {
                return
            }

            System.setProperty(
                "uniffi.component.codex_island_client.libraryOverride",
                NATIVE_LIBRARY_BASENAME
            )

            try {
                System.loadLibrary(NATIVE_LIBRARY_BASENAME)
            } catch (firstError: UnsatisfiedLinkError) {
                val nativeLibraryPath = nativeLibraryDir
                    ?.let { "$it/lib$NATIVE_LIBRARY_BASENAME.so" }
                    ?: throw firstError
                System.setProperty("jna.library.path", nativeLibraryDir)
                System.setProperty(
                    "uniffi.component.codex_island_client.libraryOverride",
                    nativeLibraryPath
                )
                System.load(nativeLibraryPath)
            }

            nativeLibraryLoaded = true
        }
    }

    private fun webSocketUrl(address: String): String {
        val trimmed = address.trim()
        return when {
            trimmed.startsWith("ws://", ignoreCase = true) ||
                trimmed.startsWith("wss://", ignoreCase = true) -> trimmed

            trimmed.startsWith("http://", ignoreCase = true) ->
                "ws://${trimmed.removePrefix("http://")}"

            trimmed.startsWith("https://", ignoreCase = true) ->
                "wss://${trimmed.removePrefix("https://")}"

            else -> "ws://$trimmed"
        }
    }

    private companion object {
        private const val ANDROID_PLATFORM = "android"
        private const val DEFAULT_DEVICE_NAME = "Android Companion"
        private const val NATIVE_LIBRARY_BASENAME = "codex_island_client_ffi"
        private const val REQUEST_THREAD_LIST = "thread-list"
        private const val REQUEST_INITIALIZE = "initialize"
        private const val REQUEST_THREAD_START = "thread-start"
        private const val REQUEST_THREAD_RESUME = "thread-resume"
        private const val REQUEST_TURN_START = "turn-start"
        private const val REQUEST_TURN_STEER = "turn-steer"
        private val nativeLoadLock = Any()
        private var nativeLibraryLoaded = false

        private fun nextRequestId(prefix: String): String = "$prefix-${UUID.randomUUID()}"

        private fun jsonArrayStrings(array: JSONArray?): List<String> {
            if (array == null) {
                return emptyList()
            }
            return buildList {
                for (index in 0 until array.length()) {
                    val value = array.optString(index)
                    if (value.isNotBlank()) {
                        add(value)
                    }
                }
            }
        }

        private fun textInput(text: String): JSONObject =
            JSONObject().put("type", "text").put("text", text)
    }
}

private enum class SocketState {
    DISCONNECTED,
    CONNECTING,
    OPEN,
}

private enum class DirectSessionState {
    DISCONNECTED,
    CONNECTING,
    OPEN,
    FAILED,
}

private class DirectSshAppServerSession(
    private val sshTarget: String,
    private val password: String?,
    private val keyPair: GeneratedSshKeyPair?,
    private val onOpen: () -> Unit,
    private val onLine: (String) -> Unit,
    private val onFailure: (String) -> Unit,
) {
    private var sshClient: SSHClient? = null
    private var session: Session? = null
    private var command: Session.Command? = null
    private var writer: java.io.BufferedWriter? = null
    private var readerThread: Thread? = null

    fun open() {
        thread(name = "codex-island-ssh-direct", isDaemon = true) {
            try {
                val (user, host, port) = parseTarget(sshTarget)
                val client = SSHClient()
                client.addHostKeyVerifier(PromiscuousVerifier())
                client.connect(host, port)
                if (keyPair != null) {
                    client.authPublickey(user, client.loadKeys(keyPair.toJavaKeyPair()))
                } else {
                    client.authPassword(user, password ?: error("SSH password is missing"))
                }
                val directSession = client.startSession()
                val directCommand = directSession.exec("exec codex app-server --listen stdio://")
                sshClient = client
                session = directSession
                command = directCommand
                writer = directCommand.outputStream.bufferedWriter()
                onOpen()

                readerThread = thread(name = "codex-island-ssh-direct-reader", isDaemon = true) {
                    try {
                        directCommand.inputStream.bufferedReader().useLines { lines ->
                            lines.forEach { line ->
                                if (line.isNotBlank()) {
                                    onLine(line)
                                }
                            }
                        }
                    } catch (throwable: Throwable) {
                        onFailure(throwable.message ?: "SSH direct reader failed")
                    }
                }
            } catch (throwable: Throwable) {
                onFailure(throwable.message ?: "SSH direct launch failed")
            }
        }
    }

    fun send(line: String) {
        val activeWriter = writer ?: error("SSH direct writer is unavailable")
        activeWriter.write(line)
        activeWriter.newLine()
        activeWriter.flush()
    }

    fun close() {
        try {
            writer?.close()
        } catch (_: Throwable) {
        }
        try {
            command?.close()
        } catch (_: Throwable) {
        }
        try {
            session?.close()
        } catch (_: Throwable) {
        }
        try {
            sshClient?.disconnect()
        } catch (_: Throwable) {
        }
        writer = null
        command = null
        session = null
        sshClient = null
        readerThread?.interrupt()
        readerThread = null
    }

    private fun parseTarget(rawTarget: String): Triple<String, String, Int> {
        val withoutScheme = rawTarget.removePrefix("ssh://")
        val user = withoutScheme.substringBefore('@', "")
        val hostPort = withoutScheme.substringAfter('@', "")
        require(user.isNotBlank() && hostPort.isNotBlank()) { "SSH target must look like user@host" }
        val host = hostPort.substringBefore(':')
        val port = hostPort.substringAfter(':', "22").toIntOrNull() ?: 22
        return Triple(user, host, port)
    }
}

private enum class ApprovalKind {
    COMMAND_EXECUTION,
    FILE_CHANGE,
    PERMISSIONS,
}

private data class PermissionGrant(
    val networkEnabled: Boolean?,
    val readRoots: List<String>,
    val writeRoots: List<String>,
) {
    fun asJson(): JSONObject {
        val result = JSONObject()
        if (networkEnabled != null) {
            result.put("network", JSONObject().put("enabled", networkEnabled))
        }
        val fileSystem = JSONObject()
        if (readRoots.isNotEmpty()) {
            fileSystem.put("read", JSONArray(readRoots))
        }
        if (writeRoots.isNotEmpty()) {
            fileSystem.put("write", JSONArray(writeRoots))
        }
        if (fileSystem.length() > 0) {
            result.put("fileSystem", fileSystem)
        }
        return result
    }
}

private data class AndroidChatEntry(
    val role: String,
    val text: String,
)

private data class AndroidPendingApproval(
    val requestId: String,
    val itemId: String,
    val threadId: String,
    val turnId: String?,
    val title: String,
    val detail: String,
    val kind: ApprovalKind,
    val requestedPermissions: PermissionGrant,
) {
    fun responsePayload(allow: Boolean): JSONObject {
        return when (kind) {
            ApprovalKind.COMMAND_EXECUTION,
            ApprovalKind.FILE_CHANGE -> JSONObject().put(
                "decision",
                if (allow) "accept" else "decline"
            )

            ApprovalKind.PERMISSIONS -> JSONObject()
                .put("scope", "turn")
                .put("permissions", if (allow) requestedPermissions.asJson() else JSONObject())
        }
    }
}

private data class AndroidPendingUserInput(
    val requestId: String,
    val itemId: String,
    val threadId: String,
    val questionId: String,
    val question: String,
) {
    fun responsePayload(answer: String): JSONObject {
        val answers = JSONObject()
        answers.put(questionId, JSONObject().put("answers", JSONArray().put(answer)))
        return JSONObject().put("answers", answers)
    }
}

private data class AndroidThreadState(
    val threadId: String,
    val title: String,
    val status: String,
    val activeTurnId: String?,
    val history: List<AndroidChatEntry>,
    val pendingApproval: AndroidPendingApproval?,
    val pendingUserInput: AndroidPendingUserInput?,
) {
    fun appendAssistantDelta(delta: String): AndroidThreadState {
        if (history.isNotEmpty() && history.last().role == "assistant") {
            val updated = history.dropLast(1) + history.last().copy(text = history.last().text + delta)
            return copy(history = updated)
        }
        return copy(history = history + AndroidChatEntry("assistant", delta))
    }

    fun summary(): String {
        return "$title\n$threadId\nstatus=$status · turn=${activeTurnId ?: "none"}"
    }

    fun merge(next: AndroidThreadState): AndroidThreadState {
        return copy(
            title = if (next.title.isNotBlank()) next.title else title,
            status = if (next.status.isNotBlank()) next.status else status,
            activeTurnId = next.activeTurnId ?: activeTurnId,
            history = if (next.history.isEmpty()) history else next.history,
            pendingApproval = next.pendingApproval ?: pendingApproval,
            pendingUserInput = next.pendingUserInput ?: pendingUserInput
        )
    }
}
