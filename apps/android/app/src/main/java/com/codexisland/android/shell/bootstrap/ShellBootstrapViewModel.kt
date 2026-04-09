package com.codexisland.android.shell.bootstrap

import android.content.Context
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.codexisland.android.shell.runtime.EngineRuntimeGateway
import com.codexisland.android.shell.runtime.UniffiEngineRuntimeGateway
import com.codexisland.android.shell.storage.HostProfile
import com.codexisland.android.shell.storage.HostProfileEditor
import com.codexisland.android.shell.storage.SecureShellStore
import com.codexisland.android.shell.storage.ShellProfile
import com.codexisland.android.shell.storage.ShellProfileStore
import java.util.UUID

private data class AndroidChatEntry(
    val role: String,
    val text: String,
)

private data class AndroidPendingApproval(
    val itemId: String,
    val title: String,
    val detail: String,
)

private data class AndroidPendingUserInput(
    val itemId: String,
    val question: String,
)

private data class AndroidThreadWorkspace(
    val threadId: String,
    val title: String,
    val status: String,
    val activeTurnId: String?,
    val history: List<AndroidChatEntry>,
    val pendingApproval: AndroidPendingApproval?,
    val pendingUserInput: AndroidPendingUserInput?,
)

class ShellBootstrapViewModel(
    private val profileStore: ShellProfileStore,
    private val runtimeGateway: EngineRuntimeGateway,
    private val hostProfileEditor: HostProfileEditor? = null,
) : ViewModel() {
    private var draftHostConnectionInput: String = ""
    private var draftHostDisplayName: String = ""
    private var draftPairingCode: String = ""
    private var draftMessage: String = ""
    private var draftUserInputAnswer: String = ""
    private var threadWorkspaces: List<AndroidThreadWorkspace> = emptyList()
    private var activeThreadId: String? = null

    private val _uiState = MutableLiveData(renderState(profileStore.load()))
    val uiState: LiveData<ShellBootstrapUiState> = _uiState

    fun saveHostProfile(
        deviceName: String,
        hostConnectionInput: String,
        hostDisplayName: String,
        authToken: String,
        pairingCode: String,
    ) {
        val current = profileStore.load()
        val updated = hostProfileEditor?.upsertHost(
            current = current.copy(deviceName = normalizeDeviceName(deviceName)),
            rawConnectionInput = hostConnectionInput,
            explicitDisplayName = hostDisplayName,
            explicitAuthToken = authToken,
            pairingCode = pairingCode
        ) ?: current

        profileStore.save(updated)
        draftHostConnectionInput = updated.activeHost()?.hostAddress.orEmpty()
        draftHostDisplayName = updated.activeHost()?.displayName.orEmpty()
        draftPairingCode = updated.activeHost()?.lastPairingCode.orEmpty()
        _uiState.value = renderState(updated)
    }

    fun selectNextHost() {
        val current = profileStore.load()
        if (current.hosts.isEmpty()) {
            return
        }

        val currentIndex = current.hosts.indexOfFirst { it.id == current.activeHostId }.coerceAtLeast(0)
        val nextHost = current.hosts[(currentIndex + 1) % current.hosts.size]
        val updated = hostProfileEditor?.selectHost(current, nextHost.id) ?: current
        profileStore.save(updated)
        draftHostConnectionInput = nextHost.hostAddress
        draftHostDisplayName = nextHost.displayName
        draftPairingCode = nextHost.lastPairingCode.orEmpty()
        _uiState.value = renderState(updated)
    }

    fun refreshRuntime() {
        _uiState.value = renderState(profileStore.load())
    }

    fun startThread() {
        val nextIndex = threadWorkspaces.size + 1
        val thread = AndroidThreadWorkspace(
            threadId = "thread-${UUID.randomUUID()}",
            title = "Thread $nextIndex",
            status = "active",
            activeTurnId = "turn-$nextIndex",
            history = listOf(
                AndroidChatEntry(
                    role = "system",
                    text = "Thread created on Android shell. Transport wiring will later send the previewed request to hostd."
                )
            ),
            pendingApproval = null,
            pendingUserInput = null
        )
        threadWorkspaces = threadWorkspaces + thread
        activeThreadId = thread.threadId
        _uiState.value = renderState(profileStore.load())
    }

    fun selectNextThread() {
        if (threadWorkspaces.isEmpty()) {
            return
        }
        val currentIndex = threadWorkspaces.indexOfFirst { it.threadId == activeThreadId }.coerceAtLeast(0)
        activeThreadId = threadWorkspaces[(currentIndex + 1) % threadWorkspaces.size].threadId
        _uiState.value = renderState(profileStore.load())
    }

    fun resumeThread() {
        val current = currentThread() ?: return
        threadWorkspaces = threadWorkspaces.map { thread ->
            if (thread.threadId == current.threadId) {
                thread.copy(
                    status = "resumed",
                    activeTurnId = thread.activeTurnId ?: "turn-resumed"
                )
            } else {
                thread
            }
        }
        _uiState.value = renderState(profileStore.load())
    }

    fun sendMessage(message: String) {
        val trimmed = message.trim()
        if (trimmed.isEmpty()) {
            return
        }
        val current = currentThread() ?: return
        draftMessage = trimmed

        val pendingApproval = if (trimmed.contains("/approve") || trimmed.contains("apply_patch")) {
            AndroidPendingApproval(
                itemId = "approval-${current.threadId}",
                title = "Command approval",
                detail = "Command wants elevated file edit permissions for `${current.title}`."
            )
        } else {
            null
        }

        val pendingUserInput = if (trimmed.contains("/input") || trimmed.contains("need details")) {
            AndroidPendingUserInput(
                itemId = "input-${current.threadId}",
                question = "Select destination branch for `${current.title}`."
            )
        } else {
            null
        }

        threadWorkspaces = threadWorkspaces.map { thread ->
            if (thread.threadId == current.threadId) {
                thread.copy(
                    status = when {
                        pendingApproval != null -> "waiting_approval"
                        pendingUserInput != null -> "waiting_input"
                        else -> "active"
                    },
                    activeTurnId = thread.activeTurnId ?: "turn-live",
                    history = thread.history +
                        AndroidChatEntry(role = "user", text = trimmed) +
                        AndroidChatEntry(
                            role = "assistant",
                            text = when {
                                pendingApproval != null -> "Queued command approval request."
                                pendingUserInput != null -> "Queued request_user_input prompt."
                                else -> "Queued turn/start or turn/steer preview for transport delivery."
                            }
                        ),
                    pendingApproval = pendingApproval,
                    pendingUserInput = pendingUserInput
                )
            } else {
                thread
            }
        }
        _uiState.value = renderState(profileStore.load())
    }

    fun interruptThread() {
        val current = currentThread() ?: return
        threadWorkspaces = threadWorkspaces.map { thread ->
            if (thread.threadId == current.threadId) {
                thread.copy(
                    status = "interrupted",
                    activeTurnId = null,
                    history = thread.history + AndroidChatEntry(
                        role = "system",
                        text = "Interrupt requested for active turn."
                    )
                )
            } else {
                thread
            }
        }
        _uiState.value = renderState(profileStore.load())
    }

    fun allowApproval() {
        resolveApproval("approved")
    }

    fun denyApproval() {
        resolveApproval("denied")
    }

    fun submitUserInput(answer: String) {
        val trimmed = answer.trim()
        if (trimmed.isEmpty()) {
            return
        }
        val current = currentThread() ?: return
        draftUserInputAnswer = trimmed
        threadWorkspaces = threadWorkspaces.map { thread ->
            if (thread.threadId == current.threadId) {
                thread.copy(
                    status = "active",
                    pendingUserInput = null,
                    history = thread.history +
                        AndroidChatEntry(role = "user-input", text = trimmed) +
                        AndroidChatEntry(role = "assistant", text = "Queued user-input response payload.")
                )
            } else {
                thread
            }
        }
        _uiState.value = renderState(profileStore.load())
    }

    private fun renderState(profile: ShellProfile): ShellBootstrapUiState {
        val activeHost = profile.activeHost()
        val activeThread = currentThread()
        if (draftHostConnectionInput.isBlank()) {
            draftHostConnectionInput = activeHost?.hostAddress.orEmpty()
        }
        if (draftHostDisplayName.isBlank()) {
            draftHostDisplayName = activeHost?.displayName.orEmpty()
        }
        if (draftPairingCode.isBlank()) {
            draftPairingCode = activeHost?.lastPairingCode.orEmpty()
        }

        val runtime = runtimeGateway.probe(
            hostProfile = activeHost,
            deviceName = profile.deviceName,
            activeThreadId = activeThread?.threadId,
            activeTurnId = activeThread?.activeTurnId,
            draftMessage = draftMessage
        )
        val runtimeState = if (runtime.runtimeLinked) "已接入" else "待接入"
        val helperText = if (activeHost?.authToken.isNullOrBlank()) {
            "Auth token 可留空。若 QR payload 内含 token，会在保存 host 时一并写入 Keystore。"
        } else {
            "当前 host 已保存 auth token，可直接作为 reconnect 入口。"
        }

        return ShellBootstrapUiState(
            deviceName = profile.deviceName,
            hostConnectionInput = draftHostConnectionInput,
            hostDisplayName = draftHostDisplayName,
            authToken = activeHost?.authToken.orEmpty(),
            pairingCode = draftPairingCode,
            messageDraft = draftMessage,
            userInputDraft = draftUserInputAnswer,
            subtitle = "当前面板支持手动地址或粘贴 QR payload、保存多个 host profile、thread/chat、approval 和 user-input 的 Android 壳流程。",
            runtimeStatus = runtimeState,
            engineStatus = runtime.engineStatus,
            bindingSurface = runtime.bindingSurface,
            connection = runtime.connection,
            commandQueue = runtime.commandQueue,
            pairedDevices = runtime.pairedDevices,
            reconnect = runtime.reconnect,
            diagnostics = runtime.diagnostics,
            lastError = runtime.lastError,
            helloCommandPreview = runtime.helloCommandPreview,
            pairStartPreview = runtime.pairStartCommandPreview,
            pairConfirmPreview = runtime.pairConfirmCommandPreview,
            reconnectPreview = runtime.reconnectCommandPreview,
            threadListPreview = runtime.threadListCommandPreview,
            threadStartPreview = runtime.threadStartCommandPreview,
            threadResumePreview = runtime.threadResumeCommandPreview,
            turnStartPreview = runtime.turnStartCommandPreview,
            turnSteerPreview = runtime.turnSteerCommandPreview,
            interruptPreview = runtime.interruptCommandPreview,
            nextSteps = runtime.nextSteps,
            authTokenHelper = helperText,
            hostProfilesSummary = profile.hosts.summary(activeHost?.id),
            activeHostSummary = activeHost?.let(::describeHost)
                ?: "尚未保存 host profile。可输入 Tailscale 地址，例如 `macbook.tail.ts.net:7331`，或粘贴 `codex-island://...` QR payload。",
            threadListSummary = threadListSummary(),
            activeThreadSummary = activeThread?.let(::describeThread)
                ?: "尚未创建 thread。先点 Start thread，再发一条消息进入 chat/approval/user-input 流。",
            chatTranscript = activeThread?.history?.joinToString("\n\n") { entry ->
                "[${entry.role}] ${entry.text}"
            } ?: "No chat yet.",
            approvalSummary = activeThread?.pendingApproval?.let {
                "${it.title}\n${it.detail}"
            } ?: "No pending approvals.",
            userInputSummary = activeThread?.pendingUserInput?.question ?: "No pending user-input requests."
        )
    }

    private fun ShellProfile.activeHost(): HostProfile? {
        return hosts.firstOrNull { it.id == activeHostId } ?: hosts.firstOrNull()
    }

    private fun List<HostProfile>.summary(activeHostId: String?): String {
        if (isEmpty()) {
            return "No saved hosts yet."
        }

        return joinToString("\n") { host ->
            val marker = if (host.id == activeHostId) "• active" else "• saved"
            val authState = if (host.authToken.isNullOrBlank()) "pairing pending" else "paired token stored"
            "$marker ${host.displayName}  ${host.hostAddress}  [$authState]"
        }
    }

    private fun describeHost(host: HostProfile): String {
        val authState = if (host.authToken.isNullOrBlank()) "未配对" else "已保存 token"
        val pairing = host.lastPairingCode ?: "未记录 pairing code"
        return "${host.displayName}\n${host.hostAddress}\n$authState · $pairing"
    }

    private fun describeThread(thread: AndroidThreadWorkspace): String {
        return "${thread.title}\n${thread.threadId}\nstatus=${thread.status} · turn=${thread.activeTurnId ?: "none"}"
    }

    private fun threadListSummary(): String {
        if (threadWorkspaces.isEmpty()) {
            return "No threads yet."
        }
        return threadWorkspaces.joinToString("\n") { thread ->
            val marker = if (thread.threadId == activeThreadId) "• active" else "• saved"
            "$marker ${thread.title}  [${thread.status}]"
        }
    }

    private fun currentThread(): AndroidThreadWorkspace? =
        threadWorkspaces.firstOrNull { it.threadId == activeThreadId } ?: threadWorkspaces.firstOrNull()

    private fun resolveApproval(result: String) {
        val current = currentThread() ?: return
        threadWorkspaces = threadWorkspaces.map { thread ->
            if (thread.threadId == current.threadId) {
                thread.copy(
                    status = "active",
                    pendingApproval = null,
                    history = thread.history + AndroidChatEntry(
                        role = "approval",
                        text = "Approval $result on Android shell."
                    )
                )
            } else {
                thread
            }
        }
        _uiState.value = renderState(profileStore.load())
    }

    private fun normalizeDeviceName(deviceName: String): String =
        deviceName.trim().ifBlank { DEFAULT_DEVICE_NAME }

    companion object {
        private const val DEFAULT_DEVICE_NAME = "Android Companion"

        fun factory(context: Context): ViewModelProvider.Factory {
            val appContext = context.applicationContext
            return object : ViewModelProvider.Factory {
                override fun <T : ViewModel> create(modelClass: Class<T>): T {
                    val store = SecureShellStore(appContext)
                    val gateway = UniffiEngineRuntimeGateway(
                        clientName = "Codex Island Android",
                        clientVersion = APP_VERSION
                    )
                    @Suppress("UNCHECKED_CAST")
                    return ShellBootstrapViewModel(store, gateway, store) as T
                }
            }
        }

        private const val APP_VERSION = "0.1.0"
    }
}
