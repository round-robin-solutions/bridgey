package dev.bridgey.android.display

import dev.bridgey.android.screen.ScreenFrameHeader
import java.io.ByteArrayOutputStream

/** One whole access unit, ready to decode. */
class AssembledFrame(val frame: Long, val key: Boolean, val parameterSets: Boolean, val captureMicros: Long, val data: ByteArray)

/**
 * Puts the parts of each display.frame back together, as the Mac's ScreenFrameAssembler does for screen.frame. Keeps
 * one unfinished frame; a part out of order, a missing part 0 or a later frame arriving first loses the frame, and
 * the caller then waits for a key frame. Not thread safe: the hub calls it under its lock.
 */
class DisplayFrameAssembler {
    sealed interface Event {
        /** Waiting for more parts. */
        data object Pending : Event

        data class Complete(val frame: AssembledFrame) : Event

        /** A frame was lost; [frame] is the newest frame number seen. */
        data class Lost(val frame: Long) : Event

        /** A part of a frame already finished or given up: dropped quietly. */
        data object Ignored : Event
    }

    private class Partial(val frame: Long, var nextPart: Int, val key: Boolean, val parameterSets: Boolean, val captureMicros: Long) {
        val data = ByteArrayOutputStream()
    }

    private var partial: Partial? = null

    /** The newest frame number finished or given up. */
    var newestFrame = 0L
        private set

    fun add(header: ScreenFrameHeader, payload: ByteArray): Event {
        if (header.frame <= newestFrame) return Event.Ignored
        var lostOne = false
        partial?.let { if (it.frame != header.frame) { partial = null; lostOne = true } }
        val current = partial
        if (current != null) {
            if (header.part != current.nextPart) return giveUp(header.frame)
            current.data.write(payload)
            current.nextPart += 1
        } else {
            if (header.part != 0) return giveUp(header.frame)
            partial = Partial(header.frame, 1, header.key, header.parameterSets, header.captureMicros).also { it.data.write(payload) }
        }
        val done = partial
        if (header.last && done != null) {
            partial = null
            newestFrame = done.frame
            // A lost earlier frame still means the decoder needs a key frame, unless this one is one.
            if (lostOne && !done.key) return Event.Lost(done.frame)
            return Event.Complete(AssembledFrame(done.frame, done.key, done.parameterSets, done.captureMicros, done.data.toByteArray()))
        }
        return if (lostOne) Event.Lost(header.frame) else Event.Pending
    }

    fun reset() {
        partial = null
    }

    private fun giveUp(frame: Long): Event {
        partial = null
        newestFrame = maxOf(newestFrame, frame)
        return Event.Lost(frame)
    }
}

/** H.264 Annex B parameter sets: the SPS and PPS at the start of a key frame, each with its start code. */
object H264ParameterSets {
    data class Sets(val sps: ByteArray, val pps: ByteArray) {
        override fun equals(other: Any?): Boolean = other is Sets && sps.contentEquals(other.sps) && pps.contentEquals(other.pps)
        override fun hashCode(): Int = 31 * sps.contentHashCode() + pps.contentHashCode()
    }

    /** The first SPS (type 7) and PPS (type 8) NAL units, each with a 4-byte start code; null when either is missing. */
    fun find(accessUnit: ByteArray): Sets? {
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        for ((start, end) in units(accessUnit)) {
            if (start >= end) continue
            val unit = byteArrayOf(0, 0, 0, 1) + accessUnit.copyOfRange(start, end)
            when (accessUnit[start].toInt() and 0x1F) {
                7 -> if (sps == null) sps = unit
                8 -> if (pps == null) pps = unit
            }
            if (sps != null && pps != null) break
        }
        return if (sps != null && pps != null) Sets(sps, pps) else null
    }

    /** NAL unit bodies as [start, end) ranges between start codes, trailing zero bytes trimmed. */
    fun units(data: ByteArray): List<Pair<Int, Int>> {
        val result = mutableListOf<Pair<Int, Int>>()
        var bodyStart = -1
        var i = 0
        while (i + 2 < data.size) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte()) {
                if (bodyStart >= 0) result += bodyStart to trimmed(data, bodyStart, i)
                i += 3
                bodyStart = i
            } else {
                i++
            }
        }
        if (bodyStart in 0 until data.size) result += bodyStart to trimmed(data, bodyStart, data.size)
        return result
    }

    private fun trimmed(data: ByteArray, start: Int, end: Int): Int {
        var stop = end
        while (stop > start && data[stop - 1] == 0.toByte()) stop--
        return stop
    }
}
