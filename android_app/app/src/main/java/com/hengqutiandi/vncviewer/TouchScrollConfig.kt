package com.hengqutiandi.vncviewer

import kotlin.math.abs

internal val touchScrollOptions = listOf(
    0 to "自动",
    18 to "慢",
    12 to "中",
    8 to "快"
)

internal fun normalizeTouchScrollStep(step: Int): Int {
    if (step <= 0) {
        return 0
    }
    return touchScrollOptions
        .filter { it.first > 0 }
        .minByOrNull { abs(it.first - step) }
        ?.first
        ?: 18
}

internal fun resolveTouchScrollPreset(step: Int): Int {
    val normalized = normalizeTouchScrollStep(step)
    if (normalized <= 0) {
        return 0
    }
    return touchScrollOptions
        .filter { it.first > 0 }
        .minByOrNull { abs(it.first - normalized) }
        ?.first
        ?: 18
}

internal fun getTouchScrollStepPx(step: Int): Float {
    val normalized = normalizeTouchScrollStep(step)
    return if (normalized <= 0) {
        18f
    } else {
        normalized.toFloat()
    }
}
