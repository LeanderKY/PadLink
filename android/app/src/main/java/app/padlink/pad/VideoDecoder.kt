package app.padlink.pad

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface

/**
 * Hardware H.264 decoder in low-latency mode, rendering straight to a Surface.
 * Every decoded frame is shown immediately (no pacing, no queue).
 */
class VideoDecoder(
    private val onFrameShown: (frameId: Long) -> Unit,
    private val onNeedKeyframe: () -> Unit,
) {
    private val lock = Object()
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var width = 0
    private var height = 0
    private var configured = false
    private var outputThread: Thread? = null
    @Volatile private var generation = 0

    fun setSurface(s: Surface?) = synchronized(lock) {
        surface = s
        release()
        if (s == null) return@synchronized
        onNeedKeyframe() // new surface → start fresh at the next keyframe
    }

    fun setSize(w: Int, h: Int) = synchronized(lock) {
        if (w == width && h == height) return@synchronized
        width = w; height = h
        release()
    }

    /** Called from the network thread. */
    fun feed(data: ByteArray, offset: Int, length: Int, key: Boolean, frameId: Long) = synchronized(lock) {
        val s = surface ?: return@synchronized
        if (!configured) {
            if (!key || width == 0) return@synchronized
            try { configure(s, data, offset, length) } catch (e: Exception) {
                Log.e(TAG, "configure failed", e); release(); onNeedKeyframe(); return@synchronized
            }
        }
        val c = codec ?: return@synchronized
        try {
            val idx = c.dequeueInputBuffer(30_000)
            if (idx < 0) { onNeedKeyframe(); return@synchronized } // decoder is backed up → resync
            val buf = c.getInputBuffer(idx)!!
            buf.clear()
            buf.put(data, offset, length)
            c.queueInputBuffer(idx, 0, length, frameId, if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
        } catch (e: Exception) {
            Log.e(TAG, "feed failed", e)
            release()
            onNeedKeyframe()
        }
    }

    private fun configure(s: Surface, data: ByteArray, offset: Int, length: Int) {
        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)              // realtime
            setInteger(MediaFormat.KEY_OPERATING_RATE, 120)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024)
            // Qualcomm (Snapdragon) vendor switches for zero frame-delay output
            setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
            setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
        }
        // SPS/PPS are prepended to every keyframe by the Mac; the decoder picks them up in-band.
        val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        c.configure(fmt, s, null, 0)
        c.start()
        codec = c
        configured = true
        val gen = ++generation
        outputThread = Thread({ drain(c, gen) }, "pad-decode-out").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    private fun drain(c: MediaCodec, gen: Int) {
        val info = MediaCodec.BufferInfo()
        while (gen == generation) {
            try {
                val idx = c.dequeueOutputBuffer(info, 20_000)
                if (idx >= 0) {
                    c.releaseOutputBuffer(idx, true)
                    onFrameShown(info.presentationTimeUs)
                }
            } catch (e: Exception) {
                if (gen == generation) Log.w(TAG, "drain: $e")
                return
            }
        }
    }

    fun release() = synchronized(lock) {
        generation++
        configured = false
        codec?.let { c ->
            runCatching { c.stop() }
            runCatching { c.release() }
        }
        codec = null
        outputThread = null
    }

    companion object { private const val TAG = "VideoDecoder" }
}
