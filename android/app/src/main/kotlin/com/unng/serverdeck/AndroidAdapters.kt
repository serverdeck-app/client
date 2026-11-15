package com.unng.serverdeck

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import android.system.ErrnoException
import java.io.File
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

internal class AndroidLocalKeyStore: LocalKeyStore {
    private val alias = "serverdeck.local.v1"
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    override fun load(): SecretKey? {
        val store = store()
        if (!store.containsAlias(alias)) return null
        return store.getKey(alias, null) as? SecretKey ?: throw NativeFailure("PROTECTION_UNAVAILABLE")
    }
    override fun create(): SecretKey {
        if (store().containsAlias(alias)) throw NativeFailure("PROTECTION_UNAVAILABLE")
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true).setUserAuthenticationRequired(false).build())
        return generator.generateKey()
    }
}
internal class AndroidMetadataIo: MetadataIo {
    override fun syncFile(file: File) {
        val fd = Os.open(file.path, OsConstants.O_RDWR or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        try { Os.fsync(fd) } finally { Os.close(fd) }
    }
    override fun syncDirectory(file: File) {
        val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        try {
            if (!OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) throw NativeFailure("STORAGE_IO")
            try { Os.fsync(fd) }
            catch (e: ErrnoException) { if (e.errno != OsConstants.EINVAL && e.errno != OsConstants.EOPNOTSUPP) throw e }
        } finally { Os.close(fd) }
    }
    override fun rename(source: File, target: File) { Os.rename(source.path, target.path) }
}
