package com.unng.serverdeck

import android.app.Activity
import android.content.Intent
import android.os.CancellationSignal
import android.os.Handler
import java.io.InputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

internal class NativePicker(private val activity: Activity, private val main: Handler) {
    private class Pick(val ticket: PickTicket, val reply: NativeReply) {
        val code get() = ticket.code
        val cancelled get() = ticket.cancelled
        val signal = CancellationSignal()
        val stream = AtomicReference<InputStream?>(null)
        var timeout: java.util.concurrent.ScheduledFuture<*>? = null
        fun check() = ticket.check()
    }
    private val reader = Executors.newSingleThreadExecutor { r -> Thread(r, "ServerDeck-key-reader").apply { isDaemon = true } }
    private val closer = Executors.newSingleThreadExecutor { r -> Thread(r, "ServerDeck-key-close").apply { isDaemon = true } }
    private val timer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "ServerDeck-key-deadline").apply { isDaemon = true } }
    private val gate = PickerGate()
    private var pending: Pick? = null
    private var closed = false
    fun start(reply: NativeReply) {
        if (closed) throw NativeFailure("SHUTTING_DOWN")
        if (PickerReadBudget.busy()) throw NativeFailure("RESOURCE_EXHAUSTED")
        val pick = Pick(gate.reserve(), reply); pending = pick
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }, pick.code)
        } catch (_: Exception) { pending = null; gate.cancel(pick.ticket); throw NativeFailure("KEY_PICK_UNAVAILABLE") }
    }
    fun result(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val pick = pending ?: return false
        if (!gate.acceptsResult(requestCode)) return false
        if (resultCode == Activity.RESULT_CANCELED) { pending = null; abort(pick); pick.reply.success(null); return true }
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || uri.scheme != "content" || uri.authority.isNullOrEmpty() || (data.clipData?.itemCount ?: 0) > 1) {
            pending = null; abort(pick); pick.reply.error("KEY_PICK_UNAVAILABLE"); return true
        }
        try { gate.beginRead(pick.ticket) }
        catch (e: NativeFailure) { pending = null; gate.cancel(pick.ticket); pick.reply.error(e.code); return true }
        if (!PickerReadBudget.reserve(pick.ticket)) {
            gate.readFinished(pick.ticket); pending = null; abort(pick)
            pick.reply.error("RESOURCE_EXHAUSTED"); return true
        }
        pick.timeout = timer.schedule({ main.post { if (pending === pick) cancel("TIMEOUT") } }, 30, TimeUnit.SECONDS)
        reader.execute {
            var bytes: ByteArray? = null
            var error: String? = null
            try {
                pick.check()
                activity.contentResolver.openAssetFileDescriptor(uri, "r", pick.signal)?.use { descriptor ->
                    pick.check()
                    if (descriptor.declaredLength > NativeLimits.secretBytes) throw NativeFailure("INVALID_ARGUMENT")
                    val stream = descriptor.createInputStream(); pick.stream.set(stream)
                    bytes = readPickedBytes(stream, pick::check)
                    pick.stream.compareAndSet(stream, null)
                    pick.check()
                } ?: throw NativeFailure("KEY_PICK_UNAVAILABLE")
            } catch (e: NativeFailure) { error = e.code }
            catch (_: Exception) { error = "KEY_PICK_UNAVAILABLE" }
            finally {
                pick.timeout?.cancel(false)
                pick.stream.getAndSet(null)?.let { try { it.close() } catch (_: Exception) {} }
                gate.readFinished(pick.ticket)
                PickerReadBudget.release(pick.ticket)
            }
            val owned = bytes; val failure = error
            if (!main.post {
                if (pending === pick) pending = null
                if (!gate.finish(pick.ticket)) { owned?.fill(0); pick.reply.error("CANCELLED") }
                else if (failure != null) { owned?.fill(0); pick.reply.error(failure) }
                else pick.reply.success(owned)
            }) { owned?.fill(0) }
        }
        return true
    }
    private fun abort(pick: Pick) {
        gate.cancel(pick.ticket); pick.timeout?.cancel(false)
        closer.execute {
            try { pick.signal.cancel() } catch (_: Exception) {}
            pick.stream.getAndSet(null)?.let { try { it.close() } catch (_: Exception) {} }
        }
    }
    fun cancel(code: String = "CANCELLED") {
        val pick = pending ?: return
        pending = null; abort(pick)
        pick.reply.error(code)
        try { activity.finishActivity(pick.code) } catch (_: Exception) {}
    }
    fun dispose() {
        if (closed) return
        cancel(); closed = true; gate.close()
        reader.shutdown(); closer.shutdown(); timer.shutdown()
    }
}
