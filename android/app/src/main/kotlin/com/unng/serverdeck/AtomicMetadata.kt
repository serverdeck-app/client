package com.unng.serverdeck

import java.io.File
import java.io.FileOutputStream
import java.util.UUID

internal interface MetadataIo {
    fun syncFile(file: File)
    fun syncDirectory(file: File)
    fun rename(source: File, target: File)
}
internal val storeIdPattern = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
internal fun publicationBytes(id: String): ByteArray {
    if (!storeIdPattern.matches(id)) throw NativeFailure("INVALID_ARGUMENT")
    return ("{\"publicationVersion\":1,\"formatVersion\":2,\"storeId\":\"$id\",\"relativeDirectory\":\"stores/$id\"}").toByteArray(Charsets.UTF_8)
}

internal class AtomicMetadata(private val root: File, private val io: MetadataIo) {
    private fun checked(file: File): File {
        if (file.absolutePath != file.canonicalPath || !file.canonicalPath.startsWith(root.canonicalPath + File.separator)) throw NativeFailure("STORAGE_IO")
        return file
    }
    private fun directory(file: File): File {
        checked(file)
        if ((!file.exists() && !file.mkdir()) || !file.isDirectory) throw NativeFailure("STORAGE_IO")
        return file
    }
    private fun entries(source: File): List<File> {
        val entries = mutableListOf<File>()
        fun visit(file: File, depth: Int) {
            checked(file)
            if (depth > 8 || entries.size >= 128) throw NativeFailure("RESOURCE_EXHAUSTED")
            entries.add(file)
            if (file.isDirectory) {
                val children = file.listFiles() ?: throw NativeFailure("STORAGE_IO")
                if (children.size > 128) throw NativeFailure("RESOURCE_EXHAUSTED")
                for (child in children) visit(child, depth + 1)
            } else if (!file.isFile) throw NativeFailure("STORAGE_IO")
        }
        visit(source, 0)
        return entries
    }
    fun hasPersistentData(): Boolean {
        try {
            val data = checked(File(root, "data"))
            if (!data.exists()) return false
            return entries(data).any { it.isFile }
        } catch (e: NativeFailure) { throw e }
        catch (_: Exception) { throw NativeFailure("STORAGE_IO") }
    }
    private fun flushStore(source: File) {
        if (!source.isDirectory) throw NativeFailure("STORAGE_IO")
        val entries = entries(source)
        for (entry in entries) if (entry.isFile) io.syncFile(entry)
        for (entry in entries.asReversed()) if (entry.isDirectory) io.syncDirectory(entry)
    }
    private fun current(bytes: ByteArray) {
        val data = directory(File(root, "data"))
        val target = checked(File(data, "CURRENT.json"))
        val temp = checked(File(data, ".CURRENT-${UUID.randomUUID()}.tmp"))
        try {
            if (!temp.createNewFile()) throw NativeFailure("STORAGE_IO")
            FileOutputStream(temp).use { stream -> stream.write(bytes); stream.flush(); stream.fd.sync() }
            io.rename(temp, target)
            io.syncDirectory(data)
        } finally {
            if (temp.exists()) temp.delete() // only own temp, never saved DB/current
        }
    }
    fun flushAtomic(path: String, bytes: ByteArray) {
        if (bytes.size > NativeLimits.metadataBytes) throw NativeFailure("INVALID_ARGUMENT")
        try {
            val flush = path.startsWith("data/flush/")
            val publish = path.startsWith("data/publish/")
            val id = if (flush) path.removePrefix("data/flush/") else if (publish) path.removePrefix("data/publish/") else if (path == "data/CURRENT.json") {
                val decoded = bytes.toString(Charsets.UTF_8)
                Regex("\"storeId\":\"([^\"]+)\"").find(decoded)?.groupValues?.get(1) ?: throw NativeFailure("INVALID_ARGUMENT")
            } else throw NativeFailure("INVALID_ARGUMENT")
            if (!storeIdPattern.matches(id) || (flush && bytes.isNotEmpty()) || (!flush && !bytes.contentEquals(publicationBytes(id)))) throw NativeFailure("INVALID_ARGUMENT")
            val data = directory(File(root, "data"))
            val stores = directory(File(data, "stores"))
            val staging = checked(File(data, "staging-$id"))
            val destination = checked(File(stores, id))
            val hasStaging = staging.exists(); val hasDestination = destination.exists()
            if (hasStaging == hasDestination || (flush && !hasStaging) || (path == "data/CURRENT.json" && !hasDestination)) throw NativeFailure("STORAGE_IO")
            flushStore(if (hasStaging) staging else destination)
            if (!flush) {
                if (hasStaging) {
                    io.rename(staging, destination)
                }
                // A prior attempt may have renamed successfully but failed fsync.
                // Re-prove parent durability even when destination already exists.
                io.syncDirectory(stores); io.syncDirectory(data)
                current(bytes)
            }
        } catch (e: NativeFailure) { throw e }
        catch (_: Exception) { throw NativeFailure("STORAGE_IO") }
    }
}
