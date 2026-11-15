package com.unng.serverdeck

import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import javax.crypto.spec.SecretKeySpec

class NativeAdaptersTest {
    @get:Rule val temp = TemporaryFolder()
    private fun fails(code: String, body: () -> Unit) {
        try { body(); fail("Expected $code") } catch (e: NativeFailure) { assertEquals(code, e.code) }
    }
    private val key = SecretKeySpec(ByteArray(32) { (it + 1).toByte() }, "AES")
    private fun box() = LocalEnvelope { key }
    @Test fun envelopeRoundTripAndNonce() {
        val bytes = byteArrayOf(0, 1, -1, 19)
        val a = box().protect(bytes, "credential.v1:test")
        val b = box().protect(bytes, "credential.v1:test")
        assertFalse(a.contentEquals(b))
        assertArrayEquals(bytes, box().unprotect(a, "credential.v1:test"))
        assertArrayEquals(byteArrayOf(0, 1, -1, 19), bytes)
        assertEquals(33 + bytes.size, a.size)
        assertEquals(33, box().protect(byteArrayOf(), "receipt-hmac.v1").size)
    }
    @Test fun envelopePurposeKeyAndTamperingAreAuthenticated() {
        val encrypted = box().protect(byteArrayOf(1, 2), "purpose:A")
        fails("PROTECTION_UNAVAILABLE") { box().unprotect(encrypted, "purpose:B") }
        val other = LocalEnvelope { SecretKeySpec(ByteArray(32) { 9 }, "AES") }
        fails("PROTECTION_UNAVAILABLE") { other.unprotect(encrypted, "purpose:A") }
        for (index in listOf(0, 4, 5, encrypted.lastIndex)) {
            val bad = encrypted.clone(); bad[index] = (bad[index].toInt() xor 1).toByte()
            fails("PROTECTION_UNAVAILABLE") { box().unprotect(bad, "purpose:A") }
        }
    }
    @Test fun envelopeLimitsAndPurposes() {
        val max = ByteArray(NativeLimits.secretBytes) { 17 }
        assertArrayEquals(max, box().unprotect(box().protect(max, "valid"), "valid"))
        fails("INVALID_ARGUMENT") { box().protect(ByteArray(max.size + 1), "valid") }
        for (purpose in listOf("", "x".repeat(129), "bad\u0000", "非ASCII")) {
            fails("INVALID_ARGUMENT") { box().protect(byteArrayOf(1), purpose) }
        }
        fails("PROTECTION_UNAVAILABLE") { box().unprotect(ByteArray(32), "valid") }
        fails("PROTECTION_UNAVAILABLE") { box().unprotect(ByteArray(NativeLimits.protectedBytes + 1), "valid") }
    }
    @Test fun startupDoesNotReplaceMissingExistingKey() {
        var creates = 0
        var current: javax.crypto.SecretKey? = null
        val store = object: LocalKeyStore {
            override fun load() = current
            override fun create(): javax.crypto.SecretKey { creates++; current = key; return key }
        }
        fails("PROTECTION_UNAVAILABLE") { LocalKeys(store) { true }.prepare() }
        assertEquals(0, creates)
        val keys = LocalKeys(store) { false }
        keys.prepare(); keys.prepare(); assertEquals(1, creates)
        current = null
        fails("PROTECTION_UNAVAILABLE") { keys.key() }
        assertEquals(1, creates)
    }
    @Test fun boundedPickerPreservesExactBytesAndCloses() {
        var closed = false
        val bytes = ByteArray(NativeLimits.secretBytes) { it.toByte() }
        val stream = object: ByteArrayInputStream(bytes) { override fun close() { closed = true; super.close() } }
        assertArrayEquals(bytes, readPickedBytes(stream) {})
        assertTrue(closed)
    }
    @Test fun pickerOversizeErrorAndCancelNeverReturnPartialContent() {
        var closed = false
        val stream = object: ByteArrayInputStream(ByteArray(NativeLimits.secretBytes + 1)) {
            override fun close() { closed = true; super.close() }
        }
        fails("INVALID_ARGUMENT") { readPickedBytes(stream) {} }
        assertTrue(closed)
        fails("CANCELLED") { readPickedBytes(ByteArrayInputStream(byteArrayOf(1))) { throw NativeFailure("CANCELLED") } }
        fails("KEY_PICK_UNAVAILABLE") { readPickedBytes(object: java.io.InputStream() {
            override fun read(): Int = throw java.io.IOException("synthetic private error")
        }) {} }
    }
    @Test fun browserWhitelistAndExactOrigin() {
        for (path in listOf("/devices", "/account", "/activate", "/activate?user_code=ABCDEFGHJK")) {
            assertEquals("https://sync.example.test$path", servicePage("https://sync.example.test", "https://sync.example.test$path"))
        }
        for (uri in listOf("https://other.test/devices", "http://sync.example.test/devices", "https://sync.example.test/devices?token=secret", "https://sync.example.test/activate?user_code=ABCDEFGHIJ", "https://sync.example.test/activate?user_code=ABCDEFGHJK&x=y", "https://sync.example.test/%64evices", "https://sync.example.test/devices#", "https://u@sync.example.test/devices", "file:///devices")) {
            fails("INVALID_ARGUMENT") { servicePage("https://sync.example.test", uri) }
        }
        for (origin in listOf("https://0x", "https://127.1", "https://sync.example.test:443", "https://SYNC.example.test", "https://sync.example.test/")) {
            fails("INVALID_ARGUMENT") { servicePage(origin, "$origin/devices") }
        }
        assertEquals("https://[::1]:8443/devices", servicePage("https://[::1]:8443", "https://[::1]:8443/devices"))
    }
    private class TestIo: MetadataIo {
        val events = mutableListOf<String>()
        var failCurrent = false
        var failDirectory: String? = null
        override fun syncFile(file: File) { events.add("file:" + file.name); RandomAccessFile(file, "rw").use { it.fd.sync() } }
        override fun syncDirectory(file: File) {
            events.add("dir:" + file.name)
            if (failDirectory == file.name) { failDirectory = null; throw java.io.IOException("synthetic directory sync failure") }
        }
        override fun rename(source: File, target: File) {
            if (target.name == "CURRENT.json" && failCurrent) throw java.io.IOException("synthetic rename failure")
            events.add("rename:" + target.name)
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        }
    }
    private val id = "00000000-0000-4000-8000-000000000001"
    @Test fun metadataFlushPublishAndRetryNeverInventEmptyData() {
        val root = temp.newFolder("workspace"); val io = TestIo(); val metadata = AtomicMetadata(root, io)
        assertFalse(metadata.hasPersistentData())
        val staging = File(root, "data/staging-$id"); staging.mkdirs()
        File(staging, "serverdeck.isar").writeBytes(byteArrayOf(3, 5, 7))
        assertTrue(metadata.hasPersistentData())
        metadata.flushAtomic("data/flush/$id", byteArrayOf())
        assertFalse(File(root, "data/CURRENT.json").exists())
        io.failCurrent = true
        fails("STORAGE_IO") { metadata.flushAtomic("data/publish/$id", publicationBytes(id)) }
        assertFalse(File(root, "data/CURRENT.json").exists())
        assertArrayEquals(byteArrayOf(3, 5, 7), File(root, "data/stores/$id/serverdeck.isar").readBytes())
        io.failCurrent = false
        metadata.flushAtomic("data/publish/$id", publicationBytes(id))
        assertArrayEquals(publicationBytes(id), File(root, "data/CURRENT.json").readBytes())
        assertTrue(io.events.indexOf("file:serverdeck.isar") < io.events.indexOf("rename:$id"))
        assertTrue(io.events.indexOf("rename:$id") < io.events.indexOf("rename:CURRENT.json"))
    }
    @Test fun metadataRejectsTraversalMismatchedManifestAndMissingOrAmbiguousSources() {
        val root = temp.newFolder("workspace"); val metadata = AtomicMetadata(root, TestIo())
        fails("INVALID_ARGUMENT") { metadata.flushAtomic("../outside", byteArrayOf()) }
        fails("INVALID_ARGUMENT") { metadata.flushAtomic("data/publish/$id", publicationBytes("00000000-0000-4000-8000-000000000002")) }
        fails("STORAGE_IO") { metadata.flushAtomic("data/publish/$id", publicationBytes(id)) }
        File(root,"data/staging-$id").mkdirs(); File(root,"data/stores/$id").mkdirs()
        fails("STORAGE_IO") { metadata.flushAtomic("data/publish/$id", publicationBytes(id)) }
        fails("INVALID_ARGUMENT") { metadata.flushAtomic("data/flush/$id", byteArrayOf(1)) }
    }
    @Test fun metadataFailurePreservesPreviousCurrent() {
        val root=temp.newFolder("workspace"); val io=TestIo(); val metadata=AtomicMetadata(root,io)
        File(root,"data/staging-$id").mkdirs()
        metadata.flushAtomic("data/publish/$id",publicationBytes(id))
        val another="00000000-0000-4000-8000-000000000002"
        File(root,"data/staging-$another").mkdirs(); io.failCurrent=true
        fails("STORAGE_IO") { metadata.flushAtomic("data/publish/$another",publicationBytes(another)) }
        assertArrayEquals(publicationBytes(id),File(root,"data/CURRENT.json").readBytes())
    }
    @Test fun pickerGateRejectsStalledReadReplacementAndStaleSelectorResults() {
        val gate=PickerGate(); val first=gate.reserve()
        fails("RESOURCE_EXHAUSTED") { gate.reserve() }
        gate.beginRead(first); gate.cancel(first)
        fails("CANCELLED") { first.check() }
        fails("RESOURCE_EXHAUSTED") { gate.reserve() }
        gate.readFinished(first)
        val second=gate.reserve()
        assertNotEquals(first.code,second.code)
        assertFalse(gate.finish(first))
        gate.beginRead(second); gate.readFinished(second)
        assertTrue(gate.finish(second))
        val third=gate.reserve(); gate.close()
        fails("CANCELLED") { third.check() }
        fails("SHUTTING_DOWN") { gate.reserve() }
    }
    @Test fun exclusiveWorkspaceLeaseCanOnlyBeReacquiredAfterClose() {
        val root=temp.newFolder("lease")
        val first=WorkspaceLease.acquire(root)
        fails("RESOURCE_EXHAUSTED") { WorkspaceLease.acquire(root) }
        first.close(); first.close()
        WorkspaceLease.acquire(root).close()
    }
    @Test fun metadataRejectsOversizeAndTooManySyntheticStoreEntries() {
        val root=temp.newFolder("many"); val metadata=AtomicMetadata(root,TestIo())
        fails("INVALID_ARGUMENT") { metadata.flushAtomic("data/CURRENT.json",ByteArray(8193)) }
        val staging=File(root,"data/staging-$id"); staging.mkdirs()
        repeat(129) { File(staging,"synthetic-$it").writeBytes(byteArrayOf(1)) }
        fails("RESOURCE_EXHAUSTED") { metadata.flushAtomic("data/flush/$id",byteArrayOf()) }
        assertFalse(File(root,"data/CURRENT.json").exists())
    }

    @Test fun pickerReadBudgetSurvivesOldOwnerCancellationAndRejectsStaleRelease() {
        val first=PickTicket(1); val second=PickTicket(2)
        try {
            assertTrue(PickerReadBudget.reserve(first)); first.cancelled.set(true)
            assertTrue(PickerReadBudget.busy()); assertFalse(PickerReadBudget.reserve(second))
            PickerReadBudget.release(second); assertTrue(PickerReadBudget.busy())
            PickerReadBudget.release(first); assertTrue(PickerReadBudget.reserve(second))
            PickerReadBudget.release(first); assertTrue(PickerReadBudget.busy())
        } finally { PickerReadBudget.release(first); PickerReadBudget.release(second) }
        assertFalse(PickerReadBudget.busy())
    }

    @Test fun metadataRetryAfterRenameFailureReprovesBothParentSyncsBeforeCurrent() {
        for (failed in listOf("stores", "data")) {
            val root=temp.newFolder("parent-$failed"); val io=TestIo(); val metadata=AtomicMetadata(root,io)
            val staging=File(root,"data/staging-$id"); staging.mkdirs()
            File(staging,"synthetic.isar").writeBytes(byteArrayOf(1,2,3))
            io.failDirectory=failed
            fails("STORAGE_IO") { metadata.flushAtomic("data/publish/$id",publicationBytes(id)) }
            assertTrue(File(root,"data/stores/$id").isDirectory)
            assertFalse(File(root,"data/CURRENT.json").exists())
            io.events.clear()
            metadata.flushAtomic("data/publish/$id",publicationBytes(id))
            val current=io.events.indexOf("rename:CURRENT.json")
            assertTrue(current > 0)
            for (parent in listOf("stores","data")) {
                val synced=io.events.indexOf("dir:$parent")
                assertTrue("$parent sync must precede CURRENT on retry", synced >= 0 && synced < current)
            }
            assertArrayEquals(publicationBytes(id),File(root,"data/CURRENT.json").readBytes())
        }
    }
    @Test fun processCodesRejectOldOwnerSelectorAndCancelResultsWithoutReuse() {
        val oldGate=PickerGate(); val old=oldGate.reserve()
        oldGate.cancel(old); oldGate.close()
        val newGate=PickerGate(); val current=newGate.reserve()
        assertNotEquals(old.code,current.code)
        assertFalse(newGate.acceptsResult(old.code))
        // Native dispatch rejects a stale success or CANCEL before interpreting it.
        if (newGate.acceptsResult(old.code)) newGate.cancel(current)
        assertTrue(newGate.acceptsResult(current.code))
        assertTrue(newGate.finish(current))
        assertFalse(oldGate.acceptsResult(current.code))
    }

    @Test fun boundedProcessCodeAllocatorFailsWithoutWrapping() {
        val codes=PickerCodes(0x5300,0x5301)
        val first=PickerGate(codes); first.cancel(first.reserve())
        val second=PickerGate(codes); second.cancel(second.reserve())
        fails("RESOURCE_EXHAUSTED") { PickerGate(codes).reserve() }
    }

    @Test fun nativeSleepSampleBoundsContainSuspendOffsetAndRejectClockRollback() {
        val sample = sleepBounds(1000000L, 600001234000L, 2000000L)
        assertTrue(sample.first <= 600000000L)
        assertTrue(sample.second >= 600000000L)
        fails("TIMEOUT") { sleepBounds(20,30,10) }
    }

}
