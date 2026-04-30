package com.hengqutiandi.vncviewer

import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.activity.ComponentActivity

abstract class MouseSafeActivity : ComponentActivity() {
    protected var statusBarInsetY = 0f
    private var mouseNonPrimaryDownActive = false
    private var lastMouseX = 0f
    private var lastMouseY = 0f

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
            lastMouseX = ev.x
            lastMouseY = ev.y
            when (ev.actionMasked) {
                MotionEvent.ACTION_SCROLL,
                MotionEvent.ACTION_HOVER_MOVE,
                MotionEvent.ACTION_BUTTON_PRESS,
                MotionEvent.ACTION_BUTTON_RELEASE -> {
                    routeMouseToHandler(ev)
                }
            }
            return true
        }
        return super.dispatchGenericMotionEvent(ev)
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.source and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE) {
            lastMouseX = ev.x
            lastMouseY = ev.y
            when (ev.actionMasked) {
                MotionEvent.ACTION_MOVE -> {
                    if (ev.buttonState == 0) return true
                }
                MotionEvent.ACTION_DOWN -> {
                    if (ev.buttonState and (MotionEvent.BUTTON_SECONDARY or MotionEvent.BUTTON_TERTIARY) != 0) {
                        mouseNonPrimaryDownActive = true
                        routeMouseToHandler(ev)
                        return true
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (mouseNonPrimaryDownActive) {
                        mouseNonPrimaryDownActive = false
                        routeMouseToHandler(ev)
                        return true
                    }
                }
                MotionEvent.ACTION_CANCEL -> {
                    if (mouseNonPrimaryDownActive) {
                        mouseNonPrimaryDownActive = false
                        routeMouseToHandler(ev)
                        return true
                    }
                }
            }
        }
        return super.dispatchTouchEvent(ev)
    }

    private fun routeMouseToHandler(ev: MotionEvent) {
        val handler = mouseHandler() ?: return
        val adjusted = if (statusBarInsetY > 0) {
            MotionEvent.obtain(ev).also { it.offsetLocation(0f, -statusBarInsetY) }
        } else {
            ev
        }
        handler(adjusted)
        if (adjusted !== ev) adjusted.recycle()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.source and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE) {
            if (event.keyCode == KeyEvent.KEYCODE_BACK) {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    val downEvent = createSyntheticMouseButtonEvent(
                        MotionEvent.ACTION_DOWN,
                        MotionEvent.BUTTON_SECONDARY
                    )
                    routeMouseToHandler(downEvent)
                    downEvent.recycle()
                    Log.d("MouseSafe", "Intercepted mouse BACK as right-click DOWN at ($lastMouseX, $lastMouseY)")
                } else if (event.action == KeyEvent.ACTION_UP) {
                    val upEvent = createSyntheticMouseButtonEvent(
                        MotionEvent.ACTION_UP,
                        0
                    )
                    routeMouseToHandler(upEvent)
                    upEvent.recycle()
                    Log.d("MouseSafe", "Intercepted mouse BACK as right-click UP at ($lastMouseX, $lastMouseY)")
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun createSyntheticMouseButtonEvent(action: Int, buttonState: Int): MotionEvent {
        val now = android.os.SystemClock.uptimeMillis()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val props = android.view.MotionEvent.PointerProperties()
            props.toolType = MotionEvent.TOOL_TYPE_MOUSE
            val coords = android.view.MotionEvent.PointerCoords()
            coords.x = lastMouseX
            coords.y = lastMouseY
            coords.pressure = 1f
            coords.size = 1f
            return MotionEvent.obtain(
                now, now, action,
                1, arrayOf(props), arrayOf(coords),
                0, buttonState,
                1f, 1f,
                0, 0,
                InputDevice.SOURCE_MOUSE,
                0
            )
        }
        val ev = MotionEvent.obtain(now, now, action, lastMouseX, lastMouseY, 0)
        ev.source = InputDevice.SOURCE_MOUSE
        return ev
    }

    override fun onActionModeStarted(mode: android.view.ActionMode) {
        super.onActionModeStarted(mode)
        mode.finish()
    }
}
