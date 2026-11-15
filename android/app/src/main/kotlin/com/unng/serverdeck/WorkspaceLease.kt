package com.unng.serverdeck

import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException

internal class WorkspaceLease private constructor(private val file: RandomAccessFile, private val lock: FileLock) {
    private var closed = false
    @Synchronized fun close() {
        if (closed) return
        closed = true
        try { lock.release() } finally { file.close() }
    }
    companion object {
        fun acquire(root: File): WorkspaceLease {
            if (!root.isDirectory || root.absolutePath != root.canonicalPath) throw NativeFailure("STORAGE_IO")
            val path = File(root, "owner.lock")
            if (path.absolutePath != path.canonicalPath || path.isDirectory) throw NativeFailure("STORAGE_IO")
            var opened: RandomAccessFile? = null
            try {
                opened = RandomAccessFile(path, "rw")
                val lock = opened.channel.tryLock() ?: throw NativeFailure("RESOURCE_EXHAUSTED")
                return WorkspaceLease(opened, lock)
            } catch (_: OverlappingFileLockException) {
                opened?.close(); throw NativeFailure("RESOURCE_EXHAUSTED")
            } catch (e: NativeFailure) { opened?.close(); throw e }
            catch (_: Exception) { opened?.close(); throw NativeFailure("STORAGE_IO") }
        }
    }
}
