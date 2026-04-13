package com.hengqutiandi.vncviewer

import android.graphics.Rect
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

object MonitorLayoutHelper {

    data class MonitorAspectOption(val label: String, val ratio: Float)

    fun getCommonMonitorAspectOptions(): List<MonitorAspectOption> {
        return listOf(
            MonitorAspectOption("21:9", 21f / 9f),
            MonitorAspectOption("16:9", 16f / 9f),
            MonitorAspectOption("16:10", 16f / 10f),
            MonitorAspectOption("3:2", 3f / 2f),
            MonitorAspectOption("5:4", 5f / 4f),
            MonitorAspectOption("4:3", 4f / 3f),
            MonitorAspectOption("10:16", 10f / 16f),
            MonitorAspectOption("9:16", 9f / 16f)
        )
    }

    fun roundMonitorDimension(value: Float): Int {
        val rounded = value.roundToInt()
        val commonDimensions = intArrayOf(
            720, 768, 800, 900, 1024, 1050, 1080, 1152, 1200, 1280, 1366, 1440,
            1600, 1680, 1920, 2160, 2400, 2560, 2880, 3440, 3840, 4320, 5120
        )
        for (dim in commonDimensions) {
            if (abs(rounded - dim) <= 32) {
                return dim
            }
        }
        val step = if (rounded >= 1200) 16 else 8
        return max(step, (rounded.toFloat() / step).roundToInt() * step)
    }

    fun findNearestSnapValue(value: Int, candidates: List<Int>, threshold: Int): Int {
        var best = value
        var bestDistance = threshold + 1
        for (candidate in candidates) {
            val distance = abs(value - candidate)
            if (distance <= threshold && distance < bestDistance) {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    fun snapMonitorRectEdges(rect: Rect, index: Int, rects: List<Rect>, fbW: Int, fbH: Int): Rect {
        if (fbW <= 0 || fbH <= 0) return rect

        val xCandidates = mutableListOf(0, fbW)
        val yCandidates = mutableListOf(0, fbH)
        for (i in rects.indices) {
            if (i == index) continue
            val other = rects[i]
            xCandidates.add(other.left)
            xCandidates.add(other.right)
            yCandidates.add(other.top)
            yCandidates.add(other.bottom)
        }

        val thresholdX = max(24, floor(fbW * 0.012f).toInt())
        val thresholdY = max(24, floor(fbH * 0.02f).toInt())

        val left = findNearestSnapValue(rect.left, xCandidates, thresholdX)
        var right = findNearestSnapValue(rect.right, xCandidates, thresholdX)
        val top = findNearestSnapValue(rect.top, yCandidates, thresholdY)
        var bottom = findNearestSnapValue(rect.bottom, yCandidates, thresholdY)

        if (right <= left) {
            right = min(fbW, left + max(1, rect.width()))
        }
        if (bottom <= top) {
            bottom = min(fbH, top + max(1, rect.height()))
        }

        return Rect(left, top, right, bottom)
    }

    fun clampManualMonitorRect(rect: Rect, fbW: Int, fbH: Int): Rect? {
        if (fbW <= 0 || fbH <= 0) return null
        val x = max(0, min(fbW - 1, rect.left))
        val y = max(0, min(fbH - 1, rect.top))
        val maxWidth = max(1, fbW - x)
        val maxHeight = max(1, fbH - y)
        val w = max(1, min(maxWidth, rect.width()))
        val h = max(1, min(maxHeight, rect.height()))
        if (w <= 0 || h <= 0) return null
        return Rect(x, y, x + w, y + h)
    }

    fun roundManualMonitorRectToCommonSize(rect: Rect, index: Int, rects: List<Rect>, fbW: Int, fbH: Int): Rect {
        if (fbW <= 0 || fbH <= 0) return rect

        var next = snapMonitorRectEdges(rect, index, rects, fbW, fbH)
        val edgeThresholdY = max(28, floor(fbH * 0.02f).toInt())
        val nearTop = next.top <= edgeThresholdY
        val nearBottom = abs(next.bottom - fbH) <= edgeThresholdY
        val nearlyFullHeight = next.height() >= floor(fbH * 0.78f).toInt()

        var nextTop = next.top
        var nextBottom = next.bottom
        var nextLeft = next.left
        var nextRight = next.right

        if ((nearTop && nearBottom) || nearlyFullHeight) {
            nextTop = 0
            nextBottom = fbH
        } else {
            val roundedH = roundMonitorDimension(next.height().toFloat())
            nextBottom = nextTop + roundedH
            if (nearTop) {
                nextTop = 0
                nextBottom = roundedH
            } else if (nearBottom) {
                nextTop = fbH - roundedH
                nextBottom = fbH
            }
        }

        var preferredWidth = roundMonitorDimension(next.width().toFloat())
        var chosenRatioDelta = Float.POSITIVE_INFINITY
        val currentRatio = next.width().toFloat() / max(1, next.height()).toFloat()
        val ratioOptions = getCommonMonitorAspectOptions()

        for (option in ratioOptions) {
            val width = roundMonitorDimension(option.ratio * (nextBottom - nextTop))
            val delta = abs(currentRatio - option.ratio)
            if (width <= 0 || width > fbW) continue
            if (delta < chosenRatioDelta) {
                chosenRatioDelta = delta
                preferredWidth = width
            }
        }

        val alignThresholdX = max(24, floor(fbW * 0.012f).toInt())
        val currentLeft = nextLeft
        val currentRight = nextRight
        val snappedLeft = findNearestSnapValue(currentLeft, listOf(0, fbW), alignThresholdX)
        val snappedRight = findNearestSnapValue(currentRight, listOf(0, fbW), alignThresholdX)

        if (chosenRatioDelta <= 0.42f) {
            if (abs(snappedLeft - currentLeft) <= alignThresholdX) {
                nextLeft = snappedLeft
                nextRight = nextLeft + preferredWidth
            } else if (abs(snappedRight - currentRight) <= alignThresholdX) {
                nextRight = snappedRight
                nextLeft = nextRight - preferredWidth
            } else {
                val center = nextLeft + (nextRight - nextLeft) / 2f
                nextLeft = (center - preferredWidth / 2f).roundToInt()
                nextRight = nextLeft + preferredWidth
            }
        } else {
            nextRight = nextLeft + preferredWidth
            if (abs(snappedLeft - currentLeft) <= alignThresholdX) {
                nextLeft = snappedLeft
                nextRight = nextLeft + preferredWidth
            } else if (abs(snappedRight - currentRight) <= alignThresholdX) {
                nextRight = snappedRight
                nextLeft = nextRight - preferredWidth
            }
        }

        val finalRect = Rect(nextLeft, nextTop, nextRight, nextBottom)
        val resnapped = snapMonitorRectEdges(finalRect, index, rects, fbW, fbH)
        return clampManualMonitorRect(resnapped, fbW, fbH) ?: rect
    }
}
