package com.hengqutiandi.vncviewer

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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

// 全局鼠标通用运动事件回调，由 DisplayScreen 注册，DisplayActivity 转发
private var activeDisplayGenericMotionHandler: ((MotionEvent) -> Boolean)? = null

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

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean {
        val handler = activeDisplayGenericMotionHandler
        if (handler != null && isMouseEvent(ev)) {
            if (handler(ev)) return true
        }
        return super.dispatchGenericMotionEvent(ev)
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

private data class FrameSnapshot(
    val image: ImageBitmap,
    val layout: IntLayout
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
    val rx = (layout.srcX + fracX * layout.srcW).toInt()
    val ry = (layout.srcY + fracY * layout.srcH).toInt()
    return rx to ry
}

@Composable
private fun DisplayScreen(launchParams: DisplayLaunchParams) {
    val store = viewerMultiWindowStore
    var title by remember { mutableStateOf(launchParams.title.ifBlank { "显示窗口" }) }
    var statusText by remember { mutableStateOf("正在初始化...") }
    var frameSnapshot by remember { mutableStateOf<FrameSnapshot?>(null) }
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
    var touchStartTs by remember { mutableStateOf(0L) }
    var touchMoved by remember { mutableStateOf(false) }
    var touchDragging by remember { mutableStateOf(false) }

    var isInteracting by remember { mutableStateOf(false) }
    var pendingBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var pendingVersion by remember { mutableIntStateOf(-1) }
    var interactSkipCounter by remember { mutableIntStateOf(0) }

    val focusRequester = remember { FocusRequester() }
    var softInputFieldValue by remember { mutableStateOf(TextFieldValue(" ")) }
    var softInputCommittedText by remember { mutableStateOf(" ") }

    LaunchedEffect(sessionId, monitorIndex) {
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
                val curFbW = snapshot.fbW
                val curFbH = snapshot.fbH
                val curMonitor = snapshot.monitors.getOrNull(monitorIndex)
                    ?.takeIf { it.w > 0 && it.h > 0 }
                    ?: SharedViewerRect(0, 0, maxOf(1, curFbW), maxOf(1, curFbH))
                if (isInteracting) {
                    if (snapshot.frame != null && curFbW > 0 && curFbH > 0 &&
                        snapshot.frameVersion != frameVersion
                    ) {
                        fbW = curFbW
                        fbH = curFbH
                        monitorRect = curMonitor
                        interactSkipCounter++
                        if (interactSkipCounter % 3 == 0) {
                            val layout = computeIntLayout(curMonitor, windowW, windowH, curFbW, curFbH)
                            frameSnapshot = FrameSnapshot(snapshot.frame.asImageBitmap(), layout)
                            frameVersion = snapshot.frameVersion
                        } else {
                            pendingBitmap = snapshot.frame
                            pendingVersion = snapshot.frameVersion
                        }
                    }
                } else {
                    connected = snapshot.connected
                    fbW = curFbW
                    fbH = curFbH
                    monitorRect = curMonitor
                    if (!snapshot.connected) {
                        statusText = "会话未连接"
                    } else if (snapshot.frame == null || curFbW <= 0 || curFbH <= 0) {
                        statusText = "正在等待画面..."
                    } else if (snapshot.frameVersion == frameVersion && frameSnapshot != null) {
                        statusText = ""
                    } else {
                        statusText = ""
                        val newFrame = snapshot.frame
                        if (newFrame != null) {
                            val layout = computeIntLayout(curMonitor, windowW, windowH, curFbW, curFbH)
                            frameSnapshot = FrameSnapshot(newFrame.asImageBitmap(), layout)
                            frameVersion = snapshot.frameVersion
                        }
                    }
                }
            }
            delay(66)
        }
    }

    val intLayout = remember(monitorRect, windowW, windowH, fbW, fbH) {
        computeIntLayout(monitorRect, windowW, windowH, fbW, fbH)
    }

    val latestLayout = androidx.compose.runtime.rememberUpdatedState(frameSnapshot?.layout ?: intLayout)

    fun toRemote(localX: Float, localY: Float): Pair<Int, Int> {
        return mapTouchToRemote(localX, localY, latestLayout.value)
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

    fun safeSendClick(x: Int, y: Int, mask: Int) {
        safeSendPointer(x, y, mask, force = true)
        safeSendPointer(x, y, 0, force = true)
    }

    fun safeSendScrollAt(x: Int, y: Int, mask: Int, baseMask: Int = 0, repeatCount: Int = 1) {
        if (!connected || sessionId.isBlank()) return
        val client = store.getVncClient(sessionId) ?: return
        try {
            if (baseMask != 0) {
                client.sendPointer(x, y, baseMask)
            }
            repeat(repeatCount) {
                client.sendPointer(x, y, mask)
                client.sendPointer(x, y, if (baseMask != 0) baseMask else 0)
            }
            if (baseMask != 0) {
                client.sendPointer(x, y, 0)
            }
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

    val keySender = object : KeySender {
        override fun sendKey(keysym: Int, down: Boolean) {
            safeSendKey(keysym, down)
        }
    }

    fun beginInteraction() {
        isInteracting = true
    }

    fun endInteraction() {
        isInteracting = false
        interactSkipCounter = 0
        pendingBitmap?.let { bmp ->
            val layout = computeIntLayout(monitorRect, windowW, windowH, fbW, fbH)
            frameSnapshot = FrameSnapshot(bmp.asImageBitmap(), layout)
            frameVersion = pendingVersion
        }
        pendingBitmap = null
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

    DisposableEffect(Unit) {
        onDispose {
            frameSnapshot = null
            pendingBitmap = null
        }
    }

    // 注册鼠标通用运动事件处理器
    val latestLastSentX = androidx.compose.runtime.rememberUpdatedState(lastSentX)
    val latestLastSentY = androidx.compose.runtime.rememberUpdatedState(lastSentY)

    DisposableEffect(Unit) {
        activeDisplayGenericMotionHandler = { event ->
            val layoutVal = latestLayout.value
            val lastX = latestLastSentX.value
            val lastY = latestLastSentY.value

            val pointMapper = object : PointMapper {
                override fun mapToRemote(x: Float, y: Float): Pair<Int, Int>? {
                    return mapTouchToRemote(x, y, layoutVal)
                }
            }

            val sender = object : ViewerMouseEventSender {
                override fun sendPointer(x: Int, y: Int, mask: Int) {
                    safeSendPointer(x, y, mask)
                }

                override fun sendScrollAt(x: Int, y: Int, mask: Int, baseMask: Int, repeatCount: Int) {
                    safeSendScrollAt(x, y, mask, baseMask, repeatCount)
                }

                override val lastPointerX: Int get() = lastX
                override val lastPointerY: Int get() = lastY
            }

            handleViewerMouseEvent(event, pointMapper, sender)
        }
        onDispose {
            activeDisplayGenericMotionHandler = null
        }
    }

    val monitorLabel = "屏幕 ${monitorIndex + 1}"

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
                    touchStartTs = System.currentTimeMillis()
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
                                val clickElapsed = (System.currentTimeMillis() as Long) - touchStartTs
                                if (touchDragging) {
                                    touchDragging = false
                                    safeSendPointer(currentRemote.first, currentRemote.second, 0)
                                } else if (!touchMoved && clickElapsed <= 350L) {
                                    safeSendClick(currentRemote.first, currentRemote.second, 1)
                                } else if (!touchMoved && clickElapsed > 500L) {
                                    // 长按触发鼠标右键
                                    safeSendClick(currentRemote.first, currentRemote.second, 4)
                                } else {
                                    safeSendPointer(currentRemote.first, currentRemote.second, 0)
                                }
                                touchDragging = false
                                touchMoved = false
                                endInteraction()
                                return@awaitEachGesture
                            }
                            PointerEventType.Exit -> {
                                if (touchDragging) {
                                    val lastRemote = toRemote(
                                        changed.position.x,
                                        changed.position.y
                                    )
                                    safeSendPointer(lastRemote.first, lastRemote.second, 1)
                                }
                            }
                            else -> {}
                        }
                    } while (true)
                }
            }
    ) {
        val snap = frameSnapshot
        if (snap != null) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawImage(
                    image = snap.image,
                    srcOffset = androidx.compose.ui.unit.IntOffset(snap.layout.srcX, snap.layout.srcY),
                    srcSize = androidx.compose.ui.unit.IntSize(snap.layout.srcW, snap.layout.srcH),
                    dstOffset = androidx.compose.ui.unit.IntOffset(snap.layout.dstX, snap.layout.dstY),
                    dstSize = androidx.compose.ui.unit.IntSize(snap.layout.dstW, snap.layout.dstH)
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
                    sendRemoteBackspace(keySender, 1)
                    softInputCommittedText = " "
                    softInputFieldValue = TextFieldValue(" ", selection = androidx.compose.ui.text.TextRange(1))
                    return@BasicTextField
                }
                val oldRealText = if (softInputCommittedText.startsWith(" ")) softInputCommittedText.substring(1) else softInputCommittedText
                val newRealText = if (nextValue.text.startsWith(" ")) nextValue.text.substring(1) else nextValue.text
                val delta = buildTextDelta(oldRealText, newRealText)
                if (delta.deletedCount > 0) {
                    sendRemoteBackspace(keySender, delta.deletedCount)
                }
                if (delta.insertedText.isNotEmpty()) {
                    sendCommittedText(keySender, delta.insertedText)
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

        if (frameSnapshot == null || statusText.isNotEmpty()) {
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

        Box(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .background(Color.Black.copy(alpha = 0.6f))
                .padding(horizontal = 16.dp, vertical = 6.dp)
        ) {
            Text(
                text = monitorLabel,
                fontSize = 14.sp,
                color = Color.White,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.align(Alignment.Center)
            )
        }
    }
}
