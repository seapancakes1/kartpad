package dev.kartpad.android.screens

import android.graphics.RectF
import kotlin.math.max
import kotlin.math.min

// Moving the focus by direction, as TV menus choose it (the Mac's KPUINearest). Pure geometry on
// design rects (y down), so the host tests can run it without a device.
object KPNavigation {
    private class Span(val lo: Float, val hi: Float)
    private class Option(val index: Int, val beam: Boolean, val ahead: Boolean, val gap: Float, val far: Float, val score: Float)

    /**
     * The rect the pressed direction leads to from `from` (dy positive downwards), or -1. Only what lies
     * that way counts (clearly: a neighbour a few points out of line isn't "above"), and left and right
     * stay on their row. One in line (overlapping sideways) beats one off to the side, unless, going up or
     * down, the one to the side lies wholly nearer; otherwise the nearest wins, distance ahead weighing
     * more than sideways offset. `across` is the sideways position measured from (the column a run of
     * moves up or down started in), NaN for the middle of `from`.
     */
    fun nearest(candidates: List<RectF>, from: Int, dx: Int, dy: Int, across: Float = Float.NaN): Int {
        fun along(r: RectF) = when {
            dx > 0 -> Span(r.left, r.right)
            dx < 0 -> Span(-r.right, -r.left)
            dy > 0 -> Span(r.top, r.bottom)
            else -> Span(-r.bottom, -r.top)
        }
        fun aside(r: RectF) = if (dx != 0) Span(r.top, r.bottom) else Span(r.left, r.right)
        val here = candidates[from]
        val a = along(here)
        val p = aside(here)
        val middle = if (across.isNaN()) (p.lo + p.hi) / 2 else across
        fun beamBeats(x: Option, y: Option): Boolean {
            if (y.beam || !x.beam) return false
            if (!y.ahead || dx != 0) return true
            return x.gap < y.far
        }
        var best: Option? = null
        for ((index, there) in candidates.withIndex()) {
            if (index == from) continue
            val b = along(there)
            val q = aside(there)
            val slack = .2f * min(a.hi - a.lo, b.hi - b.lo)
            if (!((a.lo + slack < b.lo || a.hi <= b.lo) && a.hi + slack < b.hi)) continue
            val beam = min(p.hi, q.hi) - max(p.lo, q.lo) > 0
            if (dx != 0 && !beam) continue
            val gap = max(0f, b.lo - a.hi)
            val offset = (q.lo + q.hi) / 2 - middle
            val option = Option(index, beam, b.lo >= a.hi, gap, max(1f, b.hi - a.hi), 13 * gap * gap + offset * offset)
            val current = best
            if (current == null || beamBeats(option, current) || (!beamBeats(current, option) && option.score < current.score)) best = option
        }
        return best?.index ?: -1
    }
}
