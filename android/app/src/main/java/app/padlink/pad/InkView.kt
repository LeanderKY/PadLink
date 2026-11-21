package app.padlink.pad

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.os.SystemClock
import android.view.View

/**
 * "Local ink": the stroke appears under the pen tip at once, drawn by the pad itself from the exact pen
 * samples — nothing predicted, nothing smoothed, so it can't draw a line the pen didn't make.
 *
 * Every sample has a number. The Mac tells us, with each picture, up to which number the real screen
 * already shows the stroke; that part of the local ink is removed right then. What's left is only the short
 * piece the Mac picture hasn't caught up with yet. Colour and width come from measuring the real stroke on
 * the Mac, so the hand-over is invisible. If the Mac sees nothing being drawn (hand tool, selecting …) the
 * ink is hidden.
 */
class InkView(context: Context) : View(context) {

    private class Pt(val x: Float, val y: Float, val seq: Long, val t: Long, val stroke: Int)

    private val pts = ArrayList<Pt>()       // guarded by `this`
    private var confirmed = 0L
    private var styleKnown = false
    private var visibleOnMac = false
    private var color = Color.DKGRAY
    private var widthNorm = 0.002f
    private var strokeId = 0

    /** Width of the picture on the pad in px (ink width is relative to it). */
    var videoWidthPx = 1f

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val path = Path()

    init { setWillNotDraw(false) }

    /** UI thread, for every pen sample while the tip touches. */
    fun add(x: Float, y: Float, seq: Long, newStroke: Boolean) {
        synchronized(this) {
            if (newStroke) strokeId++
            if (seq > confirmed) pts.add(Pt(x, y, seq, SystemClock.uptimeMillis(), strokeId))
        }
        invalidate()
    }

    /** Any thread: the Mac picture now shows everything up to [seq]. */
    fun confirm(seq: Long) {
        synchronized(this) {
            if (seq <= confirmed) return
            confirmed = seq
            // Remove the confirmed part, but keep its last point as the start of what's left,
            // so the remaining ink joins the real stroke without a gap.
            var last = -1
            for (i in pts.indices) if (pts[i].seq <= seq) last = i else break
            if (last >= 0) {
                val keepAnchor = last + 1 < pts.size && pts[last + 1].stroke == pts[last].stroke
                val removeCount = if (keepAnchor) last else last + 1
                if (removeCount > 0) pts.subList(0, removeCount).clear()
            }
        }
        postInvalidateOnAnimation()
    }

    fun setStyle(c: Int, width: Float, visible: Boolean) {
        synchronized(this) {
            styleKnown = true
            visibleOnMac = visible
            if (visible) { color = c; if (width > 0f) widthNorm = width }
        }
        postInvalidateOnAnimation()
    }

    fun clear() {
        synchronized(this) { pts.clear(); confirmed = 0; strokeId = 0 }
        postInvalidateOnAnimation()
    }

    override fun onDraw(canvas: Canvas) {
        val now = SystemClock.uptimeMillis()
        var more = false
        synchronized(this) {
            // Safety net: never keep ink longer than this, whatever happens on the network.
            pts.removeAll { now - it.t > MAX_AGE_MS }
            if (!styleKnown || !visibleOnMac || pts.isEmpty()) return
            paint.color = color
            paint.strokeWidth = maxOf(1.5f, widthNorm * videoWidthPx)
            path.reset()
            var stroke = -1
            for (p in pts) {
                if (p.stroke != stroke) { path.moveTo(p.x, p.y); path.lineTo(p.x + 0.01f, p.y); stroke = p.stroke }
                else path.lineTo(p.x, p.y)
            }
            more = true
        }
        canvas.drawPath(path, paint)
        if (more) postInvalidateDelayed(50) // let the safety net run even if nothing else happens
    }

    companion object {
        private const val MAX_AGE_MS = 700L
    }
}
