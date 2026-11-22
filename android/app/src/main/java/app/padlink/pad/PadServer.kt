package app.padlink.pad

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/** Message types — see PROTOCOL.md */
object Msg {
    const val HELLO = 0x01
    const val VIDEO_CONFIG = 0x02
    const val VIDEO_FRAME = 0x03
    const val PING = 0x04
    const val BYE = 0x05
    const val INK = 0x06
    const val INK_STYLE = 0x07

    const val HELLO_REPLY = 0x81
    const val PEN = 0x82
    const val PONG = 0x83
    const val FRAME_ACK = 0x84
    const val COMMAND = 0x85
    const val SCROLL = 0x86
    const val KEYFRAME_REQ = 0x87
    const val PAD_BYE = 0x88
}

/**
 * Talks to the Mac — over Wi‑Fi (TCP server, advertised via NSD/Bonjour as `_padlink._tcp`) or over the
 * USB cable (Android accessory streams, see [UsbLink]). Same framed protocol on both.
 * One Mac at a time; a new connection replaces the old one.
 */
class PadServer(private val context: Context, private val serviceName: String) {

    interface Listener {
        fun onHello(macId: String, macName: String, token: String?, udpPort: Int, udpKey: Long)
        fun onVideoConfig(width: Int, height: Int)
        fun onVideoFrame(data: ByteArray, offset: Int, length: Int, key: Boolean, frameId: Long, inkSeq: Long)
        /** The Mac's screen already shows every pen sample up to [seq]. */
        fun onInk(seq: Long)
        /** What the stroke looks like on the Mac (colour, width as fraction of the picture width). */
        fun onInkStyle(color: Int, width: Float, visible: Boolean)
        fun onDisconnected(reason: String?)
    }

    var listener: Listener? = null

    /** One live link: a TCP socket or the USB accessory. */
    private class Link(
        val input: InputStream, val output: OutputStream, val usb: Boolean,
        val remote: java.net.InetAddress? = null, val close: () -> Unit,
    )

    private var server: ServerSocket? = null
    @Volatile private var link: Link? = null
    private var out: DataOutputStream? = null
    private val sendExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "pad-send").apply { priority = Thread.MAX_PRIORITY } }
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    @Volatile private var running = false

    val isConnected get() = link != null
    /** True while the current Mac is on the USB cable. */
    val isUsb get() = link?.usb == true
    /** A Mac is connected over Wi‑Fi right now. */
    val hasWifiLink get() = link?.let { !it.usb } == true
    /** The Mac's address on Wi‑Fi (for pen datagrams). */
    val remoteAddress get() = link?.remote

    fun start() {
        if (running) return
        running = true
        Thread({ acceptLoop() }, "pad-accept").start()
    }

    fun stop() {
        running = false
        unregister()
        link?.takeIf { !it.usb }?.let { runCatching { it.close() } }
        runCatching { server?.close() }
    }

    private fun acceptLoop() {
        val ss = try {
            ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(DEFAULT_PORT)) }
        } catch (e: Exception) {
            ServerSocket(0)
        }
        server = ss
        register(ss.localPort)
        while (running) {
            val s = try { ss.accept() } catch (e: Exception) { break }
            s.tcpNoDelay = true
            s.receiveBufferSize = 2 * 1024 * 1024
            s.trafficClass = 0xB8 // DSCP EF – ask the Wi‑Fi to treat us as realtime
            attach(Link(BufferedInputStream(s.getInputStream(), 256 * 1024), s.getOutputStream(), usb = false, remote = s.inetAddress) { s.close() })
        }
    }

    /** USB cable: the accessory's streams. [close] must release the accessory file descriptor. */
    fun attachUsb(input: InputStream, output: OutputStream, close: () -> Unit) {
        attach(Link(input, output, usb = true, close = close))
    }

    private fun attach(l: Link) {
        link?.let { old -> runCatching { old.close() } }
        link = l
        out = DataOutputStream(BufferedOutputStream(l.output, 16 * 1024))
        Thread({ readLoop(l) }, "pad-read").apply { priority = Thread.MAX_PRIORITY }.start()
    }

    private fun readLoop(s: Link) {
        var reason: String? = null
        try {
            val input = DataInputStream(s.input)
            var buf = ByteArray(512 * 1024)
            while (true) {
                val type = input.readUnsignedByte()
                val len = input.readInt()
                if (len < 0 || len > 32 * 1024 * 1024) throw IllegalStateException("bad length $len")
                if (len > buf.size) buf = ByteArray(len + len / 2)
                input.readFully(buf, 0, len)
                when (type) {
                    Msg.HELLO -> {
                        val json = org.json.JSONObject(String(buf, 0, len, Charsets.UTF_8))
                        listener?.onHello(
                            json.optString("macId"),
                            json.optString("macName", "Mac"),
                            if (json.isNull("token")) null else json.optString("token"),
                            json.optInt("udpPort", 0),
                            json.optLong("udpKey", 0),
                        )
                    }
                    Msg.VIDEO_CONFIG -> {
                        val bb = ByteBuffer.wrap(buf, 0, len)
                        listener?.onVideoConfig(bb.int, bb.int)
                    }
                    Msg.VIDEO_FRAME -> {
                        val flags = buf[0].toInt()
                        val key = (flags and 1) == 1
                        val id = ByteBuffer.wrap(buf, 1, 8).long
                        if ((flags and 2) != 0) {
                            val ink = ByteBuffer.wrap(buf, 9, 4).int.toLong() and 0xFFFFFFFFL
                            listener?.onVideoFrame(buf, 13, len - 13, key, id, ink)
                        } else {
                            listener?.onVideoFrame(buf, 9, len - 9, key, id, 0)
                        }
                    }
                    Msg.INK -> listener?.onInk(ByteBuffer.wrap(buf, 0, 4).int.toLong() and 0xFFFFFFFFL)
                    Msg.INK_STYLE -> if (len >= 8) {
                        val bb = ByteBuffer.wrap(buf, 0, len)
                        val r = bb.get().toInt() and 0xFF; val g = bb.get().toInt() and 0xFF; val b = bb.get().toInt() and 0xFF
                        val w = bb.float
                        val visible = bb.get().toInt() == 1
                        listener?.onInkStyle(android.graphics.Color.rgb(r, g, b), w, visible)
                    }
                    Msg.PING -> send(Msg.PONG, buf.copyOf(len))
                    Msg.BYE -> { reason = null; break }
                }
            }
        } catch (e: Exception) {
            Log.i(TAG, "connection ended: $e")
            reason = if (running || s.usb) "Verbindung zum Mac unterbrochen" else null
        }
        runCatching { s.close() }
        if (link === s) {
            link = null
            out = null
            listener?.onDisconnected(reason)
        }
    }

    fun send(type: Int, payload: ByteArray = ByteArray(0)) {
        sendExecutor.execute {
            val o = out ?: return@execute
            try {
                o.writeByte(type)
                o.writeInt(payload.size)
                o.write(payload)
                o.flush()
            } catch (e: Exception) {
                Log.i(TAG, "send failed: $e")
            }
        }
    }

    fun disconnect() {
        send(Msg.PAD_BYE)
        // Wi‑Fi: half-close so the Mac sees the end. USB: the Mac answers PAD_BYE with BYE, which ends our read.
        sendExecutor.execute { (link?.takeIf { !it.usb })?.let { runCatching { it.output.close() } } }
    }

    // --- Bonjour / NSD ---

    private fun register(port: Int) {
        val info = NsdServiceInfo().apply {
            serviceName = this@PadServer.serviceName
            serviceType = "_padlink._tcp"
            setPort(port)
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) { Log.i(TAG, "registered ${i.serviceName}:$port") }
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) { Log.w(TAG, "nsd failed $code") }
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) {}
        }
        nsd = context.getSystemService(NsdManager::class.java)
        registration = l
        nsd?.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    private fun unregister() {
        registration?.let { runCatching { nsd?.unregisterService(it) } }
        registration = null
    }

    companion object {
        const val DEFAULT_PORT = 47800
        private const val TAG = "PadServer"
    }
}
