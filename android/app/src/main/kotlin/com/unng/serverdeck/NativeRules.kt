package com.unng.serverdeck

import java.io.InputStream
import java.net.URI
import java.net.InetAddress
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class NativeFailure(val code: String): RuntimeException("Native platform operation failed")
internal object NativeLimits {
    const val secretBytes = 1024 * 1024
    const val protectedBytes = 2 * 1024 * 1024
    const val metadataBytes = 8192
}
internal fun validPurpose(purpose: String) {
    if (purpose.isEmpty() || purpose.length > 128 || purpose.any { it.code !in 0x21..0x7e }) throw NativeFailure("INVALID_ARGUMENT")
}
internal interface LocalKeyStore {
    fun load(): SecretKey?
    fun create(): SecretKey
}
internal class LocalKeys(private val store: LocalKeyStore, private val hasData: () -> Boolean) {
    private var prepared = false
    @Synchronized fun prepare() {
        if (prepared) { key(); return }
        try {
            if (store.load() == null) {
                if (hasData()) throw NativeFailure("PROTECTION_UNAVAILABLE")
                store.create()
            }
            prepared = true
        } catch (e: NativeFailure) { throw e }
        catch (_: Exception) { throw NativeFailure("PROTECTION_UNAVAILABLE") }
    }
    @Synchronized fun key(): SecretKey {
        try { return if (prepared) store.load() ?: throw NativeFailure("PROTECTION_UNAVAILABLE") else throw NativeFailure("PROTECTION_UNAVAILABLE") }
        catch (_: Exception) { throw NativeFailure("PROTECTION_UNAVAILABLE") }
    }
}

internal class LocalEnvelope(private val key: () -> SecretKey) {
    private val header = byteArrayOf(0x53, 0x44, 0x41, 0x50, 1)
    private fun aad(purpose: String): ByteArray {
        val bytes = purpose.toByteArray(Charsets.US_ASCII)
        return header + byteArrayOf(0, 0, 0, bytes.size.toByte()) + bytes
    }
    fun protect(input: ByteArray, purpose: String): ByteArray {
        validPurpose(purpose)
        if (input.size > NativeLimits.secretBytes) throw NativeFailure("INVALID_ARGUMENT")
        val aad = aad(purpose)
        var encrypted: ByteArray? = null
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key()) // provider generates fresh randomized IV
            if (cipher.iv.size != 12) throw NativeFailure("PROTECTION_UNAVAILABLE")
            cipher.updateAAD(aad)
            encrypted = cipher.doFinal(input)
            if (encrypted.size != input.size + 16) throw NativeFailure("PROTECTION_UNAVAILABLE")
            return header + cipher.iv + encrypted
        } catch (_: Exception) { throw NativeFailure("PROTECTION_UNAVAILABLE") }
        finally { aad.fill(0); encrypted?.fill(0) }
    }
    fun unprotect(input: ByteArray, purpose: String): ByteArray {
        validPurpose(purpose)
        if (input.size < 33 || input.size > NativeLimits.protectedBytes || input.size > NativeLimits.secretBytes + 33 || !input.copyOfRange(0, 5).contentEquals(header)) throw NativeFailure("PROTECTION_UNAVAILABLE")
        val aad = aad(purpose)
        val iv = input.copyOfRange(5, 17)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            cipher.updateAAD(aad)
            return cipher.doFinal(input, 17, input.size - 17)
        } catch (_: Exception) { throw NativeFailure("PROTECTION_UNAVAILABLE") }
        finally { aad.fill(0); iv.fill(0) }
    }
}

internal fun readPickedBytes(stream: InputStream, check: () -> Unit): ByteArray {
    val buffer = ByteArray(NativeLimits.secretBytes + 1)
    var count = 0
    try {
        stream.use {
            while (true) {
                check()
                val n = it.read(buffer, count, minOf(16384, buffer.size - count))
                check()
                if (n == -1) return buffer.copyOf(count)
                if (n == 0) { // A provider must make progress; no spin or unbounded retry.
                    throw NativeFailure("KEY_PICK_UNAVAILABLE")
                }
                count += n
                if (count > NativeLimits.secretBytes) throw NativeFailure("INVALID_ARGUMENT")
            }
        }
    } catch (e: NativeFailure) { throw e }
    catch (_: Exception) { throw NativeFailure("KEY_PICK_UNAVAILABLE") }
    finally { buffer.fill(0) }
}

internal fun servicePage(origin: String, page: String): String {
    try {
        if (origin.length > 512 || origin.any { it.code !in 0x21..0x7e } || !origin.startsWith("https://") || origin.contains('%') || origin.contains('\\')) throw NativeFailure("INVALID_ARGUMENT")
        val uri = URI(origin)
        val host = uri.host ?: throw NativeFailure("INVALID_ARGUMENT")
        if (uri.scheme != "https" || uri.rawUserInfo != null || uri.rawPath != "" || uri.rawQuery != null || uri.rawFragment != null || host != host.lowercase(Locale.ROOT)) throw NativeFailure("INVALID_ARGUMENT")
        val port = uri.port
        if (port != -1 && (port !in 1..65535 || port == 443)) throw NativeFailure("INVALID_ARGUMENT")
        if (uri.rawAuthority != host + if (port == -1) "" else ":$port") throw NativeFailure("INVALID_ARGUMENT")
        if (host.startsWith("[")) {
            if (!host.endsWith("]") || !host.contains(':') || !Regex("[0-9a-fA-F:.]+").matches(host.substring(1, host.length - 1))) throw NativeFailure("INVALID_ARGUMENT")
            InetAddress.getByName(host.substring(1, host.length - 1)) // only checked numeric IPv6 literal, never DNS
        } else {
            if (host.length > 253 || host.split('.').any { it.length !in 1..63 || !Regex("[a-z0-9](?:[a-z0-9-]*[a-z0-9])?").matches(it) }) throw NativeFailure("INVALID_ARGUMENT")
            if (Regex("(?:[0-9]+|0x[0-9a-f]*)").matches(host.substringAfterLast('.'))) {
                val parts = host.split('.')
                if (parts.size != 4 || parts.any { !Regex("(?:0|[1-9][0-9]{0,2})").matches(it) || it.toInt() > 255 }) throw NativeFailure("INVALID_ARGUMENT")
            }
        }
        if (page == "$origin/activate" || page == "$origin/devices" || page == "$origin/account" || Regex(Regex.escape(origin) + "/activate\\?user_code=[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{10}").matches(page)) return page
    } catch (e: NativeFailure) { throw e }
    catch (_: Exception) { throw NativeFailure("INVALID_ARGUMENT") }
    throw NativeFailure("INVALID_ARGUMENT")
}

/** Native uptime brackets bound BOOTTIME minus MONOTONIC, including deep sleep. */
internal fun sleepBounds(awakeBeforeNanos: Long, elapsedNanos: Long, awakeAfterNanos: Long): Pair<Long, Long> {
    if (awakeBeforeNanos < 0 || elapsedNanos < 0 || awakeAfterNanos < awakeBeforeNanos) throw NativeFailure("TIMEOUT")
    return Pair((elapsedNanos - awakeAfterNanos) / 1000 - 1,
        (elapsedNanos - awakeBeforeNanos) / 1000 + 1)
}
