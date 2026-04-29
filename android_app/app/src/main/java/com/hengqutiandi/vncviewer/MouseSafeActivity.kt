package com.hengqutiandi.vncviewer

import android.os.Bundle
import android.view.InputDevice
import android.view.MotionEvent
import androidx.activity.ComponentActivity

abstract class MouseSafeActivity : ComponentActivity() {
    protected var statusBarInsetY = 0f

    protected abstract fun mouseHandler(): ((MotionEvent) -> Boolean)?

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.post {
            try {
                @Suppress("DEPRECATION")
                window.decorView.isFocusableInTouchMode = false
                window.decorView.setOnLongClickListener { true }
                window.decorView.importantForAccessibility = android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO
                val insets = window.decorView.rootWindowInsets
                if (insets != null) {
                    statusBarInsetY = insets.getInsets(android.view.WindowInsets.Type.statusBars()).top.toFloat()
                }
            } catch (_: Throwable) {}
        }
    }

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean {
        if (isMouseEvent(ev)) {
            val handler = mouseHandler()
            when (ev.actionMasked) {
                MotionEvent.ACTION_SCROLL,
                MotionEvent.ACTION_HOVER_MOVE -> {
                    if (handler != null) {
                        val adjusted = if (statusBarInsetY > 0) {
                            MotionEvent.obtain(ev).also { it.offsetLocation(0f, -statusBarInsetY) }
                        } else {
                            ev
                        }
                        handler(adjusted)
                        if (adjusted !== ev) adjusted.recycle()
                    }
                }
            }
            return true
        }
        return super.dispatchGenericMotionEvent(ev)
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.source and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE &&
            ev.actionMasked == MotionEvent.ACTION_MOVE &&
            ev.buttonState == 0
        ) {
            return true
        }
        return super.dispatchTouchEvent(ev)
    }

    override fun onActionModeStarted(mode: android.view.ActionMode) {
        super.onActionModeStarted(mode)
        mode.finish()
    }
}
