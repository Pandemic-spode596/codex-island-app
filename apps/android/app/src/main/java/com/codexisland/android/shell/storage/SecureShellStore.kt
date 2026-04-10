package com.codexisland.android.shell.storage

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.io.ByteArrayOutputStream
import java.security.KeyStore
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PublicKey
import java.security.interfaces.RSAPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.net.URLDecoder
import java.util.UUID
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class HostProfile(
    val id: String,
    val displayName: String,
    val hostAddress: String,
    val authToken: String?,
    val sshPassword: String?,
    val lastPairingCode: String?,
    val sshPublicKey: String?,
    val sshPublicKeyPkcs8: String?,
    val sshPrivateKeyPkcs8: String?,
)

data class ParsedHostInput(
    val hostAddress: String,
    val displayName: String?,
    val authToken: String?,
    val sshPassword: String?,
    val pairingCode: String?,
    val connectionMode: HostConnectionMode,
)

enum class HostConnectionMode {
    HOSTD_WEBSOCKET,
    SSH_DIRECT_APP_SERVER,
}

data class ShellProfile(
    val deviceName: String,
    val hosts: List<HostProfile>,
    val activeHostId: String?,
)

data class GeneratedSshKeyPair(
    val publicKeyOpenSsh: String,
    val publicKeyPkcs8Base64: String,
    val privateKeyPkcs8Base64: String,
) {
    fun toJavaKeyPair(): KeyPair {
        val keyFactory = KeyFactory.getInstance("RSA")
        val publicKey = keyFactory.generatePublic(
            X509EncodedKeySpec(Base64.getDecoder().decode(publicKeyPkcs8Base64))
        )
        val privateKey = keyFactory.generatePrivate(
            PKCS8EncodedKeySpec(Base64.getDecoder().decode(privateKeyPkcs8Base64))
        )
        return KeyPair(publicKey, privateKey)
    }
}

interface ShellProfileStore {
    fun load(): ShellProfile
    fun save(profile: ShellProfile)
}

interface HostProfileEditor {
    fun upsertHost(
        current: ShellProfile,
        rawConnectionInput: String,
        explicitDisplayName: String,
        explicitAuthToken: String,
        explicitSshPassword: String,
        pairingCode: String,
    ): ShellProfile

    fun selectHost(current: ShellProfile, hostId: String): ShellProfile
    fun activeHost(profile: ShellProfile): HostProfile?
    fun attachSshKeyPair(current: ShellProfile, hostId: String, keyPair: GeneratedSshKeyPair): ShellProfile
}

class SecureShellStore internal constructor(
    context: Context,
    private val cryptor: SecretCryptor = AndroidKeyStoreCryptor(),
) : ShellProfileStore, HostProfileEditor {
    private val preferences: SharedPreferences =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun load(): ShellProfile {
        val deviceName = preferences.getString(KEY_DEVICE_NAME, null)?.let(::decryptSafely)
            ?: DEFAULT_DEVICE_NAME
        val activeHostId = preferences.getString(KEY_ACTIVE_HOST_ID, null)?.let(::decryptSafely)
        val hosts = preferences.getString(KEY_HOSTS_JSON, null)?.let(::decryptSafely)?.let(::decodeHosts)
            ?: emptyList()

        return ShellProfile(
            deviceName = deviceName,
            hosts = hosts,
            activeHostId = activeHostId
        )
    }

    override fun save(profile: ShellProfile) {
        preferences.edit().apply {
            putString(KEY_DEVICE_NAME, cryptor.encrypt(profile.deviceName))
            putString(KEY_HOSTS_JSON, cryptor.encrypt(encodeHosts(profile.hosts)))

            if (profile.activeHostId.isNullOrBlank()) {
                remove(KEY_ACTIVE_HOST_ID)
            } else {
                putString(KEY_ACTIVE_HOST_ID, cryptor.encrypt(profile.activeHostId))
            }
        }.apply()
    }

    override fun upsertHost(
        current: ShellProfile,
        rawConnectionInput: String,
        explicitDisplayName: String,
        explicitAuthToken: String,
        explicitSshPassword: String,
        pairingCode: String,
    ): ShellProfile {
        val parsed = parseHostInput(rawConnectionInput)
        val normalizedAddress = parsed.hostAddress
        val connectionMode = parsed.connectionMode
        val displayName = explicitDisplayName.trim().ifBlank {
            parsed.displayName ?: normalizedAddress.substringBefore(':')
        }
        val authToken = if (connectionMode == HostConnectionMode.HOSTD_WEBSOCKET) {
            explicitAuthToken.trim().ifBlank { parsed.authToken }?.ifBlank { null }
        } else {
            null
        }
        val sshPassword = if (connectionMode == HostConnectionMode.SSH_DIRECT_APP_SERVER) {
            explicitSshPassword.trim().ifBlank { parsed.sshPassword }?.ifBlank { null }
        } else {
            null
        }
        val normalizedPairingCode = pairingCode.trim().ifBlank { parsed.pairingCode }?.ifBlank { null }

        val existing = current.hosts.firstOrNull { it.hostAddress.equals(normalizedAddress, ignoreCase = true) }
        val profile = HostProfile(
            id = existing?.id ?: UUID.randomUUID().toString(),
            displayName = displayName,
            hostAddress = normalizedAddress,
            authToken = authToken,
            sshPassword = sshPassword,
            lastPairingCode = normalizedPairingCode,
            sshPublicKey = existing?.sshPublicKey,
            sshPublicKeyPkcs8 = existing?.sshPublicKeyPkcs8,
            sshPrivateKeyPkcs8 = existing?.sshPrivateKeyPkcs8
        )

        val nextHosts = current.hosts
            .filterNot { it.id == profile.id }
            .plus(profile)
            .sortedBy { it.displayName.lowercase() }

        return current.copy(
            hosts = nextHosts,
            activeHostId = profile.id
        )
    }

    override fun selectHost(current: ShellProfile, hostId: String): ShellProfile {
        return if (current.hosts.any { it.id == hostId }) {
            current.copy(activeHostId = hostId)
        } else {
            current
        }
    }

    override fun activeHost(profile: ShellProfile): HostProfile? =
        profile.hosts.firstOrNull { it.id == profile.activeHostId }
            ?: profile.hosts.firstOrNull()

    override fun attachSshKeyPair(
        current: ShellProfile,
        hostId: String,
        keyPair: GeneratedSshKeyPair,
    ): ShellProfile {
        val updatedHosts = current.hosts.map { host ->
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
        return current.copy(hosts = updatedHosts)
    }

    private fun encodeHosts(hosts: List<HostProfile>): String {
        val array = JSONArray()
        hosts.forEach { host ->
            array.put(
                JSONObject()
                    .put("id", host.id)
                    .put("display_name", host.displayName)
                    .put("host_address", host.hostAddress)
                    .put("auth_token", host.authToken)
                    .put("ssh_password", host.sshPassword)
                    .put("last_pairing_code", host.lastPairingCode)
                    .put("ssh_public_key", host.sshPublicKey)
                    .put("ssh_public_key_pkcs8", host.sshPublicKeyPkcs8)
                    .put("ssh_private_key_pkcs8", host.sshPrivateKeyPkcs8)
            )
        }
        return array.toString()
    }

    private fun decodeHosts(json: String): List<HostProfile> {
        val array = JSONArray(json)
        return buildList {
            for (index in 0 until array.length()) {
                val objectValue = array.getJSONObject(index)
                add(
                    HostProfile(
                        id = objectValue.optString("id"),
                        displayName = objectValue.optString("display_name"),
                        hostAddress = objectValue.optString("host_address"),
                        authToken = objectValue.optString("auth_token").ifBlank { null },
                        sshPassword = objectValue.optString("ssh_password").ifBlank { null },
                        lastPairingCode = objectValue.optString("last_pairing_code").ifBlank { null },
                        sshPublicKey = objectValue.optString("ssh_public_key").ifBlank { null },
                        sshPublicKeyPkcs8 = objectValue.optString("ssh_public_key_pkcs8").ifBlank { null },
                        sshPrivateKeyPkcs8 = objectValue.optString("ssh_private_key_pkcs8").ifBlank { null }
                    )
                )
            }
        }.filter { it.id.isNotBlank() && it.displayName.isNotBlank() && it.hostAddress.isNotBlank() }
    }

    private fun decryptSafely(value: String): String? {
        return try {
            cryptor.decrypt(value)
        } catch (_: Throwable) {
            null
        }
    }

    companion object {
        private const val PREFERENCES_NAME = "codex_island.android.shell"
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_HOSTS_JSON = "hosts_json"
        private const val KEY_ACTIVE_HOST_ID = "active_host_id"
        private const val DEFAULT_DEVICE_NAME = "Android Companion"

        fun parseHostInput(rawInput: String): ParsedHostInput {
            val trimmed = rawInput.trim()
            require(trimmed.isNotEmpty()) { "Host address or QR payload is required." }

            if (trimmed.startsWith("codex-island://", ignoreCase = true)) {
                val queryParameters = parseQueryParameters(trimmed.substringAfter('?', ""))
                val hostAddress = queryParameters["addr"]
                    ?: queryParameters["address"]
                    ?: queryParameters["host"]
                    ?: throw IllegalArgumentException("QR payload missing host address.")

                return ParsedHostInput(
                    hostAddress = hostAddress.trim(),
                    displayName = queryParameters["name"]?.trim()?.ifBlank { null },
                    authToken = queryParameters["token"]?.trim()?.ifBlank { null }
                        ?: queryParameters["auth_token"]?.trim()?.ifBlank { null },
                    sshPassword = queryParameters["ssh_password"]?.trim()?.ifBlank { null },
                    pairingCode = queryParameters["pairing_code"]?.trim()?.ifBlank { null },
                    connectionMode = inferConnectionMode(hostAddress.trim())
                )
            }

            return ParsedHostInput(
                hostAddress = trimmed,
                displayName = null,
                authToken = null,
                sshPassword = null,
                pairingCode = null,
                connectionMode = inferConnectionMode(trimmed)
            )
        }

        fun inferConnectionMode(hostInput: String): HostConnectionMode {
            val trimmed = hostInput.trim()
            if (trimmed.startsWith("ssh://", ignoreCase = true)) {
                return HostConnectionMode.SSH_DIRECT_APP_SERVER
            }

            val normalized = trimmed.substringBefore('/')
            val hasScheme = trimmed.contains("://")
            val hasPort = normalized.substringAfterLast(':', "").all { it.isDigit() } && normalized.contains(':')
            val looksLikeUserAtHost = normalized.contains('@')
            return if (!hasScheme && looksLikeUserAtHost && !hasPort) {
                HostConnectionMode.SSH_DIRECT_APP_SERVER
            } else {
                HostConnectionMode.HOSTD_WEBSOCKET
            }
        }

        fun generateSshKeyPair(comment: String): GeneratedSshKeyPair {
            val generator = KeyPairGenerator.getInstance("RSA")
            generator.initialize(3072)
            val keyPair = generator.generateKeyPair()
            val publicKey = keyPair.public as RSAPublicKey
            val sanitizedComment = comment.trim().replace("\\s+".toRegex(), "-").ifBlank { "codex-island-android" }
            return GeneratedSshKeyPair(
                publicKeyOpenSsh = "${rsaOpenSshPrefix(publicKey)} $sanitizedComment",
                publicKeyPkcs8Base64 = Base64.getEncoder().encodeToString(keyPair.public.encoded),
                privateKeyPkcs8Base64 = Base64.getEncoder().encodeToString(keyPair.private.encoded)
            )
        }

        private fun rsaOpenSshPrefix(publicKey: RSAPublicKey): String {
            val payload = ByteArrayOutputStream().apply {
                writeSshString(this, "ssh-rsa".toByteArray(StandardCharsets.UTF_8))
                writeSshMpInt(this, publicKey.publicExponent.toByteArray())
                writeSshMpInt(this, publicKey.modulus.toByteArray())
            }.toByteArray()
            return "ssh-rsa ${Base64.getEncoder().encodeToString(payload)}"
        }

        private fun writeSshString(stream: ByteArrayOutputStream, value: ByteArray) {
            writeLength(stream, value.size)
            stream.write(value, 0, value.size)
        }

        private fun writeSshMpInt(stream: ByteArrayOutputStream, raw: ByteArray) {
            val normalized = when {
                raw.isEmpty() -> byteArrayOf(0)
                raw[0].toInt() and 0x80 != 0 -> byteArrayOf(0) + raw
                else -> raw
            }
            writeLength(stream, normalized.size)
            stream.write(normalized, 0, normalized.size)
        }

        private fun writeLength(stream: ByteArrayOutputStream, length: Int) {
            stream.write((length ushr 24) and 0xFF)
            stream.write((length ushr 16) and 0xFF)
            stream.write((length ushr 8) and 0xFF)
            stream.write(length and 0xFF)
        }

        private fun parseQueryParameters(query: String): Map<String, String> {
            if (query.isBlank()) {
                return emptyMap()
            }

            return query.split('&')
                .mapNotNull { part ->
                    val key = part.substringBefore('=', "").trim()
                    if (key.isBlank()) {
                        return@mapNotNull null
                    }
                    val value = part.substringAfter('=', "")
                    decode(key) to decode(value)
                }
                .toMap()
        }

        private fun decode(value: String): String =
            URLDecoder.decode(value, StandardCharsets.UTF_8)
    }
}

internal interface SecretCryptor {
    fun encrypt(value: String): String
    fun decrypt(value: String): String
}

internal class AndroidKeyStoreCryptor : SecretCryptor {
    override fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        return "${encode(iv)}:${encode(encrypted)}"
    }

    override fun decrypt(value: String): String {
        val (iv, encrypted) = value.split(":", limit = 2)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            getOrCreateKey(),
            GCMParameterSpec(GCM_TAG_LENGTH_BITS, decode(iv))
        )
        val decrypted = cipher.doFinal(decode(encrypted))
        return String(decrypted, StandardCharsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existingKey = (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
        if (existingKey != null) {
            return existingKey
        }

        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE
        )
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }

    private fun encode(bytes: ByteArray): String =
        Base64.getEncoder().encodeToString(bytes)

    private fun decode(value: String): ByteArray =
        Base64.getDecoder().decode(value)

    private companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "codex_island.android.shell.key"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_LENGTH_BITS = 128
    }
}
