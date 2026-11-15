package com.unng.serverdeck

import java.util.concurrent.atomic.AtomicBoolean

internal class PickTicket(val code: Int) {
    val cancelled = AtomicBoolean(false)
    fun check() { if (cancelled.get()) throw NativeFailure("CANCELLED") }
}
/** Bounded process-wide codes: late activity results never acquire another owner. */
internal class PickerCodes(private var next: Int = 0x5300, private val last: Int = 0x7fff) {
    @Synchronized fun allocate(): Int {
        if (next > last) throw NativeFailure("RESOURCE_EXHAUSTED")
        return next++
    }
}
private val processPickerCodes = PickerCodes()
/** One selector/read per owner; cancelled stalled providers cannot spawn more readers. */
internal class PickerGate(private val codes: PickerCodes = processPickerCodes) {
    private var active: PickTicket? = null
    private var reading: PickTicket? = null
    private var closed = false
    @Synchronized fun reserve(): PickTicket {
        if (closed) throw NativeFailure("SHUTTING_DOWN")
        if (active != null || reading != null) throw NativeFailure("RESOURCE_EXHAUSTED")
        return PickTicket(codes.allocate()).also { active = it }
    }
    @Synchronized fun acceptsResult(code: Int): Boolean = !closed && active?.let { it.code == code && !it.cancelled.get() } == true
    @Synchronized fun beginRead(ticket: PickTicket) {
        if (closed || active !== ticket || ticket.cancelled.get()) throw NativeFailure("CANCELLED")
        if (reading != null) throw NativeFailure("RESOURCE_EXHAUSTED")
        reading = ticket
    }
    @Synchronized fun readFinished(ticket: PickTicket) { if (reading === ticket) reading = null }
    @Synchronized fun finish(ticket: PickTicket): Boolean {
        val accepted = !closed && active === ticket && !ticket.cancelled.get()
        if (active === ticket) active = null
        return accepted
    }
    @Synchronized fun cancel(ticket: PickTicket) {
        ticket.cancelled.set(true)
        if (active === ticket) active = null
    }
    @Synchronized fun close() {
        closed = true; active?.cancelled?.set(true); reading?.cancelled?.set(true); active = null
    }
}

/** Process-wide bound: an uncooperative old provider cannot accumulate readers after engine recreation. */
internal object PickerReadBudget {
    private var owner: PickTicket? = null
    @Synchronized fun busy() = owner != null
    @Synchronized fun reserve(ticket: PickTicket): Boolean {
        if (owner != null) return false
        owner = ticket; return true
    }
    @Synchronized fun release(ticket: PickTicket) { if (owner === ticket) owner = null }
}
