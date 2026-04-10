package com.codexisland.android.shell.bootstrap

import android.content.Context
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.codexisland.android.shell.runtime.EngineRuntimeGateway
import com.codexisland.android.shell.runtime.UniffiEngineRuntimeGateway
import com.codexisland.android.shell.storage.GeneratedSshKeyPair
import com.codexisland.android.shell.storage.HostConnectionMode
import com.codexisland.android.shell.storage.HostProfile
import com.codexisland.android.shell.storage.HostProfileEditor
import com.codexisland.android.shell.storage.SecureShellStore
import com.codexisland.android.shell.storage.ShellProfile
import com.codexisland.android.shell.storage.ShellProfileStore

class ShellBootstrapViewModel(
    private val profileStore: ShellProfileStore,
    private val runtimeGateway: EngineRuntimeGateway,
    private val hostProfileEditor: HostProfileEditor? = null,
) : ViewModel() {
    private var draftDeviceName: String = ""
    private var draftHostConnectionInput: String = ""
    private var draftHostDisplayName: String = ""
    private var draftPairingCode: String = ""
    private var draftMessage: String = ""
    private var draftUserInputAnswer: String = ""

    private val _uiState = MutableLiveData(renderState(profileStore.load()))
    val uiState: LiveData<ShellBootstrapUiState> = _uiState

    fun saveHostProfile(
        deviceName: String,
        hostConnectionInput: String,
        hostDisplayName: String,
        authToken: String,
        sshPassword: String,
        pairingCode: String,
    ) {
        val current = profileForEditing(profileStore.load(), deviceName)
        val updated = hostProfileEditor?.upsertHost(
            current = current,
            rawConnectionInput = hostConnectionInput,
            explicitDisplayName = hostDisplayName,
            explicitAuthToken = authToken,
            explicitSshPassword = sshPassword,
            pairingCode = pairingCode
        ) ?: current

        profileStore.save(updated)
        draftDeviceName = updated.deviceName
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

    fun refreshRuntime(
        deviceName: String? = null,
        pairingCode: String? = null,
    ) {
        deviceName?.let { draftDeviceName = normalizeDeviceName(it) }
        pairingCode?.let { draftPairingCode = it.trim() }
        _uiState.value = renderState(profileStore.load())
        runtimeGateway.refresh()
        _uiState.value = renderState(profileStore.load())
    }

    fun startThread() {
        runtimeGateway.startThread()
        _uiState.value = renderState(profileStore.load())
    }

    fun selectNextThread() {
        runtimeGateway.selectNextThread()
        _uiState.value = renderState(profileStore.load())
    }

    fun resumeThread() {
        runtimeGateway.resumeThread()
        _uiState.value = renderState(profileStore.load())
    }

    fun sendMessage(message: String) {
        val trimmed = message.trim()
        if (trimmed.isEmpty()) {
            return
        }
        draftMessage = trimmed
        runtimeGateway.sendMessage(trimmed)
        _uiState.value = renderState(profileStore.load())
    }

    fun interruptThread() {
        runtimeGateway.interruptThread()
        _uiState.value = renderState(profileStore.load())
    }

    fun allowApproval() {
        runtimeGateway.respondToApproval(true)
        _uiState.value = renderState(profileStore.load())
    }

    fun denyApproval() {
        runtimeGateway.respondToApproval(false)
        _uiState.value = renderState(profileStore.load())
    }

    fun submitUserInput(answer: String) {
        val trimmed = answer.trim()
        if (trimmed.isEmpty()) {
            return
        }
        draftUserInputAnswer = trimmed
        runtimeGateway.submitUserInput(trimmed)
        _uiState.value = renderState(profileStore.load())
    }

    fun generateSshKeyPair() {
        val current = profileStore.load()
        val activeHost = current.activeHost() ?: return
        if (SecureShellStore.inferConnectionMode(activeHost.hostAddress) != HostConnectionMode.SSH_DIRECT_APP_SERVER) {
            return
        }

        val generated = SecureShellStore.generateSshKeyPair(
            "${normalizeDeviceName(current.deviceName)}@${activeHost.displayName.ifBlank { activeHost.hostAddress }}"
        )
        val updated = hostProfileEditor?.attachSshKeyPair(current, activeHost.id, generated)
            ?: attachSshKeyPairFallback(current, activeHost.id, generated)
        profileStore.save(updated)
        _uiState.value = renderState(updated)
    }

    override fun onCleared() {
        runtimeGateway.close()
        super.onCleared()
    }

    private fun renderState(profile: ShellProfile): ShellBootstrapUiState {
        var effectiveProfile = profileForEditing(profile, draftDeviceName)
        val initialHost = effectiveProfile.activeHost()
        val runtime = runtimeGateway.probe(
            hostProfile = initialHost,
            deviceName = effectiveProfile.deviceName,
            pairingCode = draftPairingCode,
            draftMessage = draftMessage
        )

        effectiveProfile = persistRuntimeHostData(effectiveProfile, runtime)
        val activeHost = effectiveProfile.activeHost()

        if (draftDeviceName.isBlank()) {
            draftDeviceName = effectiveProfile.deviceName
        }
        if (draftHostConnectionInput.isBlank()) {
            draftHostConnectionInput = activeHost?.hostAddress.orEmpty()
        }
        if (draftHostDisplayName.isBlank()) {
            draftHostDisplayName = activeHost?.displayName.orEmpty()
        }
        draftPairingCode = runtime.pairingCode ?: activeHost?.lastPairingCode.orEmpty()

        val connectionMode = activeHost?.let { SecureShellStore.inferConnectionMode(it.hostAddress) }
            ?: HostConnectionMode.HOSTD_WEBSOCKET
        val showPairingCode = connectionMode == HostConnectionMode.HOSTD_WEBSOCKET
        val showSshKeyTools = connectionMode == HostConnectionMode.SSH_DIRECT_APP_SERVER
        val runtimeState = when {
            !runtime.runtimeLinked -> "待接入"
            connectionMode == HostConnectionMode.SSH_DIRECT_APP_SERVER -> "SSH 直连"
            runtime.authToken.isNullOrBlank() -> "待配对"
            else -> "已接入"
        }
        val authSecretHelper = if (connectionMode == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
            if (!activeHost?.sshPublicKey.isNullOrBlank()) {
                "已生成 SSH key。可复制下方命令到远端追加 authorized_keys；SSH password 仅作兜底。"
            } else {
                "SSH direct 模式支持 password 或公钥。可一键生成密钥对，并复制命令到远端追加 authorized_keys。"
            }
        } else if (runtime.authToken.isNullOrBlank()) {
            "Auth token 可留空。Refresh 会先发起 pair_start；填入 pairing code 后再次 Refresh 会执行 pair_confirm。"
        } else {
            "当前 host 已保存 auth token，可直接作为 reconnect 入口。"
        }
        val hostConnectionHelper = if (connectionMode == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
            "SSH direct: 填 `ssh://user@host` 或 `user@host`。Android 会直接 SSH 拉起远端 codex app-server。"
        } else {
            "hostd websocket: 填 `host:7331`、`ws://...`，或粘贴 `codex-island://...` QR payload。"
        }
        val showHostdAuthToken = connectionMode == HostConnectionMode.HOSTD_WEBSOCKET
        val showSshPassword = connectionMode == HostConnectionMode.SSH_DIRECT_APP_SERVER
        val sshPublicKey = activeHost?.sshPublicKey.orEmpty()
        val sshKeyStatus = if (connectionMode != HostConnectionMode.SSH_DIRECT_APP_SERVER) {
            "当前 host 不使用 SSH direct。"
        } else if (sshPublicKey.isBlank()) {
            "尚未生成 SSH key。"
        } else {
            "已生成 SSH key，可直接复制命令到远端主机。"
        }
        val sshInstallCommand = activeHost?.let { buildSshInstallCommand(it, effectiveProfile.deviceName) }.orEmpty()

        return ShellBootstrapUiState(
            deviceName = effectiveProfile.deviceName,
            hostConnectionInput = draftHostConnectionInput,
            hostConnectionHelper = hostConnectionHelper,
            hostDisplayName = draftHostDisplayName,
            hostdAuthToken = runtime.authToken ?: activeHost?.authToken.orEmpty(),
            sshPassword = activeHost?.sshPassword.orEmpty(),
            showHostdAuthToken = showHostdAuthToken,
            showSshPassword = showSshPassword,
            pairingCode = draftPairingCode,
            showPairingCode = showPairingCode,
            showSshKeyTools = showSshKeyTools,
            messageDraft = draftMessage,
            userInputDraft = draftUserInputAnswer,
            subtitle = if (connectionMode == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
                "当前 host 将按 macOS 远程模式通过 SSH 拉起 codex app-server，不再要求你预先手动启动 hostd。"
            } else {
                "当前面板已直接对接 live hostd websocket；保存 host 后可走 pairing、thread/chat、approval、request_user_input 和 interrupt 的真实链路。"
            },
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
            hostdAuthTokenHelper = if (showHostdAuthToken) authSecretHelper else "",
            sshPasswordHelper = if (showSshPassword) authSecretHelper else "",
            sshKeyStatus = sshKeyStatus,
            sshPublicKey = sshPublicKey,
            sshInstallCommand = sshInstallCommand,
            hostProfilesSummary = effectiveProfile.hosts.summary(activeHost?.id),
            activeHostSummary = activeHost?.let(::describeHost)
                ?: "尚未保存 host profile。可输入 Tailscale hostd 地址，例如 `macbook.tail.ts.net:7331`，或直接输入 `ssh://user@host` 走 SSH direct 模式。",
            threadListSummary = runtime.threadListSummary,
            activeThreadSummary = runtime.activeThreadSummary,
            chatTranscript = runtime.chatTranscript,
            approvalSummary = runtime.approvalSummary,
            userInputSummary = runtime.userInputSummary
        )
    }

    private fun persistRuntimeHostData(
        profile: ShellProfile,
        runtime: com.codexisland.android.shell.runtime.EngineRuntimeProbeResult,
    ): ShellProfile {
        val activeHost = profile.activeHost() ?: return profile
        val nextToken = runtime.authToken ?: activeHost.authToken
        val nextPairingCode = runtime.pairingCode ?: activeHost.lastPairingCode
        if (nextToken == activeHost.authToken && nextPairingCode == activeHost.lastPairingCode) {
            return profile
        }

        val updatedHosts = profile.hosts.map { host ->
            if (host.id == activeHost.id) {
                host.copy(authToken = nextToken, lastPairingCode = nextPairingCode)
            } else {
                host
            }
        }
        val updated = profile.copy(hosts = updatedHosts)
        profileStore.save(updated)
        return updated
    }

    private fun profileForEditing(profile: ShellProfile, deviceName: String): ShellProfile {
        val normalized = normalizeDeviceName(deviceName.ifBlank { profile.deviceName })
        return profile.copy(deviceName = normalized)
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
            val authState = if (SecureShellStore.inferConnectionMode(host.hostAddress) == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
                if (host.sshPublicKey.isNullOrBlank()) "ssh key missing" else "ssh key ready"
            } else if (host.authToken.isNullOrBlank()) {
                "pairing pending"
            } else {
                "paired token stored"
            }
            "$marker ${host.displayName}  ${host.hostAddress}  [$authState]"
        }
    }

    private fun describeHost(host: HostProfile): String {
        val authState = if (SecureShellStore.inferConnectionMode(host.hostAddress) == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
            when {
                !host.sshPublicKey.isNullOrBlank() -> "SSH key 已生成"
                !host.sshPassword.isNullOrBlank() -> "SSH password 已保存"
                else -> "SSH 凭据未配置"
            }
        } else if (host.authToken.isNullOrBlank()) {
            "未配对"
        } else {
            "已保存 token"
        }
        val pairing = host.lastPairingCode ?: "未记录 pairing code"
        return "${host.displayName}\n${host.hostAddress}\n$authState · $pairing"
    }

    private fun attachSshKeyPairFallback(
        current: ShellProfile,
        hostId: String,
        generated: GeneratedSshKeyPair,
    ): ShellProfile {
        return current.copy(
            hosts = current.hosts.map { host ->
                if (host.id == hostId) {
                    host.copy(
                        sshPublicKey = generated.publicKeyOpenSsh,
                        sshPublicKeyPkcs8 = generated.publicKeyPkcs8Base64,
                        sshPrivateKeyPkcs8 = generated.privateKeyPkcs8Base64
                    )
                } else {
                    host
                }
            }
        )
    }

    private fun buildSshInstallCommand(host: HostProfile, deviceName: String): String {
        val publicKey = host.sshPublicKey ?: return ""
        if (SecureShellStore.inferConnectionMode(host.hostAddress) != HostConnectionMode.SSH_DIRECT_APP_SERVER) {
            return ""
        }
        val escapedKey = publicKey.replace("'", "'\"'\"'")
        val comment = normalizeDeviceName(deviceName)
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' '$escapedKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys # $comment"
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
                        clientVersion = APP_VERSION,
                        nativeLibraryDir = appContext.applicationInfo.nativeLibraryDir
                    )
                    @Suppress("UNCHECKED_CAST")
                    return ShellBootstrapViewModel(store, gateway, store) as T
                }
            }
        }

        private const val APP_VERSION = "0.1.0"
    }
}
