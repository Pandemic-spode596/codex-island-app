package com.codexisland.android.shell.bootstrap

import androidx.arch.core.executor.testing.InstantTaskExecutorRule
import com.codexisland.android.shell.runtime.EngineRuntimeGateway
import com.codexisland.android.shell.runtime.EngineRuntimeProbeResult
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
        val secureStore = FakeHostProfileEditor()
        val viewModel = ShellBootstrapViewModel(store, runtime, secureStore)

        viewModel.saveHostProfile(
            deviceName = " Pixel 9 ",
            hostConnectionInput = "codex-island://pair?addr=mbp.tail.ts.net:7331&name=MacBook%20Pro&token=secret-1&pairing_code=ABC-123",
            hostDisplayName = "",
            authToken = "",
            pairingCode = ""
        )

        val activeHost = store.profile.hosts.single()
        assertEquals("Pixel 9", store.profile.deviceName)
        assertEquals("MacBook Pro", activeHost.displayName)
        assertEquals("mbp.tail.ts.net:7331", activeHost.hostAddress)
        assertEquals("secret-1", activeHost.authToken)
        assertEquals("ABC-123", activeHost.lastPairingCode)
        assertEquals(activeHost.id, store.profile.activeHostId)
        assertEquals("secret-1", runtime.lastHost?.authToken)
    }

    @Test
    fun selectNextHostCyclesProfiles() {
        val profile = ShellProfile(
            deviceName = "Android Companion",
            hosts = listOf(
                HostProfile("1", "Host One", "one.tail.ts.net:7331", null, "AAA-111"),
                HostProfile("2", "Host Two", "two.tail.ts.net:7331", "token-2", "BBB-222")
            ),
            activeHostId = "1"
        )
        val store = FakeShellProfileStore(profile)
        val runtime = FakeRuntimeGateway()
        val secureStore = FakeHostProfileEditor()
        val viewModel = ShellBootstrapViewModel(store, runtime, secureStore)

        viewModel.selectNextHost()

        assertEquals("2", store.profile.activeHostId)
        assertTrue(viewModel.uiState.value?.activeHostSummary?.contains("Host Two") == true)
    }

    @Test
    fun threadWorkspaceSupportsMessageApprovalAndInterruptFlow() {
        val profile = ShellProfile(
            deviceName = "Android Companion",
            hosts = listOf(
                HostProfile("1", "Host One", "one.tail.ts.net:7331", "token-1", "AAA-111")
            ),
            activeHostId = "1"
        )
        val store = FakeShellProfileStore(profile)
        val runtime = FakeRuntimeGateway()
        val viewModel = ShellBootstrapViewModel(store, runtime, FakeHostProfileEditor())

        viewModel.startThread()
        viewModel.sendMessage("please /approve apply_patch to config")

        assertTrue(viewModel.uiState.value?.approvalSummary?.contains("Command approval") == true)
        assertTrue(runtime.lastActiveThreadId != null)

        viewModel.allowApproval()
        viewModel.interruptThread()

        assertTrue(viewModel.uiState.value?.approvalSummary?.contains("No pending") == true)
        assertTrue(viewModel.uiState.value?.activeThreadSummary?.contains("interrupted") == true)
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
        var lastActiveThreadId: String? = null

        override fun probe(
            hostProfile: HostProfile?,
            deviceName: String,
            activeThreadId: String?,
            activeTurnId: String?,
            draftMessage: String,
        ): EngineRuntimeProbeResult {
            lastHost = hostProfile
            lastActiveThreadId = activeThreadId
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
                nextSteps = "next"
            )
        }
    }

    private class FakeHostProfileEditor : HostProfileEditor {
        override fun upsertHost(
            current: ShellProfile,
            rawConnectionInput: String,
            explicitDisplayName: String,
            explicitAuthToken: String,
            pairingCode: String,
        ): ShellProfile {
            val parsed = SecureShellStore.parseHostInput(rawConnectionInput)
            val host = HostProfile(
                id = "host-1",
                displayName = explicitDisplayName.ifBlank { parsed.displayName ?: "Host" },
                hostAddress = parsed.hostAddress,
                authToken = explicitAuthToken.ifBlank { parsed.authToken },
                lastPairingCode = pairingCode.ifBlank { parsed.pairingCode }
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
    }
}
