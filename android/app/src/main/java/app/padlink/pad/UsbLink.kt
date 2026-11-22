package app.padlink.pad

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream

/**
 * The USB-C cable to the Mac, via Android Open Accessory. The Mac switches the pad into accessory mode;
 * Android then starts PadLink (first time it asks once — tick "Immer"). No developer mode needed.
 */
class UsbLink(private val activity: Activity, private val server: PadServer) {

    private val usb = activity.getSystemService(UsbManager::class.java)
    private var pfd: ParcelFileDescriptor? = null
    private var receiverRegistered = false
    /** Asked Android for permission already (don't pop the dialog again on every check). */
    private var permissionAsked = false
    private val poll = object : Runnable {
        override fun run() {
            if (!server.hasWifiLink) open(null) // never cut a running Wi‑Fi session
            activity.window.decorView.postDelayed(this, 1500)
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.action) {
                ACTION_PERMISSION -> {
                    permissionAsked = false
                    if (i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) open(accessoryFrom(i))
                }
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> { permissionAsked = false; close() }
            }
        }
    }

    val isOpen get() = pfd != null

    fun start() {
        if (!receiverRegistered) {
            val f = IntentFilter().apply {
                addAction(ACTION_PERMISSION)
                addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
            }
            activity.registerReceiver(receiver, f, Context.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }
        open(null)
        // The "cable plugged in" message from Android doesn't always reach us (app already open, chooser
        // dialog, screen was locked …). Look for the Mac's accessory ourselves every 1.5 s — cheap.
        activity.window.decorView.removeCallbacks(poll)
        activity.window.decorView.postDelayed(poll, 1500)
    }

    fun stop() {
        activity.window.decorView.removeCallbacks(poll)
        if (receiverRegistered) { runCatching { activity.unregisterReceiver(receiver) }; receiverRegistered = false }
    }

    /** Called with the intent that launched us (USB_ACCESSORY_ATTACHED), or null to look for one. */
    fun open(fromIntent: UsbAccessory?) {
        if (pfd != null) return
        val acc = fromIntent ?: usb.accessoryList?.firstOrNull { it.manufacturer == "PadLink" } ?: return
        if (!usb.hasPermission(acc)) {
            if (permissionAsked) return
            permissionAsked = true
            val pi = PendingIntent.getBroadcast(
                activity, 0, Intent(ACTION_PERMISSION).setPackage(activity.packageName),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            usb.requestPermission(acc, pi)
            return
        }
        val fd = try { usb.openAccessory(acc) } catch (e: Exception) { Log.w(TAG, "open failed: $e"); null } ?: return
        pfd = fd
        Log.i(TAG, "accessory open")
        val input = AccessoryInputStream(FileInputStream(fd.fileDescriptor))
        val output = AccessoryOutputStream(FileOutputStream(fd.fileDescriptor))
        server.attachUsb(input, output) { closeFd(fd) }
    }

    /** After a session ends the descriptor is closed — reopen so the next button press works right away. */
    fun reopenSoon() {
        activity.window.decorView.postDelayed({ if (!activity.isFinishing) open(null) }, 400)
    }

    fun close() {
        pfd?.let { closeFd(it) }
    }

    private fun closeFd(fd: ParcelFileDescriptor) {
        runCatching { fd.close() }
        if (pfd === fd) pfd = null
    }

    @Suppress("DEPRECATION")
    private fun accessoryFrom(i: Intent): UsbAccessory? = i.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)

    companion object {
        private const val TAG = "UsbLink"
        private const val ACTION_PERMISSION = "app.padlink.pad.USB_PERMISSION"
        private const val TRANSFER = 16 * 1024

        @Suppress("DEPRECATION")
        fun accessoryFromIntent(i: Intent?): UsbAccessory? =
            if (i?.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) i.getParcelableExtra(UsbManager.EXTRA_ACCESSORY) else null
    }

    /**
     * The accessory driver hands out data in whole USB transfers; a read with a buffer smaller than the
     * transfer loses data. So we always read a full 16 KB transfer and serve callers from it.
     */
    private class AccessoryInputStream(private val raw: FileInputStream) : InputStream() {
        private val buf = ByteArray(TRANSFER)
        private var pos = 0
        private var end = 0

        private fun fill(): Boolean {
            while (pos >= end) {
                val n = raw.read(buf, 0, TRANSFER)
                if (n < 0) return false
                pos = 0; end = n
            }
            return true
        }

        override fun read(): Int = if (!fill()) -1 else buf[pos++].toInt() and 0xFF

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            if (!fill()) return -1
            val n = minOf(len, end - pos)
            System.arraycopy(buf, pos, b, off, n)
            pos += n
            return n
        }

        override fun available(): Int = end - pos
        override fun close() = raw.close()
    }

    /**
     * Each write() becomes one USB transfer. A transfer that is an exact multiple of the 512-byte packet
     * size gives the Mac no "short packet" to tell it the transfer ended — split such writes in two.
     */
    private class AccessoryOutputStream(private val raw: FileOutputStream) : OutputStream() {
        override fun write(b: Int) = raw.write(byteArrayOf(b.toByte()))
        override fun write(b: ByteArray, off: Int, len: Int) {
            var o = off
            var left = len
            while (left > 0) {
                var n = minOf(left, TRANSFER)
                if (n % 512 == 0) n -= 1
                raw.write(b, o, n)
                o += n; left -= n
            }
        }
        override fun flush() = raw.flush()
        override fun close() = raw.close()
    }
}
