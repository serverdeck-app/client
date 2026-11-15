package com.unng.serverdeck

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.os.StatFs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal class NativeReply(private val result: MethodChannel.Result, private val alive: () -> Boolean) {
    private val sent = AtomicBoolean(false)
    fun success(value: Any?) {
        try { if (sent.compareAndSet(false, true) && alive()) result.success(value) }
        finally { if (value is ByteArray) value.fill(0) }
    }
    fun error(code: String) {
        if (sent.compareAndSet(false, true) && alive()) result.error(code, "Native platform operation failed", null)
    }
}

internal class AndroidBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "serverdeck/android")
    private val epoch = UUID.randomUUID().toString()
    private val live = AtomicBoolean(true)
    private val stopped = AtomicBoolean(false)
    private val picker = NativePicker(activity, main)
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(34),
        { r -> Thread(r, "ServerDeck-platform").apply { isDaemon = true } })
    private var initialized = false
    private var root: File? = null
    private var metadata: AtomicMetadata? = null
    private var keys: LocalKeys? = null
    private var lease: WorkspaceLease? = null
    var resumed = false
    init { channel.setMethodCallHandler { call, result ->
        val reply = NativeReply(result, live::get)
        try {
            if (!live.get()) throw NativeFailure("SHUTTING_DOWN")
            val args = call.arguments as? Map<*, *> ?: throw NativeFailure("INVALID_ARGUMENT")
            if (args["version"] != 1) throw NativeFailure("INVALID_ARGUMENT")
            if (call.method == "initialize") {
                exact(args, setOf("version")); queue(reply, true) { initialize() }; return@setMethodCallHandler
            }
            if (args["ownerEpoch"] != epoch || !initialized) throw NativeFailure("STALE_OWNER")
            val control = call.method in setOf("platform.stopAdmission", "credential.cancelPick", "platform.drain", "platform.dispose")
            if (stopped.get() && !control) throw NativeFailure("SHUTTING_DOWN")
            when (call.method) {
                "secret.protect", "secret.unprotect" -> {
                    exact(args, setOf("version", "ownerEpoch", "purpose", "bytes"))
                    val purpose = args["purpose"] as? String ?: throw NativeFailure("INVALID_ARGUMENT")
                    validPurpose(purpose)
                    val borrowed = args["bytes"] as? ByteArray ?: throw NativeFailure("INVALID_ARGUMENT")
                    val protect = call.method == "secret.protect"
                    if (borrowed.size > if (protect) NativeLimits.secretBytes else NativeLimits.protectedBytes) { borrowed.fill(0); throw NativeFailure("INVALID_ARGUMENT") }
                    val bytes = borrowed.clone(); borrowed.fill(0)
                    queue(reply, false, { bytes.fill(0) }) {
                        try { val box = LocalEnvelope { keys!!.key() }; if (protect) box.protect(bytes, purpose) else box.unprotect(bytes, purpose) }
                        finally { bytes.fill(0) }
                    }
                }
                "file.flushAtomic" -> {
                    exact(args, setOf("version", "ownerEpoch", "path", "bytes"))
                    val path = args["path"] as? String ?: throw NativeFailure("INVALID_ARGUMENT")
                    val borrowed = args["bytes"] as? ByteArray ?: throw NativeFailure("INVALID_ARGUMENT")
                    if (borrowed.size > NativeLimits.metadataBytes) throw NativeFailure("INVALID_ARGUMENT")
                    val bytes = borrowed.clone(); borrowed.fill(0)
                    queue(reply, false, { bytes.fill(0) }) { try { metadata!!.flushAtomic(path, bytes); null } finally { bytes.fill(0) } }
                }
                "clock.sleepBounds" -> {
                    exact(args, setOf("version", "ownerEpoch"))
                    val before = SystemClock.uptimeMillis() * 1000000L
                    val elapsed = SystemClock.elapsedRealtimeNanos()
                    val after = (SystemClock.uptimeMillis() + 1) * 1000000L
                    val bounds = sleepBounds(before, elapsed, after)
                    reply.success(mapOf("lowerMicros" to bounds.first, "upperMicros" to bounds.second))
                }
                "storage.availableBytes" -> {
                    exact(args, setOf("version", "ownerEpoch"))
                    queue(reply) { StatFs(root!!.path).availableBytes }
                }
                "browser.open" -> {
                    exact(args, setOf("version", "ownerEpoch", "serviceOrigin", "page"))
                    if (!resumed) throw NativeFailure("BROWSER_UNAVAILABLE")
                    val origin = args["serviceOrigin"] as? String ?: throw NativeFailure("INVALID_ARGUMENT")
                    val page = args["page"] as? String ?: throw NativeFailure("INVALID_ARGUMENT")
                    val target = servicePage(origin, page)
                    try { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(target)).apply { addCategory(Intent.CATEGORY_BROWSABLE) }); reply.success(null) }
                    catch (_: Exception) { throw NativeFailure("BROWSER_UNAVAILABLE") }
                }
                "credential.pickKey" -> {
                    exact(args, setOf("version", "ownerEpoch"))
                    if (!resumed) throw NativeFailure("KEY_PICK_UNAVAILABLE")
                    picker.start(reply)
                }
                "credential.cancelPick" -> { exact(args, setOf("version", "ownerEpoch")); picker.cancel(); reply.success(null) }
                "platform.stopAdmission" -> { exact(args, setOf("version", "ownerEpoch")); stopped.set(true); picker.cancel(); reply.success(null) }
                "platform.drain" -> { exact(args, setOf("version", "ownerEpoch")); queue(reply, true) { null } }
                "platform.dispose" -> {
                    exact(args, setOf("version", "ownerEpoch")); stopped.set(true); picker.dispose()
                    queue(reply, true) { releaseLease(); worker.shutdown(); null }
                }
                else -> throw NativeFailure("INVALID_ARGUMENT")
            }
        } catch (e: NativeFailure) { reply.error(e.code) }
        catch (_: Exception) { reply.error("STORAGE_IO") }
        finally { ((call.arguments as? Map<*, *>)?.get("bytes") as? ByteArray)?.fill(0) }
    } }
    private fun exact(args: Map<*, *>, expected: Set<String>) {
        if (args.keys != expected) throw NativeFailure("INVALID_ARGUMENT")
    }
    private fun queue(reply: NativeReply, control: Boolean = false, rejected: () -> Unit = {}, action: () -> Any?) {
        if (!control && worker.queue.size >= 32) { rejected(); throw NativeFailure("RESOURCE_EXHAUSTED") }
        try { worker.execute {
            var value: Any? = null; var error: String? = null
            try {
                if (!live.get() || (!control && stopped.get())) throw NativeFailure("SHUTTING_DOWN")
                value = action()
            } catch (e: NativeFailure) { rejected(); error = e.code }
            catch (_: Exception) { rejected(); error = "STORAGE_IO" }
            val owned = value; val failure = error
            if (!main.post { if (failure != null) reply.error(failure) else if (!control && stopped.get()) { if (owned is ByteArray) owned.fill(0); reply.error("SHUTTING_DOWN") } else reply.success(owned) }) {
                if (owned is ByteArray) owned.fill(0)
            }
        } } catch (_: java.util.concurrent.RejectedExecutionException) { rejected(); throw NativeFailure("RESOURCE_EXHAUSTED") }
    }
    private fun initialize(): Map<String, Any> {
        if (stopped.get()) throw NativeFailure("SHUTTING_DOWN")
        if (initialized) return context()
        if (!Process.is64Bit()) throw NativeFailure("UNSUPPORTED_PLATFORM")
        try {
            val files = activity.filesDir.canonicalFile
            val proposed = File(files, "serverdeck")
            if (proposed.canonicalPath != proposed.absolutePath || (!proposed.exists() && !proposed.mkdir()) || !proposed.isDirectory) throw NativeFailure("STORAGE_IO")
            lease = WorkspaceLease.acquire(proposed)
            root = proposed
            val metadata = AtomicMetadata(proposed, AndroidMetadataIo()); this.metadata = metadata
            val keys = LocalKeys(AndroidLocalKeyStore(), metadata::hasPersistentData); this.keys = keys
            keys.prepare() // create only before first DB publication; never replace a missing existing key
            initialized = true
            return context()
        } catch (e: NativeFailure) { releaseLease(); throw e }
        catch (_: Exception) { releaseLease(); throw NativeFailure("STORAGE_IO") }
    }
    private fun context(): Map<String, Any> = mapOf("version" to 1, "ownerEpoch" to epoch, "dataRoot" to root!!.path, "platform" to "android")
    private fun releaseLease() { lease?.close(); lease = null }
    fun activityResult(code: Int, result: Int, data: Intent?): Boolean = picker.result(code, result, data)
    fun cleanup() {
        if (!live.compareAndSet(true, false)) return
        stopped.set(true); picker.dispose(); channel.setMethodCallHandler(null)
        try { worker.execute { try { releaseLease() } catch (_: Exception) {} } } catch (_: java.util.concurrent.RejectedExecutionException) {}
        worker.shutdown()
    }
}
