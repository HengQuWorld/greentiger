package com.hengqutiandi.vncviewer

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.foundation.focusable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import com.hengqutiandi.vncviewer.ui.theme.GreenTigerTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val EXTRA_DISPLAY_SESSION_ID = "display_session_id"
private const val EXTRA_DISPLAY_MONITOR_INDEX = "display_monitor_index"
private const val EXTRA_DISPLAY_TITLE = "display_title"

data class DisplayLaunchParams(
    val sessionId: String,
    val monitorIndex: Int,
    val title: String
)

internal fun createDisplayIntent(
    context: Context,
    params: DisplayLaunchParams
): Intent {
    return Intent(context, DisplayActivity::class.java)
        .putExtra(EXTRA_DISPLAY_SESSION_ID, params.sessionId)
        .putExtra(EXTRA_DISPLAY_MONITOR_INDEX, params.monitorIndex)
        .putExtra(EXTRA_DISPLAY_TITLE, params.title)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
}

internal fun Intent.toDisplayLaunchParams(): DisplayLaunchParams? {
    val sessionId = getStringExtra(EXTRA_DISPLAY_SESSION_ID).orEmpty()
    if (sessionId.isBlank()) return null
    return DisplayLaunchParams(
        sessionId = sessionId,
        monitorIndex = getIntExtra(EXTRA_DISPLAY_MONITOR_INDEX, 0),
        title = getStringExtra(EXTRA_DISPLAY_TITLE).orEmpty().ifBlank { "显示窗口" }
    )
}

@Suppress("DEPRECATION")
private fun applyTaskLabel(activity: Activity?, label: String) {
    if (activity == null || label.isBlank()) return
    activity.title = label
    try {
        activity.setTaskDescription(ActivityManager.TaskDescription(label))
    } catch (_: Throwable) {
    }
}

class DisplayActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, true)
        val launchParams = intent.toDisplayLaunchParams()
        if (launchParams == null) {
            finish()
            return
        }
        applyTaskLabel(this, launchParams.title.ifBlank { "显示窗口" })
        setContent {
            GreenTigerTheme {
                DisplayScreen(launchParams = launchParams)
            }
        }
    }
}

private data class IntLayout(
    val srcX: Int,
    val srcY: Int,
    val srcW: Int,
    val srcH: Int,
    val dstX: Int,
    val dstY: Int,
    val dstW: Int,
    val dstH: Int
)

private fun computeIntLayout(
    monitorRect: SharedViewerRect,
    windowW: Int,
    windowH: Int,
    @Suppress("UNUSED_PARAMETER") fbW: Int,
    @Suppress("UNUSED_PARAMETER") fbH: Int
): IntLayout {
    val mX = monitorRect.x
    val mY = monitorRect.y
    val mW = maxOf(1, monitorRect.w)
    val mH = maxOf(1, monitorRect.h)
    val winW = maxOf(1, windowW)
    val winH = maxOf(1, windowH)
    val scaleF = min(winW.toFloat() / mW.toFloat(), winH.toFloat() / mH.toFloat())
    val contentW = (mW * scaleF).roundToInt()
    val contentH = (mH * scaleF).roundToInt()
    val dX = (winW - contentW) / 2
    val dY = (winH - contentH) / 2
    return IntLayout(
        srcX = mX,
        srcY = mY,
        srcW = mW,
        srcH = mH,
        dstX = dX,
        dstY = dY,
        dstW = maxOf(1, contentW),
        dstH = maxOf(1, contentH)
    )
}

private fun mapTouchToRemote(touchX: Float, touchY: Float, layout: IntLayout): Pair<Int, Int> {
    val dx = touchX - layout.dstX
    val dy = touchY - layout.dstY
    if (layout.dstW <= 0 || layout.dstH <= 0) return 0 to 0
    val fracX = dx / layout.dstW
    val fracY = dy / layout.dstH
    val rx = (layout.srcX + fracX * layout.srcW).toInt().coerceIn(layout.srcX, layout.srcX + layout.srcW - 1)
    val ry = (layout.srcY + fracY * layout.srcH).toInt().coerceIn(layout.srcY, layout.srcY + layout.srcH - 1)
    return rx to ry
}

private fun keySymFromAndroidKey(code: Int, shiftDown: Boolean, capsOn: Boolean): Int {
    if (code in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) {
        val uppercase = capsOn.xor(shiftDown)
        val base = if (uppercase) 'A'.code else 'a'.code
        return base + (code - KeyEvent.KEYCODE_A)
    }
    if (code in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9) {
        if (!shiftDown) return '0'.code + (code - KeyEvent.KEYCODE_0)
        return when (code) {
            KeyEvent.KEYCODE_0 -> ')'.code
            KeyEvent.KEYCODE_1 -> '!'.code
            KeyEvent.KEYCODE_2 -> '@'.code
            KeyEvent.KEYCODE_3 -> '#'.code
            KeyEvent.KEYCODE_4 -> '$'.code
            KeyEvent.KEYCODE_5 -> '%'.code
            KeyEvent.KEYCODE_6 -> '^'.code
            KeyEvent.KEYCODE_7 -> '&'.code
            KeyEvent.KEYCODE_8 -> '*'.code
            KeyEvent.KEYCODE_9 -> '('.code
            else -> 0
        }
    }
    return when (code) {
        KeyEvent.KEYCODE_SPACE -> 0x20
        KeyEvent.KEYCODE_ENTER -> 0xFF0D
        KeyEvent.KEYCODE_TAB -> 0xFF09
        KeyEvent.KEYCODE_ESCAPE -> 0xFF1B
        KeyEvent.KEYCODE_DEL -> 0xFF08
        KeyEvent.KEYCODE_FORWARD_DEL -> 0xFFFF
        KeyEvent.KEYCODE_BACK -> 0xFF08
        KeyEvent.KEYCODE_DPAD_UP -> 0xFF52
        KeyEvent.KEYCODE_DPAD_DOWN -> 0xFF54
        KeyEvent.KEYCODE_DPAD_LEFT -> 0xFF51
        KeyEvent.KEYCODE_DPAD_RIGHT -> 0xFF53
        KeyEvent.KEYCODE_DPAD_CENTER -> 0xFF0D
        KeyEvent.KEYCODE_PAGE_UP -> 0xFF55
        KeyEvent.KEYCODE_PAGE_DOWN -> 0xFF56
        KeyEvent.KEYCODE_MOVE_HOME -> 0xFF50
        KeyEvent.KEYCODE_MOVE_END -> 0xFF57
        KeyEvent.KEYCODE_INSERT -> 0xFF63
        KeyEvent.KEYCODE_NUM_LOCK -> 0xFF7F
        KeyEvent.KEYCODE_CAPS_LOCK -> 0xFFE5
        KeyEvent.KEYCODE_SCROLL_LOCK -> 0xFF14
        KeyEvent.KEYCODE_SYSRQ -> 0xFF15
        KeyEvent.KEYCODE_BREAK -> 0xFF6B
        KeyEvent.KEYCODE_MINUS -> if (shiftDown) '_'.code else '-'.code
        KeyEvent.KEYCODE_EQUALS -> if (shiftDown) '+'.code else '='.code
        KeyEvent.KEYCODE_LEFT_BRACKET -> if (shiftDown) '{'.code else '['.code
        KeyEvent.KEYCODE_RIGHT_BRACKET -> if (shiftDown) '}'.code else ']'.code
        KeyEvent.KEYCODE_BACKSLASH -> if (shiftDown) '|'.code else '\\'.code
        KeyEvent.KEYCODE_SEMICOLON -> if (shiftDown) ':'.code else ';'.code
        KeyEvent.KEYCODE_APOSTROPHE -> if (shiftDown) '"'.code else '\''.code
        KeyEvent.KEYCODE_COMMA -> if (shiftDown) '<'.code else ','.code
        KeyEvent.KEYCODE_PERIOD -> if (shiftDown) '>'.code else '.'.code
        KeyEvent.KEYCODE_SLASH -> if (shiftDown) '?'.code else '/'.code
        KeyEvent.KEYCODE_GRAVE -> if (shiftDown) '~'.code else '`'.code
        KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT -> 0xFFE1
        KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT -> 0xFFE3
        KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT -> 0xFFE9
        KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT -> 0xFFEB
        KeyEvent.KEYCODE_F1 -> 0xFFBE
        KeyEvent.KEYCODE_F2 -> 0xFFBF
        KeyEvent.KEYCODE_F3 -> 0xFFC0
        KeyEvent.KEYCODE_F4 -> 0xFFC1
        KeyEvent.KEYCODE_F5 -> 0xFFC2
        KeyEvent.KEYCODE_F6 -> 0xFFC3
        KeyEvent.KEYCODE_F7 -> 0xFFC4
        KeyEvent.KEYCODE_F8 -> 0xFFC5
        KeyEvent.KEYCODE_F9 -> 0xFFC6
        KeyEvent.KEYCODE_F10 -> 0xFFC7
        KeyEvent.KEYCODE_F11 -> 0xFFC8
        KeyEvent.KEYCODE_F12 -> 0xFFC9
        else -> 0
    }
}

@Composable
private fun DisplayScreen(launchParams: DisplayLaunchParams) {
    val store = viewerMultiWindowStore
    var title by remember { mutableStateOf(launchParams.title.ifBlank { "显示窗口" }) }
    var statusText by remember { mutableStateOf("正在初始化...") }
    var displayBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var imageBitmap by remember { mutableStateOf<ImageBitmap?>(null) }
    var frameVersion by remember { mutableIntStateOf(0) }
    var windowW by remember { mutableIntStateOf(1) }
    var windowH by remember { mutableIntStateOf(1) }
    var fbW by remember { mutableIntStateOf(0) }
    var fbH by remember { mutableIntStateOf(0) }
    var monitorRect by remember { mutableStateOf(SharedViewerRect(0, 0, 1, 1)) }
    var connected by remember { mutableStateOf(false) }

    val sessionId = launchParams.sessionId
    val monitorIndex = maxOf(0, launchParams.monitorIndex)

    var lastSentX by remember { mutableIntStateOf(-1) }
    var lastSentY by remember { mutableIntStateOf(-1) }
    var lastSentMask by remember { mutableIntStateOf(0) }

    var touchStartX by remember { mutableFloatStateOf(0f) }
    var touchStartY by remember { mutableFloatStateOf(0f) }
    var touchMoved by remember { mutableStateOf(false) }
    var touchDragging by remember { mutableStateOf(false) }

    var isInteracting by remember { mutableStateOf(false) }
    var pendingBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var pendingVersion by remember { mutableIntStateOf(-1) }

    val focusRequester = remember { FocusRequester() }
    var softInputFieldValue by remember { mutableStateOf(TextFieldValue(" ")) }
    var softInputCommittedText by remember { mutableStateOf(" ") }

    LaunchedEffect(sessionId, monitorIndex) {
        title = launchParams.title.ifBlank { "屏幕 ${monitorIndex + 1}" }
        delay(200)
        focusRequester.requestFocus()
        while (isActive) {
            val snapshot = store.getSessionSnapshot(sessionId)
            if (snapshot == null) {
                if (!isInteracting) {
                    connected = false
                    statusText = "主会话不存在或已结束"
                }
            } else {
                if (isInteracting) {
                    if (snapshot.frame != null && snapshot.fbW > 0 && snapshot.fbH > 0 &&
                        snapshot.frameVersion != frameVersion
                    ) {
                        pendingBitmap = snapshot.frame
                        pendingVersion = snapshot.frameVersion
                    }
                } else {
                    connected = snapshot.connected
                    fbW = snapshot.fbW
                    fbH = snapshot.fbH
                    val monitor = snapshot.monitors.getOrNull(monitorIndex)
                    if (monitor != null && monitor.w > 0 && monitor.h > 0) {
                        monitorRect = monitor
                    } else {
                        monitorRect = SharedViewerRect(0, 0, maxOf(1, snapshot.fbW), maxOf(1, snapshot.fbH))
                    }
                    if (!snapshot.connected) {
                        statusText = "会话未连接"
                    } else if (snapshot.frame == null || snapshot.fbW <= 0 || snapshot.fbH <= 0) {
                        statusText = "正在等待画面..."
                    } else if (snapshot.frameVersion == frameVersion && displayBitmap != null) {
                        statusText = ""
                    } else {
                        statusText = ""
                        val oldBitmap = displayBitmap
                        displayBitmap = snapshot.frame
                        imageBitmap = snapshot.frame?.asImageBitmap()
                        frameVersion = snapshot.frameVersion
                        if (oldBitmap !== displayBitmap && oldBitmap != null && !oldBitmap.isRecycled) {
                            try { oldBitmap.recycle() } catch (_: Throwable) {}
                        }
                    }
                }
            }
            delay(66)
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            displayBitmap?.recycle()
            pendingBitmap?.recycle()
        }
    }

    val intLayout = remember(monitorRect, windowW, windowH, fbW, fbH) {
        computeIntLayout(monitorRect, windowW, windowH, fbW, fbH)
    }

    fun toRemote(localX: Float, localY: Float): Pair<Int, Int> {
        return mapTouchToRemote(localX, localY, intLayout)
    }

    fun safeSendPointer(x: Int, y: Int, mask: Int, force: Boolean = false) {
        if (!connected || sessionId.isBlank()) return
        if (!force && lastSentX == x && lastSentY == y && lastSentMask == mask) return
        val client = store.getVncClient(sessionId) ?: return
        try {
            client.sendPointer(x, y, mask)
            lastSentX = x
            lastSentY = y
            lastSentMask = mask
        } catch (_: Throwable) {
        }
    }

    fun safeSendKey(keysym: Int, down: Boolean) {
        if (!connected || sessionId.isBlank()) return
        val client = store.getVncClient(sessionId) ?: return
        try {
            client.sendKey(keysym, down)
        } catch (_: Throwable) {
        }
    }

    fun beginInteraction() {
        isInteracting = true
    }

    fun endInteraction() {
        isInteracting = false
        pendingBitmap?.let { bmp ->
            displayBitmap?.recycle()
            displayBitmap = bmp
            imageBitmap = bmp.asImageBitmap()
            frameVersion = pendingVersion
            pendingBitmap = null
        }
    }

    fun sendRemoteBackspace(count: Int) {
        repeat(max(0, count)) {
            safeSendKey(0xff08, true)
            safeSendKey(0xff08, false)
        }
    }

    fun sendCommittedText(text: String) {
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            val keysym = when {
                codePoint == '\n'.code -> 0xff0d
                codePoint in 0x20..0x7E -> codePoint
                codePoint in 0xA0..0xFF -> codePoint
                else -> 0x01000000 or codePoint
            }
            safeSendKey(keysym, true)
            safeSendKey(keysym, false)
            index += Character.charCount(codePoint)
        }
    }

    fun computeTextDelta(previous: String, next: String): Pair<Int, String> {
        val prevChars = previous.map { it }.toList()
        val nextChars = next.map { it }.toList()
        var prefixLen = 0
        while (prefixLen < prevChars.size && prefixLen < nextChars.size && prevChars[prefixLen] == nextChars[prefixLen]) {
            prefixLen++
        }
        var suffixLen = 0
        while (
            suffixLen < prevChars.size - prefixLen &&
            suffixLen < nextChars.size - prefixLen &&
            prevChars[prevChars.size - 1 - suffixLen] == nextChars[nextChars.size - 1 - suffixLen]
        ) {
            suffixLen++
        }
        val deletedCount = prevChars.size - prefixLen - suffixLen
        val insertedText = nextChars.subList(prefixLen, nextChars.size - suffixLen).joinToString("")
        return deletedCount to insertedText
    }

    val handleKeyEvent: (androidx.compose.ui.input.key.KeyEvent) -> Boolean = { event ->
        val nativeEvent = event.nativeKeyEvent
        val keysym = keySymFromAndroidKey(
            nativeEvent.keyCode,
            nativeEvent.isShiftPressed,
            nativeEvent.metaState and KeyEvent.META_CAPS_LOCK_ON != 0
        )
        if (keysym == 0) {
            false
        } else {
            safeSendKey(keysym, nativeEvent.action == KeyEvent.ACTION_DOWN)
            true
        }
    }

    BackHandler(enabled = connected) {
        safeSendKey(0xFF08, true)
        safeSendKey(0xFF08, false)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .statusBarsPadding()
            .navigationBarsPadding()
            .focusRequester(focusRequester)
            .focusable()
            .onPreviewKeyEvent(handleKeyEvent)
            .onSizeChanged { size ->
                windowW = size.width.coerceAtLeast(1)
                windowH = size.height.coerceAtLeast(1)
            }
            .pointerInput(sessionId, connected) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val localX = down.position.x
                    val localY = down.position.y
                    val remote = toRemote(localX, localY)

                    beginInteraction()
                    touchStartX = localX
                    touchStartY = localY
                    touchMoved = false
                    touchDragging = false
                    safeSendPointer(remote.first, remote.second, 0)

                    do {
                        val event = awaitPointerEvent()
                        val changed = event.changes.firstOrNull() ?: break
                        when (event.type) {
                            PointerEventType.Move -> {
                                val cx = changed.position.x
                                val cy = changed.position.y
                                val dist = abs(cx - touchStartX) + abs(cy - touchStartY)
                                if (dist >= 6f) touchMoved = true
                                if (touchMoved && !touchDragging) {
                                    touchDragging = true
                                    val startRemote = toRemote(touchStartX, touchStartY)
                                    safeSendPointer(startRemote.first, startRemote.second, 1)
                                }
                                val currentRemote = toRemote(cx, cy)
                                safeSendPointer(currentRemote.first, currentRemote.second, if (touchDragging) 1 else 0)
                            }
                            PointerEventType.Release -> {
                                val cx = changed.position.x
                                val cy = changed.position.y
                                val currentRemote = toRemote(cx, cy)
                                if (touchDragging) {
                                    touchDragging = false
                                    safeSendPointer(currentRemote.first, currentRemote.second, 0)
                                } else if (!touchMoved) {
                                    safeSendPointer(currentRemote.first, currentRemote.second, 1)
                                    safeSendPointer(currentRemote.first, currentRemote.second, 0)
                                } else {
                                    safeSendPointer(currentRemote.first, currentRemote.second, 0)
                                }
                                touchDragging = false
                                touchMoved = false
                                endInteraction()
                                return@awaitEachGesture
                            }
                            PointerEventType.Exit -> {
                                touchDragging = false
                                safeSendPointer(lastSentX.coerceAtLeast(0), lastSentY.coerceAtLeast(0), 0)
                                endInteraction()
                                return@awaitEachGesture
                            }
                            else -> {}
                        }
                    } while (true)
                }
            }
    ) {
        val bmp = imageBitmap
        if (bmp != null) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawImage(
                    image = bmp,
                    srcOffset = androidx.compose.ui.unit.IntOffset(intLayout.srcX, intLayout.srcY),
                    srcSize = androidx.compose.ui.unit.IntSize(intLayout.srcW, intLayout.srcH),
                    dstOffset = androidx.compose.ui.unit.IntOffset(intLayout.dstX, intLayout.dstY),
                    dstSize = androidx.compose.ui.unit.IntSize(intLayout.dstW, intLayout.dstH)
                )
            }
        }

        BasicTextField(
            value = softInputFieldValue,
            onValueChange = { nextValue ->
                if (!connected || nextValue.composition != null) {
                    softInputFieldValue = nextValue
                    return@BasicTextField
                }
                if (nextValue.text.isEmpty()) {
                    sendRemoteBackspace(1)
                    softInputCommittedText = " "
                    softInputFieldValue = TextFieldValue(" ", selection = androidx.compose.ui.text.TextRange(1))
                    return@BasicTextField
                }
                val oldRealText = if (softInputCommittedText.startsWith(" ")) softInputCommittedText.substring(1) else softInputCommittedText
                val newRealText = if (nextValue.text.startsWith(" ")) nextValue.text.substring(1) else nextValue.text
                val (deletedCount, insertedText) = computeTextDelta(oldRealText, newRealText)
                if (deletedCount > 0) {
                    sendRemoteBackspace(deletedCount)
                }
                if (insertedText.isNotEmpty()) {
                    sendCommittedText(insertedText)
                }
                softInputCommittedText = " " + newRealText
                softInputFieldValue = nextValue.copy(text = softInputCommittedText)
            },
            modifier = Modifier
                .align(Alignment.TopStart)
                .size(1.dp)
                .alpha(0f)
                .onPreviewKeyEvent(handleKeyEvent),
            enabled = connected,
            singleLine = false,
            textStyle = androidx.compose.ui.text.TextStyle(color = Color.Transparent),
            cursorBrush = SolidColor(Color.Transparent),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
            keyboardActions = KeyboardActions()
        )

        if (displayBitmap == null || statusText.isNotEmpty()) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .padding(16.dp)
                    .background(Color.Black.copy(alpha = 0.72f), RoundedCornerShape(16.dp))
                    .padding(16.dp)
                    .align(Alignment.Center)
            ) {
                Text(
                    text = title,
                    fontSize = 16.sp,
                    color = Color.White,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    text = statusText.ifBlank { "正在等待画面..." },
                    fontSize = 12.sp,
                    color = Color(0xFFd6d3d1)
                )
            }
        }
    }
}
