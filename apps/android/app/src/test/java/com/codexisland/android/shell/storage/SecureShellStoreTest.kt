package com.codexisland.android.shell.storage

import org.junit.Assert.assertEquals
import org.junit.Test

class SecureShellStoreTest {
    @Test
    fun parseHostInputAcceptsQrPayload() {
        val parsed = SecureShellStore.parseHostInput(
            "codex-island://pair?addr=linux.tail.ts.net:7331&name=Linux%20Box&token=abc123&pairing_code=PAIR-777"
        )

        assertEquals("linux.tail.ts.net:7331", parsed.hostAddress)
        assertEquals("Linux Box", parsed.displayName)
        assertEquals("abc123", parsed.authToken)
        assertEquals(null, parsed.sshPassword)
        assertEquals("PAIR-777", parsed.pairingCode)
        assertEquals(HostConnectionMode.HOSTD_WEBSOCKET, parsed.connectionMode)
    }

    @Test
    fun parseHostInputAcceptsManualAddress() {
        val parsed = SecureShellStore.parseHostInput("macbook.tail.ts.net:7331")

        assertEquals("macbook.tail.ts.net:7331", parsed.hostAddress)
        assertEquals(null, parsed.displayName)
        assertEquals(null, parsed.authToken)
        assertEquals(null, parsed.sshPassword)
        assertEquals(null, parsed.pairingCode)
        assertEquals(HostConnectionMode.HOSTD_WEBSOCKET, parsed.connectionMode)
    }

    @Test
    fun parseHostInputTreatsSshTargetAsDirectMode() {
        val parsed = SecureShellStore.parseHostInput("ssh://deploy@linux.tail.ts.net")

        assertEquals("ssh://deploy@linux.tail.ts.net", parsed.hostAddress)
        assertEquals(HostConnectionMode.SSH_DIRECT_APP_SERVER, parsed.connectionMode)
    }
}
