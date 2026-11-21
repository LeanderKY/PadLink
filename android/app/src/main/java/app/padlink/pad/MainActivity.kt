package app.padlink.pad

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.nio.ByteBuffer
import java.util.UUID

class MainActivity : Activity(), PadServer.Listener {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var server: PadServer
    private lateinit var usbLink: UsbLink
    private var started = false
    private lateinit var decoder: VideoDecoder
    private lateinit var root: FrameLayout
    private lateinit var idleView: View
    private lateinit var idleTitle: TextView
    private lateinit var idleSubtitle: TextView
    private lateinit var streamLayer: LinearLayout
    private lateinit var streamView: StreamView
    private lateinit var toolbar: LinearLayout
    private var approvalView: View? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var pendingMacId: String? = null
    /** frameId → the last pen sample that picture already shows (for removing local ink). */
    private val frameInk = java.util.TreeMap<Long, Long>()

    private val prefs by lazy { getSharedPreferences("padlink", Context.MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes = window.attributes.apply {
            // Ask for the panel's highest refresh rate (120 Hz) — halves display latency.
            preferredDisplayModeId = display?.supportedModes?.maxByOrNull { it.refreshRate }?.modeId ?: 0
        }

        decoder = VideoDecoder(
            onFrameShown = { id -> ack(id) },
            onNeedKeyframe = { server.send(Msg.KEYFRAME_REQ) },
        )
        server = PadServer(this, padName())
        server.listener = this
        usbLink = UsbLink(this, server)

        buildUi()
        showIdle(null)
    }

    override fun onStart() {
        super.onStart()
        hideSystemBars()
        started = true
        server.start()
        usbLink.start()
        usbLink.open(UsbLink.accessoryFromIntent(intent))
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Cable plugged in / Mac switched the pad to accessory mode while we were open.
        usbLink.open(UsbLink.accessoryFromIntent(intent))
    }

    override fun onStop() {
        super.onStop()
        // Leaving the app ends the session so the Mac doesn't keep streaming into nothing.
        started = false
        server.disconnect()
        server.stop()
        usbLink.stop()
        releaseWifiLock()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun hideSystemBars() {
        window.insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun padName(): String {
        val n = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
        return if (n.isNullOrBlank()) "Zeichen-Pad" else n
    }

    // ---------------- Server callbacks (network thread) ----------------

    override fun onHello(macId: String, macName: String, token: String?, udpPort: Int, udpKey: Long) {
        streamView.udp?.close()
        streamView.udp = null
        val mac = server.remoteAddress
        if (!server.isUsb && udpPort > 0 && mac != null) {
            streamView.udp = runCatching { PenUdp(mac, udpPort, udpKey.toInt()) }.getOrNull()
        }
        val known = tokens().optString(macId, "")
        if (server.isUsb) {
            // A cable is a physical "yes" — no need to ask.
            val t = known.ifEmpty { UUID.randomUUID().toString().also { prefs.edit().putString("tokens", tokens().put(macId, it).toString()).apply() } }
            accept(macId, t)
        } else if (token != null && known.isNotEmpty() && token == known) {
            accept(macId, known)
        } else {
            server.send(Msg.HELLO_REPLY, reply("pending", null))
            main.post { showApproval(macId, macName) }
        }
    }

    override fun onVideoConfig(width: Int, height: Int) {
        decoder.setSize(width, height)
        streamView.setVideoSize(width, height)
    }

    override fun onVideoFrame(data: ByteArray, offset: Int, length: Int, key: Boolean, frameId: Long, inkSeq: Long) {
        if (inkSeq > 0) synchronized(frameInk) { frameInk[frameId] = inkSeq }
        decoder.feed(data, offset, length, key, frameId)
    }

    override fun onInk(seq: Long) = streamView.confirmInk(seq)

    override fun onInkStyle(color: Int, width: Float, visible: Boolean) = streamView.setInkStyle(color, width, visible)

    override fun onDisconnected(reason: String?) {
        streamView.udp?.close()
        streamView.udp = null
        synchronized(frameInk) { frameInk.clear() }
        main.post {
            streamView.resetInk()
            releaseWifiLock()
            decoder.release()
            dismissApproval()
            showIdle(reason)
            if (started) usbLink.reopenSoon()
        }
    }

    /** Decoder thread: a picture is on screen now. */
    private fun ack(frameId: Long) {
        server.send(Msg.FRAME_ACK, ByteBuffer.allocate(8).putLong(frameId).array())
        val ink = synchronized(frameInk) {
            val v = frameInk[frameId]
            frameInk.headMap(frameId, true).clear()
            v
        }
        if (ink != null) streamView.confirmInk(ink)
    }

    // ---------------- Pairing ----------------

    private fun tokens(): JSONObject = JSONObject(prefs.getString("tokens", "{}") ?: "{}")

    private fun accept(macId: String, token: String) {
        server.send(Msg.HELLO_REPLY, reply("ok", token))
        main.post { showStreaming() }
    }

    private fun reply(status: String, token: String?): ByteArray {
        val m = resources.displayMetrics
        val bounds = windowManager.maximumWindowMetrics.bounds
        val w = maxOf(bounds.width(), bounds.height())
        val h = minOf(bounds.width(), bounds.height())
        return JSONObject().apply {
            put("status", status)
            if (token != null) put("token", token)
            put("padName", padName())
            put("width", w)
            put("height", h)
            put("density", m.density.toDouble())
        }.toString().toByteArray()
    }

    private fun showApproval(macId: String, macName: String) {
        dismissApproval()
        pendingMacId = macId
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(40), dp(36), dp(40), dp(32))
            background = rounded(Color.WHITE, dp(28).toFloat())
            elevation = dp(12).toFloat()
        }
        card.addView(text("„$macName“", 30f, bold = true, color = INK))
        card.addView(text("möchte dieses Pad als Bildschirm benutzen.", 20f, color = MUTED).apply {
            setPadding(0, dp(8), 0, dp(28))
        })
        val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        buttons.addView(pill("Nein", Color.parseColor("#E9EBEF"), INK) {
            server.send(Msg.HELLO_REPLY, reply("denied", null))
            server.disconnect()
            dismissApproval()
        }, LinearLayout.LayoutParams(dp(180), dp(72)).apply { marginEnd = dp(16) })
        buttons.addView(pill("Erlauben", ACCENT, Color.WHITE) {
            val token = UUID.randomUUID().toString()
            prefs.edit().putString("tokens", tokens().put(macId, token).toString()).apply()
            dismissApproval()
            accept(macId, token)
        }, LinearLayout.LayoutParams(dp(240), dp(72)))
        card.addView(buttons)

        val scrim = FrameLayout(this).apply {
            setBackgroundColor(Color.argb(90, 0, 0, 0))
            isClickable = true
            addView(card, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        }
        approvalView = scrim
        root.addView(scrim, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun dismissApproval() {
        approvalView?.let { root.removeView(it) }
        approvalView = null
        pendingMacId = null
    }

    // ---------------- Screens ----------------

    private fun showIdle(problem: String?) {
        streamLayer.visibility = View.GONE
        idleView.visibility = View.VISIBLE
        idleTitle.text = if (problem == null) "Bereit" else "Getrennt"
        idleSubtitle.text = problem?.let { "$it\n\nDrück am Mac nochmal auf den großen Knopf." }
            ?: "Drück am Mac auf den großen Knopf."
        window.decorView.setBackgroundColor(BG)
    }

    private fun showStreaming() {
        idleView.visibility = View.GONE
        streamLayer.visibility = View.VISIBLE
        window.decorView.setBackgroundColor(Color.BLACK)
        if (!server.isUsb) acquireWifiLock()
        streamView.requestFocus()
    }

    private fun acquireWifiLock() {
        if (wifiLock?.isHeld == true) return
        val wm = applicationContext.getSystemService(WifiManager::class.java)
        // Keeps the Wi‑Fi radio out of power-save: the biggest single latency win on tablets.
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "padlink").apply {
            setReferenceCounted(false); acquire()
        }
    }

    private fun releaseWifiLock() {
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    // ---------------- UI construction ----------------

    private fun buildUi() {
        root = FrameLayout(this)
        setContentView(root)

        // Idle screen
        val idle = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(BG)
        }
        val badge = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                colors = intArrayOf(Color.parseColor("#4A86FF"), Color.parseColor("#2A5EE0"))
                orientation = GradientDrawable.Orientation.TOP_BOTTOM
            }
            elevation = dp(10).toFloat()
            addView(TextView(context).apply {
                text = "✎"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 84f)
                gravity = Gravity.CENTER
            }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        idle.addView(badge, LinearLayout.LayoutParams(dp(200), dp(200)).apply { bottomMargin = dp(40) })
        idleTitle = text("Bereit", 44f, bold = true, color = INK)
        idle.addView(idleTitle)
        idleSubtitle = text("", 22f, color = MUTED).apply { setPadding(dp(40), dp(12), dp(40), 0) }
        idle.addView(idleSubtitle)
        idle.addView(text("Dieses Pad heißt „${padName()}“ · per USB-Kabel oder im gleichen WLAN wie der Mac", 15f, color = MUTED).apply {
            setPadding(0, dp(56), 0, 0)
            alpha = 0.7f
        })
        idleView = idle
        root.addView(idle, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        // Streaming screen: toolbar | picture
        streamLayer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(Color.BLACK)
            visibility = View.GONE
        }
        toolbar = buildToolbar()
        streamLayer.addView(toolbar, LinearLayout.LayoutParams(dp(92), ViewGroup.LayoutParams.MATCH_PARENT))
        streamView = StreamView(this) { type, payload -> server.send(type, payload) }
        streamView.addHolderCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(h: SurfaceHolder) { decoder.setSurface(h.surface) }
            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hh: Int) {}
            override fun surfaceDestroyed(h: SurfaceHolder) { decoder.setSurface(null) }
        })
        streamLayer.addView(streamView, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        root.addView(streamLayer, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun buildToolbar(): LinearLayout {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(8), dp(14), dp(8), dp(14))
            setBackgroundColor(Color.parseColor("#1C1D21"))
        }
        fun add(symbol: String, label: String, cmd: Int) =
            bar.addView(toolButton(symbol, label) { sendCommand(cmd) }, toolParams())

        add("↶", "Zurück", 1)
        add("↷", "Vor", 2)
        spacer(bar)
        add("✎", "Pinsel", 3)
        add("⌫", "Radierer", 4)
        bar.addView(holdButton("✋", "Hand", down = 8, up = 9), toolParams())
        spacer(bar)
        add("＋", "Zoom", 5)
        add("－", "Zoom", 6)
        add("▢", "Ganz", 7)
        spacer(bar)
        add("●", "Größer", 11)
        add("•", "Kleiner", 10)

        bar.addView(View(this), LinearLayout.LayoutParams(1, 0, 1f))
        bar.addView(toolButton("✕", "Trennen", danger = true) { server.disconnect() }, toolParams())
        return bar
    }

    private fun spacer(bar: LinearLayout) =
        bar.addView(View(this).apply { setBackgroundColor(Color.parseColor("#2E3036")) },
            LinearLayout.LayoutParams(dp(40), dp(1)).apply { topMargin = dp(6); bottomMargin = dp(6) })

    private fun toolParams() = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)).apply { bottomMargin = dp(4) }

    private fun sendCommand(c: Int) = server.send(Msg.COMMAND, byteArrayOf(c.toByte()))

    private fun toolButton(symbol: String, label: String, danger: Boolean = false, onTap: () -> Unit): View {
        val v = toolView(symbol, label, danger)
        v.setOnClickListener { onTap() }
        return v
    }

    /** Hand tool: hold to pan with the pen, like holding the space bar. */
    private fun holdButton(symbol: String, label: String, down: Int, up: Int): View {
        val v = toolView(symbol, label, false)
        v.setOnTouchListener { view, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { view.isPressed = true; sendCommand(down) }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { view.isPressed = false; sendCommand(up) }
            }
            true
        }
        return v
    }

    private fun toolView(symbol: String, label: String, danger: Boolean): View {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            isClickable = true
            background = android.graphics.drawable.StateListDrawable().apply {
                addState(intArrayOf(android.R.attr.state_pressed), rounded(Color.parseColor("#3A3D45"), dp(14).toFloat()))
                addState(intArrayOf(), rounded(Color.TRANSPARENT, dp(14).toFloat()))
            }
        }
        val fg = if (danger) Color.parseColor("#FF7A70") else Color.parseColor("#F2F3F5")
        col.addView(TextView(this).apply {
            text = symbol; setTextColor(fg); setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f); gravity = Gravity.CENTER
            includeFontPadding = false
        })
        col.addView(TextView(this).apply {
            text = label; setTextColor(Color.parseColor("#A4A7AF")); setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            gravity = Gravity.CENTER; setPadding(0, dp(3), 0, 0)
        })
        return col
    }

    private fun pill(label: String, bg: Int, fg: Int, onTap: () -> Unit) = TextView(this).apply {
        text = label
        setTextColor(fg)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        background = rounded(bg, dp(36).toFloat())
        isClickable = true
        setOnClickListener { onTap() }
    }

    private fun text(s: String, sp: Float, bold: Boolean = false, color: Int) = TextView(this).apply {
        text = s
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        gravity = Gravity.CENTER
        if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
    }

    private fun rounded(color: Int, radius: Float) = GradientDrawable().apply {
        setColor(color); cornerRadius = radius
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        private val BG = Color.parseColor("#F4F5F7")
        private val INK = Color.parseColor("#16181D")
        private val MUTED = Color.parseColor("#6B7078")
        private val ACCENT = Color.parseColor("#3D7AFA")
    }
}
