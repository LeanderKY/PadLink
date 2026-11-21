package app.padlink.pad

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Pen samples over UDP (Wi‑Fi only). TCP has to stop and wait when a packet is lost — that's the typical
 * 50–200 ms hiccup in the middle of a stroke. Here every datagram also carries the previous 3 samples,
 * so a lost packet is simply covered by the next one. The same samples still go over TCP too; the Mac
 * keeps whichever copy arrives first (by sample number).
 */
class PenUdp(private val host: InetAddress, private val port: Int, private val key: Int) {
    private val socket = DatagramSocket().apply { trafficClass = 0xB8 } // DSCP EF: realtime
    private val exec = Executors.newSingleThreadExecutor { r -> Thread(r, "pen-udp").apply { priority = Thread.MAX_PRIORITY } }
    private val recent = ArrayDeque<ByteArray>()
    @Volatile private var closed = false

    fun send(record: ByteArray) {
        if (closed) return
        exec.execute {
            recent.addLast(record)
            while (recent.size > REDUNDANCY) recent.removeFirst()
            val bb = ByteBuffer.allocate(5 + recent.sumOf { it.size })
            bb.putInt(key)
            bb.put(recent.size.toByte())
            for (r in recent) bb.put(r)
            runCatching { socket.send(DatagramPacket(bb.array(), bb.position(), host, port)) }
        }
    }

    fun close() {
        closed = true
        exec.execute { runCatching { socket.close() } }
        exec.shutdown()
    }

    companion object { private const val REDUNDANCY = 4 }
}
