package com.codexisland.android.shell.bootstrap

import androidx.arch.core.executor.testing.InstantTaskExecutorRule
import com.codexisland.android.shell.runtime.EngineRuntimeGateway
import com.codexisland.android.shell.runtime.EngineRuntimeProbeResult
import com.codexisland.android.shell.storage.GeneratedSshKeyPair
import com.codexisland.android.shell.storage.HostProfile
import com.codexisland.android.shell.storage.HostProfileEditor
import com.codexisland.android.shell.storage.SecureShellStore
import com.codexisland.android.shell.storage.ShellProfile
import com.codexisland.android.shell.storage.ShellProfileStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ShellBootstrapViewModelTest {
    @get:Rule
    val instantTaskExecutorRule = InstantTaskExecutorRule()

    @Test
    fun saveHostProfilePersistsParsedQrPayloadAndSelectsHost() {
        val store = FakeShellProfileStore()
        val runtime = FakeRuntimeGateway()
        val viewModel = ShellBootstrapViewModel(store, runtime, FakeHostProfileEditor())

        viewModel.saveHostProfile(
            deviceName = " Pixel 9 ",
            hostConnectionInput = "codex-island://pair?addr=mbp.tail.ts.net:7331&name=MacBook%20Pro&token=secret-1&pairing_code=ABC-123",
            hostDisplayName = "",
            authToken = "",
            sshPassword = "",
            pairingCode = ""
        )

        val activeHost = store.profile.hosts.single()
        assertEquals("Pixel 9", store.profile.deviceName)
        assertEquals("MacBook Pro", activeHost.displayName)
        assertEquals("mbp.tail.ts.net:7331", activeHost.hostAddress)
        assertEquals("secret-1", activeHost.authToken)
        assertEquals(null, activeHost.sshPassword)
        assertEquals("ABC-123", activeHost.lastPairingCode)
        assertEquals(null, activeHost.sshPublicKey)
        assertEquals(activeHost.id, store.profile.activeHostId)
        assertEquals("secret-1", runtime.lastHost?.authToken)
    }

    @Test
    fun selectNextHostCyclesProfiles() {
        val profile = ShellProfile(
            deviceName = "Android Companion",
            hosts = listOf(
                hostProfile("1", "Host One", "one.tail.ts.net:7331", null, "AAA-111"),
                hostProfile("2", "Host Two", "two.tail.ts.net:7331", "token-2", "BBB-222")
            ),
            activeHostId = "1"
        )
        val store = FakeShellProfileStore(profile)
        val runtime = FakeRuntimeGateway()
        val viewModel = ShellBootstrapViewModel(store, runtime, FakeHostProfileEditor())

        viewModel.selectNextHost()

        assertEquals("2", store.profile.activeHostId)
        assertTrue(viewModel.uiState.value?.activeHostSummary?.contains("Host Two") == true)
    }

    @Test
    fun threadWorkspaceSupportsMessageApprovalAndInterruptFlow() {
        val profile = ShellProfile(
            deviceName = "Android Companion",
            hosts = listOf(
                hostProfile("1", "Host One", "one.tail.ts.net:7331", "token-1", "AAA-111")
            ),
            activeHostId = "1"
        )
        val store = FakeShellProfileStore(profile)
        val runtime = FakeRuntimeGateway()
        val viewModel = ShellBootstrapViewModel(store, runtime, FakeHostProfileEditor())

        viewModel.startThread()
        viewModel.sendMessage("please /approve apply_patch to config")

        assertTrue(viewModel.uiState.value?.approvalSummary?.contains("Command approval") == true)
        assertTrue(runtime.startedThread)

        viewModel.allowApproval()
        viewModel.interruptThread()

        assertTrue(viewModel.uiState.value?.approvalSummary?.contains("No pending") == true)
        assertTrue(viewModel.uiState.value?.activeThreadSummary?.contains("interrupted") == true)
    }

    @Test
    fun generateSshKeyPairPersistsOpenSshKeyAndInstallCommand() {
        val profile = ShellProfile(
            deviceName = "Android Companion",
            hosts = listOf(
                hostProfile("1", "Linux Box", "ssh://deploy@linux.tail.ts.net", null, null)
            ),
            activeHostId = "1"
        )
        val store = FakeShellProfileStore(profile)
        val runtime = FakeRuntimeGateway()
        val viewModel = ShellBootstrapViewModel(store, runtime, FakeHostProfileEditor())

        viewModel.generateSshKeyPair()

        val activeHost = store.profile.hosts.single()
        assertTrue(activeHost.sshPublicKey?.startsWith("ssh-rsa ") == true)
        assertTrue(activeHost.sshPrivateKeyPkcs8?.isNotBlank() == true)
        assertTrue(viewModel.uiState.value?.showSshKeyTools == true)
        assertTrue(viewModel.uiState.value?.sshInstallCommand?.contains("authorized_keys") == true)
    }

    private class FakeShellProfileStore(
        var profile: ShellProfile = ShellProfile(
            deviceName = "Android Companion",
            hosts = emptyList(),
            activeHostId = null
        )
    ) : ShellProfileStore {
        override fun load(): ShellProfile = profile

        override fun save(profile: ShellProfile) {
            this.profile = profile
        }
    }

    private class FakeRuntimeGateway : EngineRuntimeGateway {
        var lastHost: HostProfile? = null
        var startedThread: Boolean = false
        private var draftMessage: String = ""
        private var threadStatus: String = "idle"
        private var approvalSummary: String = "No pending approvals."

        override fun probe(
            hostProfile: HostProfile?,
            deviceName: String,
            pairingCode: String,
            draftMessage: String,
        ): EngineRuntimeProbeResult {
            lastHost = hostProfile
            this.draftMessage = draftMessage
            return EngineRuntimeProbeResult(
                runtimeLinked = true,
                engineStatus = "ok",
                bindingSurface = "surface 1",
                connection = "connecting",
                commandQueue = "2 pending",
                pairedDevices = "0 paired",
                reconnect = "idle",
                diagnostics = "connect=1",
                lastError = "none",
                helloCommandPreview = "{}",
                pairStartCommandPreview = "pair-start",
                pairConfirmCommandPreview = "pair-confirm",
                reconnectCommandPreview = "reconnect",
                threadListCommandPreview = "thread-list",
                threadStartCommandPreview = "thread-start",
                threadResumeCommandPreview = "thread-resume",
                turnStartCommandPreview = "turn-start",
                turnSteerCommandPreview = "turn-steer",
                interruptCommandPreview = "interrupt",
                nextSteps = "next",
                authToken = hostProfile?.authToken,
                pairingCode = pairingCode.ifBlank { hostProfile?.lastPairingCode },
                threadListSummary = if (startedThread) "• active Thread 1  [$threadStatus]" else "No live threads yet.",
                activeThreadSummary = if (startedThread) {
                    "Thread 1\nthread-1\nstatus=$threadStatus · turn=turn-1"
                } else {
                    "尚未创建 thread。"
                },
                chatTranscript = if (draftMessage.isBlank()) "No chat yet." else "[user] $draftMessage",
                approvalSummary = approvalSummary,
                userInputSummary = "No pending user-input requests."
            )
        }

        override fun refresh() = Unit

        override fun startThread() {
            startedThread = true
            threadStatus = "active"
        }

        override fun selectNextThread() = Unit

        override fun resumeThread() {
            threadStatus = "resumed"
        }

        override fun sendMessage(message: String) {
            draftMessage = message
            if (message.contains("/approve")) {
                approvalSummary = "Command approval\nNeed approval."
                threadStatus = "waiting_approval"
            }
        }

        override fun interruptThread() {
            threadStatus = "interrupted"
        }

        override fun respondToApproval(allow: Boolean) {
            approvalSummary = "No pending approvals."
            threadStatus = if (allow) "active" else "idle"
        }

        override fun submitUserInput(answer: String) = Unit
    }

    private class FakeHostProfileEditor : HostProfileEditor {
        override fun upsertHost(
            current: ShellProfile,
            rawConnectionInput: String,
            explicitDisplayName: String,
            explicitAuthToken: String,
            explicitSshPassword: String,
            pairingCode: String,
        ): ShellProfile {
            val parsed = SecureShellStore.parseHostInput(rawConnectionInput)
            val host = hostProfile(
                id = "host-1",
                displayName = explicitDisplayName.ifBlank { parsed.displayName ?: "Host" },
                hostAddress = parsed.hostAddress,
                authToken = explicitAuthToken.ifBlank { parsed.authToken },
                pairingCode = pairingCode.ifBlank { parsed.pairingCode },
                sshPassword = explicitSshPassword.ifBlank { parsed.sshPassword }
            )
            return current.copy(
                hosts = listOf(host),
                activeHostId = host.id
            )
        }

        override fun selectHost(current: ShellProfile, hostId: String): ShellProfile {
            return current.copy(activeHostId = hostId)
        }

        override fun activeHost(profile: ShellProfile): HostProfile? {
            return profile.hosts.firstOrNull { it.id == profile.activeHostId } ?: profile.hosts.firstOrNull()
        }

        override fun attachSshKeyPair(
            current: ShellProfile,
            hostId: String,
            keyPair: GeneratedSshKeyPair,
        ): ShellProfile {
            return current.copy(
                hosts = current.hosts.map { host ->
                    if (host.id == hostId) {
                        host.copy(
                            sshPublicKey = keyPair.publicKeyOpenSsh,
                            sshPublicKeyPkcs8 = keyPair.publicKeyPkcs8Base64,
                            sshPrivateKeyPkcs8 = keyPair.privateKeyPkcs8Base64
                        )
                    } else {
                        host
                    }
                }
            )
        }
    }

    companion object {
        private fun hostProfile(
            id: String,
            displayName: String,
            hostAddress: String,
            authToken: String?,
            pairingCode: String?,
            sshPassword: String? = null,
        ): HostProfile {
            return HostProfile(
                id = id,
                displayName = displayName,
                hostAddress = hostAddress,
                authToken = authToken,
                sshPassword = sshPassword,
                lastPairingCode = pairingCode,
                sshPublicKey = null,
                sshPublicKeyPkcs8 = null,
                sshPrivateKeyPkcs8 = null
            )
        }
    }
}
