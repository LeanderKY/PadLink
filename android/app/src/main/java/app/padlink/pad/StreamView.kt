package app.padlink.pad

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * Shows the Mac picture (letterboxed) and turns the pen into tablet events.
 * - Pen: drawn on the Mac with pressure + tilt, hover moves the cursor.
 * - One finger: ignored (palm rejection).
 * - Two fingers: move the canvas; pinch: zoom.
 * A local cursor ring follows the pen instantly so it never feels behind.
 */
@SuppressLint("ViewConstructor")
class StreamView(context: Context, private val send: (Int, ByteArray) -> Unit) : FrameLayout(context) {

    val surfaceView = SurfaceView(context)
    private val ink = InkView(context)
    private val cursor = CursorView(context)

    /** Set while on Wi‑Fi: pen samples also go out as UDP datagrams. */
    @Volatile var udp: PenUdp? = null
    private var seq = 0L          // running pen-sample number (UI thread)
    private var strokeStarted = false
    private var videoW = 16
    private var videoH = 10
    private val videoRect = RectF()

    private var penDown = false
    private var hovering = false

    // two-finger gesture state
    private var gestureActive = false
    private var lastCx = 0f
    private var lastCy = 0f
    private var lastSpan = 0f

    init {
        setBackgroundColor(Color.BLACK)
        addView(surfaceView)
        addView(ink, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(cursor, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        isFocusable = true
        isFocusableInTouchMode = true
    }

    fun setVideoSize(w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        videoW = w; videoH = h
        post { requestLayout() }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val w = (r - l).toFloat()
        val h = (b - t).toFloat()
        val scale = minOf(w / videoW, h / videoH)
        val vw = videoW * scale
        val vh = videoH * scale
        val x = (w - vw) / 2
        val y = (h - vh) / 2
        videoRect.set(x, y, x + vw, y + vh)
        surfaceView.layout(x.toInt(), y.toInt(), (x + vw).toInt(), (y + vh).toInt())
        ink.layout(0, 0, (r - l), (b - t))
        ink.videoWidthPx = vw
        cursor.layout(0, 0, (r - l), (b - t))
    }

    fun addHolderCallback(cb: SurfaceHolder.Callback) = surfaceView.holder.addCallback(cb)

    // Local ink (see InkView) — called from the network/decoder threads.
    fun confirmInk(seq: Long) = ink.confirm(seq)
    fun setInkStyle(color: Int, width: Float, visible: Boolean) = ink.setStyle(color, width, visible)
    fun resetInk() { ink.clear() }

    // ---------- Pen ----------

    private fun isPen(ev: MotionEvent, i: Int = 0): Boolean {
        val t = ev.getToolType(i)
        return t == MotionEvent.TOOL_TYPE_STYLUS || t == MotionEvent.TOOL_TYPE_ERASER
    }

    override fun onGenericMotionEvent(ev: MotionEvent): Boolean {
        if (!isPen(ev)) return super.onGenericMotionEvent(ev)
        when (ev.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER -> { hovering = true; sendPen(ev, ACTION_HOVER_ENTER, -1) }
            MotionEvent.ACTION_HOVER_MOVE -> {
                if (!hovering) { hovering = true; sendPen(ev, ACTION_HOVER_ENTER, -1) }
                for (h in 0 until ev.historySize) sendPen(ev, ACTION_HOVER_MOVE, h)
                sendPen(ev, ACTION_HOVER_MOVE, -1)
            }
            MotionEvent.ACTION_HOVER_EXIT -> {
                hovering = false
                // Android sends HOVER_EXIT right before a touch-down too; only leave proximity if the pen really left.
                postDelayed({ if (!hovering && !penDown) { sendPen(ev, ACTION_HOVER_EXIT, -1); cursor.hide() } }, 120)
            }
        }
        return true
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(ev: MotionEvent): Boolean {
        if (isPen(ev)) {
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    requestUnbufferedDispatch(ev) // deliver every pen sample immediately, not once per frame
                    penDown = true
                    hovering = true
                    strokeStarted = true
                    sendPen(ev, ACTION_DOWN, -1)
                }
                MotionEvent.ACTION_MOVE -> {
                    for (h in 0 until ev.historySize) sendPen(ev, ACTION_MOVE, h)
                    sendPen(ev, ACTION_MOVE, -1)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    penDown = false
                    sendPen(ev, ACTION_UP, -1)
                }
            }
            return true
        }
        handleFingers(ev)
        return true
    }

    private fun sendPen(ev: MotionEvent, action: Int, h: Int) {
        val x = if (h < 0) ev.x else ev.getHistoricalX(h)
        val y = if (h < 0) ev.y else ev.getHistoricalY(h)
        val pressure = if (action == ACTION_UP || action <= 0 || action >= ACTION_HOVER_EXIT) 0f
                       else (if (h < 0) ev.pressure else ev.getHistoricalPressure(h)).coerceIn(0f, 1f)
        val tilt = if (h < 0) ev.getAxisValue(MotionEvent.AXIS_TILT) else ev.getHistoricalAxisValue(MotionEvent.AXIS_TILT, h)
        val orient = if (h < 0) ev.getAxisValue(MotionEvent.AXIS_ORIENTATION) else ev.getHistoricalAxisValue(MotionEvent.AXIS_ORIENTATION, h)
        val tiltX = (sin(tilt) * sin(orient)).coerceIn(-1f, 1f)
        val tiltY = (-sin(tilt) * cos(orient)).coerceIn(-1f, 1f)
        val eraser = ev.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER
        val side = (ev.buttonState and (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_SECONDARY)) != 0

        val nx = ((x - videoRect.left) / videoRect.width()).coerceIn(0f, 1f)
        val ny = ((y - videoRect.top) / videoRect.height()).coerceIn(0f, 1f)

        seq++
        val bb = ByteBuffer.allocate(27).order(ByteOrder.BIG_ENDIAN)
        bb.put(action.toByte())
        bb.put(if (eraser) 1 else 0)
        bb.put(if (side) 1 else 0)
        bb.putFloat(nx); bb.putFloat(ny); bb.putFloat(pressure); bb.putFloat(tiltX); bb.putFloat(tiltY)
        bb.putInt(seq.toInt())
        val record = bb.array()
        udp?.send(record)          // fast path (may get lost — covered by the next datagram)
        send(Msg.PEN, record)      // reliable path; the Mac drops whichever copy comes second

        // Instant local ink for the drawing end of the pen (not for the eraser, not with the side button).
        if ((action == ACTION_DOWN || action == ACTION_MOVE) && !eraser && !side) {
            ink.add(x, y, seq, newStroke = strokeStarted)
            strokeStarted = false
        }

        if (h < 0) {
            if (action == ACTION_HOVER_EXIT) cursor.hide()
            else cursor.show(x, y, if (action == ACTION_DOWN || action == ACTION_MOVE) pressure else -1f, eraser)
        }
    }

    // ---------- Fingers ----------

    private fun handleFingers(ev: MotionEvent) {
        if (penDown) return
        when (ev.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN -> if (ev.pointerCount == 2) {
                gestureActive = true
                lastCx = (ev.getX(0) + ev.getX(1)) / 2
                lastCy = (ev.getY(0) + ev.getY(1)) / 2
                lastSpan = hypot(ev.getX(0) - ev.getX(1), ev.getY(0) - ev.getY(1))
            }
            MotionEvent.ACTION_MOVE -> if (gestureActive && ev.pointerCount >= 2) {
                val cx = (ev.getX(0) + ev.getX(1)) / 2
                val cy = (ev.getY(0) + ev.getY(1)) / 2
                val span = hypot(ev.getX(0) - ev.getX(1), ev.getY(0) - ev.getY(1))
                val dSpan = span - lastSpan
                if (kotlin.math.abs(dSpan) > 6f) {
                    sendScroll(0f, dSpan * 0.6f, zoom = true)
                    lastSpan = span
                } else {
                    val dx = cx - lastCx
                    val dy = cy - lastCy
                    if (kotlin.math.abs(dx) + kotlin.math.abs(dy) >= 1f) sendScroll(dx, dy, zoom = false)
                }
                lastCx = cx; lastCy = cy
            }
            MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> gestureActive = false
        }
    }

    private fun sendScroll(dx: Float, dy: Float, zoom: Boolean) {
        val bb = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
        bb.putFloat(dx); bb.putFloat(dy); bb.put(if (zoom) 1 else 0)
        send(Msg.SCROLL, bb.array())
    }

    /** Instant local pen feedback. */
    private class CursorView(context: Context) : View(context) {
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 3f; color = Color.argb(200, 255, 255, 255)
        }
        private val ringDark = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 5f; color = Color.argb(120, 0, 0, 0)
        }
        private var x = 0f
        private var y = 0f
        private var visible = false
        private var r = 8f

        fun show(x: Float, y: Float, pressure: Float, eraser: Boolean) {
            this.x = x; this.y = y; visible = true
            r = if (pressure >= 0f) 4f + pressure * 6f else if (eraser) 12f else 8f
            postInvalidateOnAnimation()
        }
        fun hide() { visible = false; postInvalidateOnAnimation() }

        override fun onDraw(c: Canvas) {
            if (!visible) return
            c.drawCircle(x, y, r, ringDark)
            c.drawCircle(x, y, r, ring)
        }
    }

    companion object {
        const val ACTION_HOVER_MOVE = 0
        const val ACTION_DOWN = 1
        const val ACTION_MOVE = 2
        const val ACTION_UP = 3
        const val ACTION_HOVER_EXIT = 4
        const val ACTION_HOVER_ENTER = 5
    }
}
