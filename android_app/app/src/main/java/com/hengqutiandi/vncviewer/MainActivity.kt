package com.hengqutiandi.vncviewer

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.view.InputDevice
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.ui.input.pointer.*
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.border
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.setValue
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.focusable
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.hengqutiandi.vncviewer.data.ConnectionsRepository
import com.hengqutiandi.vncviewer.model.ConnectionItem
import com.hengqutiandi.vncviewer.model.DEFAULT_SSH_PORT
import com.hengqutiandi.vncviewer.model.DEFAULT_VNC_PORT
import com.hengqutiandi.vncviewer.model.HostPort
import com.hengqutiandi.vncviewer.model.SSH_AUTH_PASSWORD
import com.hengqutiandi.vncviewer.model.SSH_AUTH_PUBLIC_KEY
import com.hengqutiandi.vncviewer.model.SshConnectionConfig
import com.hengqutiandi.vncviewer.model.generateConnectionId
import com.hengqutiandi.vncviewer.model.normalizeSshConfigForAddress
import com.hengqutiandi.vncviewer.model.normalizeConnName
import com.hengqutiandi.vncviewer.model.parseAddress
import com.hengqutiandi.vncviewer.model.resolveSshConfigForConnection
import com.hengqutiandi.vncviewer.model.validateSshConfig
import com.hengqutiandi.vncviewer.native.DamageRect as NativeDamageRect
import com.hengqutiandi.vncviewer.native.FramebufferInfo
import com.hengqutiandi.vncviewer.native.VncClient
import com.hengqutiandi.vncviewer.ui.theme.GreenTigerTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

private enum class AppScreen {
    Home,
    Viewer
}

private const val PROJECT_CONTACT_EMAIL = "contact@hengqu.world"
private const val PROJECT_HOMEPAGE_URL = "https://www.hengqu.world"
private const val PROJECT_SOURCE_URL = "https://github.com/hengquworld/greentiger"
private const val PRIVACY_POLICY_ASSET_NAME = "privacy-policy.md"
private const val USER_AGREEMENT_ASSET_NAME = "user-agreement.md"

private enum class AgreementType {
    PrivacyPolicy,
    UserAgreement
}

private data class AgreementDocument(
    val type: AgreementType,
    val title: String,
    val assetName: String,
    val contentDescription: String
)

private sealed interface MarkdownBlock {
    data class Heading(val level: Int, val text: String) : MarkdownBlock
    data class Paragraph(val text: String) : MarkdownBlock
    data class Bullet(val text: String) : MarkdownBlock
}

private fun loadBundledTextAsset(context: Context, assetName: String, documentName: String): String {
    return runCatching {
        context.assets.open(assetName).bufferedReader().use { it.readText() }
    }.getOrElse {
        "$documentName 暂时无法加载，请稍后重试。"
    }
}

private fun stripInlineMarkdown(text: String): String {
    return text.replace("`", "").replace(Regex("\\[(.+?)\\]\\((.+?)\\)"), "$1")
}

private fun parseMarkdownBlocks(markdown: String): List<MarkdownBlock> {
    val blocks = mutableListOf<MarkdownBlock>()
    val paragraphBuffer = mutableListOf<String>()

    fun flushParagraph() {
        if (paragraphBuffer.isEmpty()) return
        blocks += MarkdownBlock.Paragraph(paragraphBuffer.joinToString("\n") { stripInlineMarkdown(it.trim()) })
        paragraphBuffer.clear()
    }

    markdown.lines().forEach { rawLine ->
        val line = rawLine.trim()
        when {
            line.isBlank() -> flushParagraph()
            line.startsWith("### ") -> {
                flushParagraph()
                blocks += MarkdownBlock.Heading(3, stripInlineMarkdown(line.removePrefix("### ").trim()))
            }
            line.startsWith("## ") -> {
                flushParagraph()
                blocks += MarkdownBlock.Heading(2, stripInlineMarkdown(line.removePrefix("## ").trim()))
            }
            line.startsWith("# ") -> {
                flushParagraph()
                blocks += MarkdownBlock.Heading(1, stripInlineMarkdown(line.removePrefix("# ").trim()))
            }
            line.startsWith("- ") -> {
                flushParagraph()
                blocks += MarkdownBlock.Bullet(stripInlineMarkdown(line.removePrefix("- ").trim()))
            }
            else -> paragraphBuffer += line
        }
    }

    flushParagraph()
    return blocks
}

@Composable
private fun FloatingNavigationPad(
    onUp: () -> Unit,
    onDown: () -> Unit,
    onLeft: () -> Unit,
    onRight: () -> Unit,
    onZoomIn: () -> Unit,
    onZoomOut: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .padding(8.dp)
            .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(16.dp))
            .padding(8.dp)
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                NavPadButton("－", onZoomOut)
                NavPadButton("＋", onZoomIn)
            }
            Spacer(modifier = Modifier.height(4.dp))
            NavPadButton("↑", onUp)
            Row(horizontalArrangement = Arrangement.spacedBy(36.dp)) {
                NavPadButton("←", onLeft)
                NavPadButton("→", onRight)
            }
            NavPadButton("↓", onDown)
        }
    }
}

@Composable
private fun NavPadButton(text: String, onClick: () -> Unit) {
    val currentOnClick by androidx.compose.runtime.rememberUpdatedState(onClick)
    Box(
        modifier = Modifier
            .size(36.dp)
            .background(Color.White.copy(alpha = 0.15f), RoundedCornerShape(8.dp))
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    currentOnClick()
                    var running = true
                    val job = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main).launch {
                        while (running) {
                            kotlinx.coroutines.delay(100)
                            if (running) currentOnClick()
                        }
                    }
                    waitForUpOrCancellation()
                    running = false
                    job.cancel()
                }
            },
        contentAlignment = Alignment.Center
    ) {
        Text(text, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold)
    }
}

private enum class ViewerInteractionMode {
    Control,
    Inspect
}

private enum class EditConnectionTab {
    Basic,
    Advanced
}

private data class OpenViewerWindow(
    val taskId: Int,
    val title: String,
    val host: String,
    val isCurrent: Boolean
)

@Suppress("DEPRECATION")
private fun applyTaskLabel(activity: Activity?, label: String) {
    if (activity == null || label.isBlank()) {
        return
    }
    activity.title = label
    try {
        activity.setTaskDescription(ActivityManager.TaskDescription(label))
    } catch (_: Throwable) {
    }
}

private fun resolveViewerHostTarget(address: String, ssh: SshConnectionConfig): String {
    val target = buildConnectionPresentation(address, ssh).vncTarget.trim()
    return target.takeUnless { it.isBlank() || it == "未填写" } ?: address.trim()
}

private fun buildViewerWindowLabel(title: String, hostTarget: String): String {
    val trimmedTitle = title.trim()
    val trimmedHost = hostTarget.trim()
    return when {
        trimmedTitle.isBlank() -> trimmedHost
        trimmedHost.isBlank() || trimmedHost == "未填写" || trimmedTitle == trimmedHost -> trimmedTitle
        else -> "$trimmedTitle · $trimmedHost"
    }
}

private fun buildViewerSubtitleText(hostTarget: String, connected: Boolean, frameSize: IntSize): String {
    val trimmedHost = hostTarget.trim()
    if (trimmedHost.isBlank()) {
        return if (connected) "已连接" else "输入地址后即可建立远程桌面连接"
    }
    return if (connected && frameSize.width > 0 && frameSize.height > 0) {
        "主机 $trimmedHost · ${frameSize.width}x${frameSize.height}"
    } else {
        "主机 $trimmedHost"
    }
}

@Suppress("DEPRECATION")
private fun queryOpenViewerWindows(context: Context, currentTaskId: Int): List<OpenViewerWindow> {
    val manager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
    return manager.appTasks.mapNotNull { task ->
        val info = try {
            task.taskInfo
        } catch (_: Throwable) {
            null
        } ?: return@mapNotNull null
        val args = info.baseIntent.toViewerLaunchArgs() ?: return@mapNotNull null
        val taskId = info.id
        OpenViewerWindow(
            taskId = taskId,
            title = normalizeConnName(args.connName, args.address),
            host = resolveViewerHostTarget(args.address, args.ssh),
            isCurrent = taskId == currentTaskId
        )
    }.sortedWith(compareByDescending<OpenViewerWindow> { it.isCurrent }.thenBy { it.title.lowercase() })
}

@Suppress("DEPRECATION")
private fun moveToViewerWindow(context: Context, taskId: Int): Boolean {
    val manager = context.getSystemService(ActivityManager::class.java) ?: return false
    val appTask = manager.appTasks.firstOrNull {
        try {
            it.taskInfo.id == taskId
        } catch (_: Throwable) {
            false
        }
    } ?: return false
    return try {
        appTask.moveToFront()
        true
    } catch (_: Throwable) {
        false
    }
}

private data class EditConnectionState(
    val id: String = "",
    val name: String = "",
    val address: String = "",
    val user: String = "",
    val password: String = "",
    val storePassword: Boolean = true,
    val touchScrollStep: Int = 0,
    val ssh: SshConnectionConfig = SshConnectionConfig()
)

private data class ConnectionPasswordPromptState(
    val connection: ConnectionItem,
    val password: String = "",
    val storePassword: Boolean = false
)

private fun createConnectionItem(
    id: String,
    name: String,
    address: String,
    user: String,
    password: String,
    storePassword: Boolean,
    touchScrollStep: Int,
    ssh: SshConnectionConfig,
    lastUsedAt: Long
): ConnectionItem {
    val normalizedAddress = address.trim()
    return ConnectionItem(
        id = id,
        name = name.trim(),
        address = normalizedAddress,
        user = user.trim(),
        password = if (storePassword) password else "",
        storePassword = storePassword,
        touchScrollStep = normalizeTouchScrollStep(touchScrollStep),
        ssh = normalizeSshConfigForAddress(ssh, normalizedAddress),
        lastUsedAt = lastUsedAt
    )
}

private fun ConnectionItem.normalized(lastUsedAt: Long = this.lastUsedAt): ConnectionItem =
    createConnectionItem(
        id = id,
        name = name,
        address = address,
        user = user,
        password = password,
        storePassword = storePassword,
        touchScrollStep = touchScrollStep,
        ssh = ssh,
        lastUsedAt = lastUsedAt
    )

@Composable
private fun PasswordField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    label: String = "密码",
    enabled: Boolean = true,
    imeAction: ImeAction = ImeAction.Done,
    onDone: (() -> Unit)? = null
) {
    var passwordVisible by rememberSaveable { mutableStateOf(false) }
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        label = { Text(label) },
        enabled = enabled,
        singleLine = true,
        visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = imeAction),
        keyboardActions = KeyboardActions(onDone = { onDone?.invoke() }),
        trailingIcon = {
            TextButton(onClick = { passwordVisible = !passwordVisible }) {
                Text(if (passwordVisible) "隐藏" else "显示")
            }
        }
    )
}

@Composable
private fun LockedInheritedField(
    label: String,
    value: String,
    supportingText: String
) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.08f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.2f))
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = value,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
                fontWeight = FontWeight.Medium
            )
            Text(
                text = supportingText,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.secondary
            )
        }
    }
}

private data class RemoteFramePlacement(
    val drawSize: IntSize = IntSize.Zero,
    val offset: IntOffset = IntOffset.Zero,
    val frameSize: IntSize = IntSize.Zero,
    val viewerSize: IntSize = IntSize.Zero
) {
    fun toBaseViewerPoint(x: Float, y: Float, zoomState: ViewerZoomState): Pair<Float, Float> {
        if (!canUseZoomViewer(this) || zoomState.scale <= VIEWER_ZOOM_MIN_SCALE) {
            return x to y
        }
        val (centerX, centerY) = getViewerCenter(this)
        return (centerX + (x - centerX - zoomState.offsetX) / zoomState.scale) to
            (centerY + (y - centerY - zoomState.offsetY) / zoomState.scale)
    }

    fun mapToRemote(x: Float, y: Float, zoomState: ViewerZoomState): Pair<Int, Int>? {
        if (drawSize.width <= 0 || drawSize.height <= 0 || frameSize.width <= 0 || frameSize.height <= 0) {
            return null
        }
        val basePoint = toBaseViewerPoint(x, y, zoomState)
        val localX = basePoint.first - offset.x
        val localY = basePoint.second - offset.y
        if (localX < 0f || localY < 0f || localX > drawSize.width || localY > drawSize.height) {
            return null
        }
        val remoteX = ((localX / drawSize.width) * frameSize.width).toInt().coerceIn(0, frameSize.width - 1)
        val remoteY = ((localY / drawSize.height) * frameSize.height).toInt().coerceIn(0, frameSize.height - 1)
        return remoteX to remoteY
    }
}

private class ViewerInputState {
    var touchStartX: Float = 0f
    var touchStartY: Float = 0f
    var touchStartTs: Long = 0L
    var touchMoved: Boolean = false
    var touchDragging: Boolean = false
    var touchScrollActive: Boolean = false
    var touchScrollLastX: Float = 0f
    var touchScrollLastY: Float = 0f
    var touchScrollResidualY: Float = 0f
    var pinchActive: Boolean = false
    var pinchStartDistance: Float = 0f
    var pinchStartScale: Float = 1f
    var pinchAnchorBaseX: Float = 0f
    var pinchAnchorBaseY: Float = 0f
    var inspectTouchMoved: Boolean = false
    var lastInspectTapTs: Long = 0L
    var lastInspectTapX: Float = 0f
    var lastInspectTapY: Float = 0f
}

private data class ViewerZoomState(
    val scale: Float = 1f,
    val offsetX: Float = 0f,
    val offsetY: Float = 0f
)

private data class TextDelta(
    val deletedCount: Int,
    val insertedText: String
)

private const val VIEWER_ZOOM_MIN_SCALE = 1f
private const val VIEWER_ZOOM_MAX_SCALE = 4f
private const val VIEWER_ZOOM_STEP_SCALE = 0.25f
private const val VIEWER_INSPECT_MOVE_SLOP_PX = 8f
private const val VIEWER_INSPECT_DOUBLE_TAP_MS = 320L
private const val VIEWER_CHROME_AUTO_HIDE_MS = 2200L
private const val VIEWER_CHROME_INTERACTION_HIDE_MS = 3200L
private val VIEWER_CHROME_HANDLE_WIDTH = 18.dp
private val VIEWER_CHROME_HANDLE_HEIGHT = 72.dp
private val VIEWER_CHROME_PRIMARY = Color(0xFF2C4F54)
private val VIEWER_CHROME_PRIMARY_FG = Color.White
private val VIEWER_CHROME_SURFACE = Color(0xC70C1416)
private val VIEWER_CHROME_SURFACE_SOFT = Color(0x14000000)
private val VIEWER_CHROME_BORDER = Color.White.copy(alpha = 0.12f)

private fun String.toCodePointList(): List<Int> {
    val codePoints = ArrayList<Int>(length)
    var index = 0
    while (index < length) {
        val codePoint = codePointAt(index)
        codePoints.add(codePoint)
        index += Character.charCount(codePoint)
    }
    return codePoints
}

private fun buildTextDelta(previous: String, next: String): TextDelta {
    val previousChars = previous.toCodePointList()
    val nextChars = next.toCodePointList()

    var prefix = 0
    while (prefix < previousChars.size && prefix < nextChars.size && previousChars[prefix] == nextChars[prefix]) {
        prefix++
    }

    var suffix = 0
    while (
        suffix < previousChars.size - prefix &&
        suffix < nextChars.size - prefix &&
        previousChars[previousChars.size - 1 - suffix] == nextChars[nextChars.size - 1 - suffix]
    ) {
        suffix++
    }

    val insertedText = nextChars
        .subList(prefix, nextChars.size - suffix)
        .joinToString(separator = "") { String(Character.toChars(it)) }

    return TextDelta(
        deletedCount = previousChars.size - prefix - suffix,
        insertedText = insertedText
    )
}

private fun sendRemoteBackspace(session: ViewerSession, count: Int) {
    repeat(max(0, count)) {
        session.sendKey(0xff08, true)
        session.sendKey(0xff08, false)
    }
}

private fun sendCommittedText(session: ViewerSession, text: String) {
    var index = 0
    while (index < text.length) {
        val codePoint = text.codePointAt(index)
        val keysym = when {
            codePoint == '\n'.code -> 0xff0d
            codePoint in 0x20..0x7E -> codePoint
            codePoint in 0xA0..0xFF -> codePoint
            else -> 0x01000000 or codePoint
        }
        session.sendKey(keysym, true)
        session.sendKey(keysym, false)
        index += Character.charCount(codePoint)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TouchScrollStepSelector(
    selectedStep: Int,
    onSelect: (Int) -> Unit
) {
    val selectedPreset = resolveTouchScrollPreset(selectedStep)
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        touchScrollOptions.forEach { (value, label) ->
            val selected = selectedPreset == value
            if (selected) {
                Button(
                    onClick = { onSelect(value) },
                    shape = RoundedCornerShape(12.dp),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 0.dp)
                ) {
                    Text(label)
                }
            } else {
                OutlinedButton(
                    onClick = { onSelect(value) },
                    shape = RoundedCornerShape(12.dp),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 0.dp)
                ) {
                    Text(label)
                }
            }
        }
    }
}

private class ViewerSession(storageRoot: String) : AutoCloseable {
    private val fallbackFullFrameSyncMs = 500L
    private val monitorDetectionIntervalMs = 1500L
    private val emptyMonitorDetectionIntervalMs = 300L
    private val activeServerRefreshWindowMs = 15000L
    private val activeServerRefreshIntervalMs = 250L
    private val idleServerRefreshIntervalMs = 1000L

    init {
        VncClient.configureStorageRoot(storageRoot)
    }

    private val client = VncClient()
    private var lastFullFrameSyncTs = 0L
    private var lastMonitorDetectionTs = 0L
    private var lastMonitorDetectWidth = 0
    private var lastMonitorDetectHeight = 0
    private var connectedAtTs = 0L
    private var lastFramebufferUpdateTs = 0L
    private var lastServerRefreshRequestTs = 0L

    var connected by mutableStateOf(false)
        private set
    var connecting by mutableStateOf(false)
        private set
    var lastError by mutableStateOf("")
        private set
    var bitmap by mutableStateOf<Bitmap?>(null)
        private set
    var frameVersion by mutableIntStateOf(0)
        private set
    var securityLevel by mutableIntStateOf(0)
        private set
    var serverName by mutableStateOf("")
        private set
    var monitors by mutableStateOf<List<android.graphics.Rect>>(emptyList())
        private set
    var fallbackMonitors by mutableStateOf<List<android.graphics.Rect>?>(null)
        private set
    var isManualMonitorLayout by mutableStateOf(false)
        private set
    var currentMonitorRect by mutableStateOf<android.graphics.Rect?>(null)
        private set
    var lastPointerX by mutableIntStateOf(0)
        private set
    var lastPointerY by mutableIntStateOf(0)
        private set

    private inline fun <T> publishState(block: () -> T): T = Snapshot.withMutableSnapshot(block)

    fun setCurrentMonitor(rect: android.graphics.Rect?) {
        publishState {
            currentMonitorRect = rect
        }
    }

    fun setFallbackMonitors(rects: List<android.graphics.Rect>?, manual: Boolean) {
        publishState {
            fallbackMonitors = rects
            isManualMonitorLayout = manual
            if (rects != null && manual) {
                monitors = rects
            }
        }
    }

    suspend fun connect(hostPort: HostPort, user: String, password: String, ssh: SshConnectionConfig): Boolean {
        if (connecting) {
            return false
        }
        connecting = true
        lastError = ""
        serverName = ""
        return try {
            val normalizedSsh = normalizeSshConfigForAddress(ssh, "${hostPort.host}:${hostPort.port}")
            if (normalizedSsh.enabled) {
                val sshRc = withContext(Dispatchers.IO) {
                    client.setSshTunnel(normalizedSsh.toNativeConfig())
                }
                if (sshRc != 0) {
                    connected = false
                    lastError = client.getLastError().ifBlank { "SSH 隧道配置失败" }
                    return false
                }
            } else {
                client.clearSshTunnel()
            }
            val rc = withContext(Dispatchers.IO) {
                client.connect(hostPort.host, hostPort.port, user, password)
            }
            connected = rc == 0
            securityLevel = if (connected) client.getSecurityLevel() else 0
            lastError = client.getLastError()
            if (connected) {
                val now = System.currentTimeMillis()
                connectedAtTs = now
                lastFramebufferUpdateTs = now
                serverName = client.getServerName().trim()
                updateFrame(forceFull = true)
            }
            connected
        } catch (t: Throwable) {
            connected = false
            lastError = t.message ?: "连接失败"
            false
        } finally {
            connecting = false
        }
    }

    fun step(): Boolean {
        if (!connected) {
            return false
        }
        return try {
            val rc = client.process()
            if (rc != 0) {
                publishState {
                    lastError = client.getLastError().ifBlank { "连接已断开" }
                }
                disconnect()
                false
            } else {
                val nextSecurityLevel = client.getSecurityLevel()
                publishState {
                    securityLevel = nextSecurityLevel
                }
                val damage = client.consumeDamage()
                val now = System.currentTimeMillis()
                if (damage != null) {
                    lastFramebufferUpdateTs = now
                } else if (shouldRequestServerRefresh(now)) {
                    client.requestUpdate(incremental = true)
                    lastServerRefreshRequestTs = now
                }
                val needsFullSync = bitmap == null || (damage == null && now - lastFullFrameSyncTs >= fallbackFullFrameSyncMs)
                if (damage != null || needsFullSync) {
                    updateFrame(forceFull = needsFullSync)
                }
                true
            }
        } catch (t: Throwable) {
            publishState {
                lastError = t.message ?: client.getLastError().ifBlank { "连接已断开" }
            }
            disconnect()
            false
        }
    }

    fun sendPointer(x: Int, y: Int, mask: Int) {
        if (!connected) {
            return
        }
        lastPointerX = x
        lastPointerY = y
        client.sendPointer(x, y, mask)
    }

    fun sendClick(x: Int, y: Int, mask: Int) {
        sendPointer(x, y, mask)
        sendPointer(x, y, 0)
    }

    fun sendScroll(mask: Int) {
        sendPointer(lastPointerX, lastPointerY, mask)
        sendPointer(lastPointerX, lastPointerY, 0)
    }

    fun sendScrollAt(x: Int, y: Int, mask: Int, baseMask: Int = 0, repeatCount: Int = 1) {
        repeat(max(1, repeatCount)) {
            sendPointer(x, y, baseMask or mask)
            sendPointer(x, y, baseMask)
        }
    }

    fun sendKey(keysym: Int, down: Boolean) {
        if (connected && keysym != 0) {
            client.sendKey(keysym, down)
        }
    }

    fun sendText(text: String) {
        text.forEach { ch ->
            val keysym = ch.code
            sendKey(keysym, true)
            sendKey(keysym, false)
        }
    }

    fun pushClipboard(text: String) {
        if (connected) {
            client.setClipboardText(text)
        }
    }

    fun requestClipboard() {
        if (connected) {
            client.requestClipboard()
        }
    }

    fun takeRemoteClipboardText(): String {
        return if (connected && client.hasRemoteClipboardText()) {
            client.takeRemoteClipboardText()
        } else {
            ""
        }
    }

    fun disconnect() {
        try {
            client.disconnect()
        } catch (_: Throwable) {
        }
        try {
            client.clearSshTunnel()
        } catch (_: Throwable) {
        }
        publishState {
            connected = false
            connecting = false
            securityLevel = 0
            serverName = ""
        }
        lastFullFrameSyncTs = 0L
        lastMonitorDetectionTs = 0L
        lastMonitorDetectWidth = 0
        lastMonitorDetectHeight = 0
        connectedAtTs = 0L
        lastFramebufferUpdateTs = 0L
        lastServerRefreshRequestTs = 0L
        publishState {
            bitmap?.recycle()
            bitmap = null
            frameVersion += 1
        }
    }

    override fun close() {
        disconnect()
        try {
            client.close()
        } catch (_: Throwable) {
        }
        bitmap?.recycle()
        bitmap = null
}

    private fun rectListsEqual(a: List<android.graphics.Rect>, b: List<android.graphics.Rect>): Boolean {
        if (a.size != b.size) {
            return false
        }
        return a.indices.all { index -> a[index] == b[index] }
    }

    private fun shouldRequestServerRefresh(now: Long): Boolean {
        if (!connected) {
            return false
        }
        val refreshInterval = if (connectedAtTs != 0L && now - connectedAtTs <= activeServerRefreshWindowMs) {
            activeServerRefreshIntervalMs
        } else {
            idleServerRefreshIntervalMs
        }
        val sinceLastUpdate = now - lastFramebufferUpdateTs
        val sinceLastRequest = now - lastServerRefreshRequestTs
        return sinceLastUpdate >= refreshInterval && sinceLastRequest >= refreshInterval
    }

    private fun maybeRefreshMonitors(info: FramebufferInfo, forceFull: Boolean, now: Long) {
        if (!connected) {
            return
        }

        val nextSecurityLevel = client.getSecurityLevel()
        val nextServerName = client.getServerName().trim()
        val fallback = fallbackMonitors?.toTypedArray()
        if (isManualMonitorLayout && fallback != null) {
            publishState {
                securityLevel = nextSecurityLevel
                if (serverName.isBlank()) {
                    serverName = nextServerName
                }
                val manualRects = fallback.toList()
                if (!rectListsEqual(monitors, manualRects)) {
                    monitors = manualRects
                }
            }
            return
        }

        val framebufferChanged = info.width != lastMonitorDetectWidth || info.height != lastMonitorDetectHeight
        val shouldDetect = framebufferChanged ||
            monitors.isEmpty() ||
            (forceFull && now - lastMonitorDetectionTs >= monitorDetectionIntervalMs) ||
            (monitors.isEmpty() && now - lastMonitorDetectionTs >= emptyMonitorDetectionIntervalMs)

        publishState {
            securityLevel = nextSecurityLevel
            if (serverName.isBlank()) {
                serverName = nextServerName
            }
        }

        if (!shouldDetect) {
            return
        }

        val nextMonitors = client.detectMonitors(fallback).toList()
        lastMonitorDetectionTs = now
        lastMonitorDetectWidth = info.width
        lastMonitorDetectHeight = info.height
        publishState {
            if (!rectListsEqual(monitors, nextMonitors)) {
                monitors = nextMonitors
            }
        }
    }

    private fun updateFrame(forceFull: Boolean = false) {
        val info = client.getFramebufferInfo()
        maybeRefreshMonitors(info, forceFull, System.currentTimeMillis())
        if (info.width <= 0 || info.height <= 0) {
            return
        }
        val target = publishState {
            if (bitmap?.width == info.width && bitmap?.height == info.height) {
                bitmap
            } else {
                bitmap?.recycle()
                Bitmap.createBitmap(info.width, info.height, Bitmap.Config.ARGB_8888).also {
                    bitmap = it
                }
            }
        } ?: return

        if (!client.blitFrameToBitmap(target)) {
            return
        }
        val now = System.currentTimeMillis()
        lastFullFrameSyncTs = now
        lastFramebufferUpdateTs = now
        publishState {
            frameVersion += 1
        }
    }
}

class MainActivity : ComponentActivity() {
    private var launchIntent by mutableStateOf<Intent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        launchIntent = intent
        setContent {
            GreenTigerTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.surface
                ) {
                    GreenTigerApp(launchIntent = launchIntent)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        launchIntent = intent
    }
}

@Composable
fun FloatingNavButton(text: String, onClick: () -> Unit) {
    Surface(
        modifier = Modifier.size(44.dp),
        shape = androidx.compose.foundation.shape.CircleShape,
        color = Color.Black.copy(alpha = 0.5f),
        onClick = onClick
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(text, color = Color.White, fontWeight = FontWeight.Bold)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun GreenTigerApp(launchIntent: Intent?) {
    val context = LocalContext.current
    val activity = context as? Activity
    val clipboardManager = LocalClipboardManager.current
    val repository = remember(context) { ConnectionsRepository(context) }
    val viewerLaunchArgs = remember(launchIntent) { launchIntent?.toViewerLaunchArgs() }
    val isViewerWindow = viewerLaunchArgs != null
    val privacyPolicyDocument = remember(context) {
        AgreementDocument(
            type = AgreementType.PrivacyPolicy,
            title = "翠虎远程桌面隐私协议",
            assetName = PRIVACY_POLICY_ASSET_NAME,
            contentDescription = "隐私协议全文"
        )
    }
    val userAgreementDocument = remember(context) {
        AgreementDocument(
            type = AgreementType.UserAgreement,
            title = "翠虎远程桌面用户协议",
            assetName = USER_AGREEMENT_ASSET_NAME,
            contentDescription = "用户协议全文"
        )
    }
    val privacyPolicyText = remember(context) {
        loadBundledTextAsset(context, privacyPolicyDocument.assetName, privacyPolicyDocument.title)
    }
    val userAgreementText = remember(context) {
        loadBundledTextAsset(context, userAgreementDocument.assetName, userAgreementDocument.title)
    }
    val viewerSession = remember(context) {
        ViewerSession(context.filesDir.resolve("tigervnc").absolutePath)
    }
    val showToast: (String) -> Unit = remember(context) {
        { message ->
            Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            viewerSession.close()
        }
    }

    var connections by remember { mutableStateOf(repository.loadConnections()) }
    val storedSelectedId = remember { repository.loadSelectedConnectionId() }
    val initialSelectedId = connections.firstOrNull { it.id == storedSelectedId }?.id ?: connections.firstOrNull()?.id.orEmpty()

    var selectedConnectionId by rememberSaveable { mutableStateOf(initialSelectedId) }
    var connName by rememberSaveable {
        mutableStateOf(viewerLaunchArgs?.connName ?: connections.firstOrNull { it.id == initialSelectedId }?.name.orEmpty())
    }
    var address by rememberSaveable {
        mutableStateOf(viewerLaunchArgs?.address ?: connections.firstOrNull { it.id == initialSelectedId }?.address ?: "127.0.0.1:5900")
    }
    var user by rememberSaveable {
        mutableStateOf(viewerLaunchArgs?.user ?: connections.firstOrNull { it.id == initialSelectedId }?.user.orEmpty())
    }
    var password by rememberSaveable {
        mutableStateOf(viewerLaunchArgs?.password ?: connections.firstOrNull { it.id == initialSelectedId }?.password.orEmpty())
    }
    var storePassword by rememberSaveable {
        mutableStateOf(
            if (viewerLaunchArgs != null) {
                viewerLaunchArgs.password.isNotBlank()
            } else {
                connections.firstOrNull { it.id == initialSelectedId }?.storePassword ?: true
            }
        )
    }
    var touchScrollStep by rememberSaveable {
        mutableIntStateOf(viewerLaunchArgs?.touchScrollStep ?: connections.firstOrNull { it.id == initialSelectedId }?.touchScrollStep ?: 0)
    }
    var sshConfig by remember {
        mutableStateOf(viewerLaunchArgs?.ssh ?: connections.firstOrNull { it.id == initialSelectedId }?.ssh ?: SshConnectionConfig())
    }
    var currentScreen by rememberSaveable { mutableStateOf(if (isViewerWindow) AppScreen.Viewer else AppScreen.Home) }
    var editState by remember { mutableStateOf<EditConnectionState?>(null) }
    var searchKeyword by rememberSaveable { mutableStateOf("") }
    var pendingDeleteConnection by remember { mutableStateOf<ConnectionItem?>(null) }
    var pendingPasswordPrompt by remember { mutableStateOf<ConnectionPasswordPromptState?>(null) }
    var sendTextDialog by remember { mutableStateOf(false) }
    var showAboutDialog by rememberSaveable { mutableStateOf(false) }
    var activeAgreementDialog by rememberSaveable { mutableStateOf<AgreementType?>(null) }
    var launchAgreementsAccepted by rememberSaveable { mutableStateOf(repository.hasAcceptedLaunchAgreements()) }
    var pendingText by rememberSaveable { mutableStateOf("") }
    var autoConnectAttempted by rememberSaveable { mutableStateOf(false) }
    var didAdoptServerName by rememberSaveable { mutableStateOf(false) }
    val appTitle = remember(context) { context.getString(R.string.app_name) }

    fun persistConnections(nextConnections: List<ConnectionItem>, selectedId: String = selectedConnectionId) {
        val safePassword = if (storePassword) password else ""
        repository.saveConnections(nextConnections, selectedId, address, user, safePassword)
    }

    fun applyConnection(item: ConnectionItem?) {
        if (item == null) {
            return
        }
        selectedConnectionId = item.id
        connName = item.name
        address = item.address
        user = item.user
        password = item.password
        storePassword = item.storePassword
        touchScrollStep = normalizeTouchScrollStep(item.touchScrollStep)
        sshConfig = normalizeSshConfigForAddress(item.ssh, item.address)
    }

    fun selectConnection(id: String) {
        connections.firstOrNull { it.id == id }?.let { item ->
            applyConnection(item)
            persistConnections(connections, item.id)
        }
    }

    fun upsertSelectedConnection(markUsed: Boolean) {
        val parsed = parseAddress(address)
        if (parsed == null) {
            showToast("地址格式不正确，例如 192.168.1.2:5900 或 [::1]:5900")
            return
        }
        val now = System.currentTimeMillis()
        val id = selectedConnectionId.ifBlank { generateConnectionId() }
        val updated = createConnectionItem(
            id = id,
            name = connName,
            address = address,
            user = user,
            password = password,
            storePassword = storePassword,
            touchScrollStep = touchScrollStep,
            ssh = sshConfig,
            lastUsedAt = if (markUsed) now else connections.firstOrNull { it.id == id }?.lastUsedAt ?: now
        )
        connections = (connections.filterNot { it.id == id } + updated).sortedByDescending { it.lastUsedAt }
        applyConnection(updated)
        persistConnections(connections, updated.id)
        if (!markUsed) {
            showToast("已保存")
        }
    }

    fun launchConnection(item: ConnectionItem, runtimePassword: String, shouldStorePassword: Boolean) {
        val parsed = parseAddress(item.address)
        if (parsed == null) {
            showToast("地址格式不正确，例如 192.168.1.2:5900 或 [::1]:5900")
            return
        }
        val updated = createConnectionItem(
            id = item.id,
            name = item.name,
            address = item.address,
            user = item.user,
            password = runtimePassword,
            storePassword = shouldStorePassword,
            touchScrollStep = item.touchScrollStep,
            ssh = item.ssh,
            lastUsedAt = System.currentTimeMillis()
        )
        val effectiveSsh = resolveSshConfigForConnection(
            updated.ssh,
            updated.address,
            updated.user,
            runtimePassword
        )
        connections = (connections.filterNot { existing -> existing.id == updated.id } + updated)
            .sortedByDescending { connection -> connection.lastUsedAt }
        applyConnection(updated)
        persistConnections(connections, updated.id)
        pendingPasswordPrompt = null
        activity?.startActivity(
            createViewerIntent(
                context,
                ViewerLaunchArgs(
                    connName = updated.name,
                    address = updated.address,
                    user = updated.user,
                    password = runtimePassword,
                    touchScrollStep = updated.touchScrollStep,
                    ssh = effectiveSsh
                )
            )
        )
    }

    fun openConnection(item: ConnectionItem) {
        if (!item.storePassword || item.password.isBlank()) {
            pendingPasswordPrompt = ConnectionPasswordPromptState(
                connection = item.normalized(),
                storePassword = item.storePassword
            )
            return
        }
        launchConnection(item, item.password, true)
    }

    fun deleteConnection(item: ConnectionItem) {
        val next = connections.filterNot { it.id == item.id }
        connections = next
        val nextSelected = when {
            next.isEmpty() -> ""
            item.id != selectedConnectionId && next.any { it.id == selectedConnectionId } -> selectedConnectionId
            else -> next.firstOrNull()?.id.orEmpty()
        }
        selectedConnectionId = nextSelected
        next.firstOrNull { it.id == nextSelected }?.let(::applyConnection)
        if (next.isEmpty()) {
            connName = ""
            address = "127.0.0.1:5900"
            user = ""
            password = ""
            storePassword = false
            touchScrollStep = 0
            sshConfig = SshConnectionConfig()
        }
        persistConnections(next, nextSelected)
        showToast("已删除")
    }

    if (editState != null) {
        EditConnectionDialog(
            state = editState!!,
            onStateChange = { editState = it },
            onDismiss = { editState = null },
            onSave = {
                val parsed = parseAddress(it.address)
                if (parsed == null) {
                    showToast("地址格式不正确，例如 192.168.1.2:5900 或 [::1]:5900")
                    return@EditConnectionDialog
                }
                val now = System.currentTimeMillis()
                val normalizedSsh = normalizeEditSshConfig(it.ssh, it.address.trim())
                val persistedSsh = normalizedSsh.copy(
                    sshUser = if (normalizedSsh.reuseDesktopUser) it.user.trim() else normalizedSsh.sshUser,
                    sshPassword = if (
                        normalizedSsh.authType == SSH_AUTH_PASSWORD &&
                        normalizedSsh.reuseDesktopPassword
                    ) {
                        it.password
                    } else {
                        normalizedSsh.sshPassword
                    }
                )
                val effectiveSsh = resolveSshConfigForConnection(
                    persistedSsh,
                    it.address.trim(),
                    it.user,
                    it.password
                )
                val sshError = validateSshConfig(effectiveSsh)
                if (sshError != null) {
                    showToast(sshError)
                    return@EditConnectionDialog
                }
                val updated = createConnectionItem(
                    id = it.id.ifBlank { generateConnectionId() },
                    name = it.name,
                    address = it.address,
                    user = it.user,
                    password = it.password,
                    storePassword = it.storePassword,
                    touchScrollStep = it.touchScrollStep,
                    ssh = persistedSsh,
                    lastUsedAt = connections.firstOrNull { existing -> existing.id == it.id }?.lastUsedAt ?: now
                )
                connections = (connections.filterNot { existing -> existing.id == updated.id } + updated)
                    .sortedByDescending { item -> item.lastUsedAt }
                applyConnection(updated)
                persistConnections(connections, updated.id)
                editState = null
                showToast("已保存")
            }
        )
    }

    if (pendingDeleteConnection != null) {
        val deleting = pendingDeleteConnection!!
        AlertDialog(
            onDismissRequest = { pendingDeleteConnection = null },
            title = { Text("删除连接") },
            text = { Text("确认删除“${normalizeConnName(deleting.name, deleting.address)}”？") },
            confirmButton = {
                TextButton(
                    onClick = {
                        deleteConnection(deleting)
                        pendingDeleteConnection = null
                    }
                ) {
                    Text("删除")
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDeleteConnection = null }) {
                    Text("取消")
                }
            }
        )
    }

    if (pendingPasswordPrompt != null) {
        val prompt = pendingPasswordPrompt!!
        AlertDialog(
            onDismissRequest = { pendingPasswordPrompt = null },
            title = { Text("输入连接密码") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("“${normalizeConnName(prompt.connection.name, prompt.connection.address)}”未保存密码，输入后再发起连接。")
                    PasswordField(
                        value = prompt.password,
                        onValueChange = { pendingPasswordPrompt = prompt.copy(password = it) },
                        modifier = Modifier.fillMaxWidth(),
                        imeAction = ImeAction.Done,
                        onDone = {
                            if (prompt.password.isBlank()) {
                                showToast("请输入密码")
                            } else {
                                launchConnection(prompt.connection, prompt.password, prompt.storePassword)
                            }
                        }
                    )
                    FilterChip(
                        selected = prompt.storePassword,
                        onClick = {
                            pendingPasswordPrompt = prompt.copy(storePassword = !prompt.storePassword)
                        },
                        label = { Text(if (prompt.storePassword) "保存密码：开" else "保存密码：关") }
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        if (prompt.password.isBlank()) {
                            showToast("请输入密码")
                        } else {
                            launchConnection(prompt.connection, prompt.password, prompt.storePassword)
                        }
                    }
                ) {
                    Text("连接")
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingPasswordPrompt = null }) {
                    Text("取消")
                }
            }
        )
    }

    if (sendTextDialog) {
        AlertDialog(
            onDismissRequest = { sendTextDialog = false },
            title = { Text("发送文本") },
            text = {
                OutlinedTextField(
                    value = pendingText,
                    onValueChange = { pendingText = it },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 4
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewerSession.sendText(pendingText)
                        pendingText = ""
                        sendTextDialog = false
                    }
                ) {
                    Text("发送")
                }
            },
            dismissButton = {
                TextButton(onClick = { sendTextDialog = false }) {
                    Text("取消")
                }
            }
        )
    }

    androidx.compose.runtime.LaunchedEffect(viewerLaunchArgs, currentScreen, launchAgreementsAccepted) {
        if (!launchAgreementsAccepted || !isViewerWindow || currentScreen != AppScreen.Viewer || autoConnectAttempted) {
            return@LaunchedEffect
        }
        autoConnectAttempted = true
        val args = viewerLaunchArgs ?: return@LaunchedEffect
        val parsed = args.hostPort
        if (parsed == null) {
            showToast("地址格式不正确，例如 192.168.1.2:5900 或 [::1]:5900")
            activity?.finish()
            return@LaunchedEffect
        }
        if (!viewerSession.connected && !viewerSession.connecting) {
            val success = viewerSession.connect(parsed, args.user.trim(), args.password, args.ssh)
            if (!success && isActive) {
                withContext(Dispatchers.Main) {
                    showToast(viewerSession.lastError.ifBlank { "连接失败" })
                    activity?.finish()
                }
            }
        }
    }

    androidx.compose.runtime.LaunchedEffect(viewerSession.connected, address) {
        if (!viewerSession.connected) {
            didAdoptServerName = false
        }
    }

    androidx.compose.runtime.LaunchedEffect(viewerSession.connected, viewerSession.serverName, connName, selectedConnectionId) {
        if (!viewerSession.connected || didAdoptServerName) {
            return@LaunchedEffect
        }
        if (connName.trim().isNotEmpty()) {
            didAdoptServerName = true
            return@LaunchedEffect
        }
        val name = viewerSession.serverName.trim()
        if (name.isEmpty()) {
            return@LaunchedEffect
        }

        val selectedId = selectedConnectionId.trim()
        var changed = false
        val nextConnections = connections.map { item ->
            if (selectedId.isNotEmpty() && item.id == selectedId && item.name.isBlank()) {
                changed = true
                item.copy(name = name)
            } else {
                item
            }
        }

        connName = name
        didAdoptServerName = true
        if (changed) {
            connections = nextConnections
            persistConnections(nextConnections, selectedId)
        }
    }

    androidx.compose.runtime.SideEffect {
        val label = if (currentScreen == AppScreen.Viewer) {
            val title = normalizeConnName(connName, address).ifBlank { address.ifBlank { appTitle } }
            buildViewerWindowLabel(title, resolveViewerHostTarget(address, sshConfig))
        } else {
            appTitle
        }
        applyTaskLabel(activity, label)
    }

    when (currentScreen) {
        AppScreen.Home -> HomeScreen(
            connections = connections,
            selectedConnectionId = selectedConnectionId,
            keyword = searchKeyword,
            connecting = viewerSession.connecting,
            onKeywordChange = { searchKeyword = it },
            onClearKeyword = { searchKeyword = "" },
            onSelectConnection = ::selectConnection,
            onCreateConnection = {
                editState = EditConnectionState(
                    address = "",
                    user = "",
                    password = "",
                    storePassword = true,
                    touchScrollStep = 0,
                    ssh = normalizeEditSshConfig(null, "")
                )
            },
            onEditConnection = { item ->
                editState = EditConnectionState(
                    id = item.id,
                    name = item.name,
                    address = item.address,
                    user = item.user,
                    password = item.password,
                    storePassword = item.storePassword,
                    touchScrollStep = normalizeTouchScrollStep(item.touchScrollStep),
                    ssh = normalizeEditSshConfig(item.ssh, item.address)
                )
            },
            onRequestDeleteConnection = { pendingDeleteConnection = it },
            onAbout = { showAboutDialog = true },
            onConnectConnection = ::openConnection
        )

        AppScreen.Viewer -> ViewerScreen(
            session = viewerSession,
            repository = repository,
            connId = selectedConnectionId,
            connName = connName,
            address = address,
            ssh = sshConfig,
            touchScrollStep = touchScrollStep,
            onBack = {
                viewerSession.disconnect()
                if (isViewerWindow) {
                    activity?.finish()
                } else {
                    currentScreen = AppScreen.Home
                }
            },
            onShowToast = showToast,
            onOpenSendText = { sendTextDialog = true },
            onPushLocalClipboard = {
                val localText = clipboardManager.getText()?.text.orEmpty()
                if (localText.isBlank()) {
                    showToast("本地剪贴板为空")
                } else {
                    viewerSession.pushClipboard(localText)
                    showToast("已同步到远端剪贴板")
                }
            },
            onPullRemoteClipboard = {
                viewerSession.requestClipboard()
                showToast("已请求远端剪贴板")
            },
            onRemoteClipboard = { text ->
                clipboardManager.setText(AnnotatedString(text))
                showToast("已同步远端剪贴板")
            }
        )
    }

    if (showAboutDialog) {
        AboutDialog(
            onDismiss = { showAboutDialog = false },
            onShowPrivacyPolicy = { activeAgreementDialog = AgreementType.PrivacyPolicy },
            onShowUserAgreement = { activeAgreementDialog = AgreementType.UserAgreement }
        )
    }

    when (activeAgreementDialog) {
        AgreementType.PrivacyPolicy -> {
            AgreementDocumentDialog(
                title = privacyPolicyDocument.title,
                helperText = "您可随时在“关于 -> 协议与隐私”中再次查看本协议。",
                markdownText = privacyPolicyText,
                onDismiss = { activeAgreementDialog = null }
            )
        }
        AgreementType.UserAgreement -> {
            AgreementDocumentDialog(
                title = userAgreementDocument.title,
                helperText = "您可随时在“关于 -> 协议与隐私”中再次查看本协议。",
                markdownText = userAgreementText,
                onDismiss = { activeAgreementDialog = null }
            )
        }
        null -> Unit
    }

    if (!launchAgreementsAccepted) {
        AgreementsConsentDialog(
            privacyPolicyText = privacyPolicyText,
            userAgreementText = userAgreementText,
            onAgree = {
                repository.setLaunchAgreementsAccepted(true)
                launchAgreementsAccepted = true
            },
            onExit = { activity?.finish() }
        )
    }
}

@Composable
private fun HomeScreen(
    connections: List<ConnectionItem>,
    selectedConnectionId: String,
    keyword: String,
    connecting: Boolean,
    onKeywordChange: (String) -> Unit,
    onClearKeyword: () -> Unit,
    onSelectConnection: (String) -> Unit,
    onCreateConnection: () -> Unit,
    onEditConnection: (ConnectionItem) -> Unit,
    onRequestDeleteConnection: (ConnectionItem) -> Unit,
    onAbout: () -> Unit,
    onConnectConnection: (ConnectionItem) -> Unit
) {
    val selectedConnection = connections.firstOrNull { it.id == selectedConnectionId }
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 16.dp)
            .background(MaterialTheme.colorScheme.surface)
    ) {
        val wide = maxWidth >= 920.dp
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("连接管理", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                }
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("v${BuildConfig.BUILD_VERSION}", color = MaterialTheme.colorScheme.secondary)
                    TextButton(onClick = onAbout) {
                        Text("关于")
                    }
                }
            }
            if (wide) {
                Row(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(top = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    ConnectionListPane(
                        modifier = Modifier
                            .weight(1.2f)
                            .fillMaxHeight(),
                        scrollable = true,
                        connections = connections,
                        selectedConnectionId = selectedConnectionId,
                        keyword = keyword,
                        connecting = connecting,
                        onKeywordChange = onKeywordChange,
                        onClearKeyword = onClearKeyword,
                        onSelectConnection = onSelectConnection,
                        onCreateConnection = onCreateConnection,
                        onOpenConnection = onConnectConnection,
                        onEditConnection = onEditConnection,
                        onDeleteConnection = onRequestDeleteConnection
                    )
                    SelectedConnectionPane(
                        modifier = Modifier
                            .weight(0.88f)
                            .fillMaxHeight(),
                        connection = selectedConnection?.takeIf { matchesConnectionKeyword(it, keyword) || keyword.isBlank() },
                        hasConnections = connections.isNotEmpty(),
                        keyword = keyword
                    )
                }
            } else {
                ConnectionListPane(
                    modifier = Modifier
                        .padding(top = 16.dp)
                        .fillMaxSize(),
                    scrollable = true,
                    connections = connections,
                    selectedConnectionId = selectedConnectionId,
                    keyword = keyword,
                    connecting = connecting,
                    onKeywordChange = onKeywordChange,
                    onClearKeyword = onClearKeyword,
                    onSelectConnection = onSelectConnection,
                    onCreateConnection = onCreateConnection,
                    onOpenConnection = onConnectConnection,
                    onEditConnection = onEditConnection,
                    onDeleteConnection = onRequestDeleteConnection
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SelectedConnectionPane(
    modifier: Modifier,
    connection: ConnectionItem?,
    hasConnections: Boolean,
    keyword: String
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(24.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text("当前选中", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            when {
                !hasConnections -> {
                    EmptyStateCard("暂无连接配置", "先新增一个连接，之后就可以在这里查看详情和快捷操作。")
                }
                connection == null && keyword.isNotBlank() -> {
                    EmptyStateCard("当前搜索结果中没有选中项", "请从左侧结果中选择一个连接，或清除搜索关键词。")
                }
                connection == null -> {
                    EmptyStateCard("请选择一个连接", "从左侧列表中选择连接后，这里会显示详情和快捷操作。")
                }
                else -> {
                    val presentation = connection.presentation()
                    Text(
                        text = normalizeConnName(connection.name, connection.address),
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold
                    )
                    ConnectionPathPreview(presentation = presentation)
                    ConnectionDetailLine("连接方式", presentation.routeLabel)
                    ConnectionDetailLine("VNC 目标", presentation.vncTarget)
                    if (presentation.usesSsh) {
                        ConnectionDetailLine("SSH 服务器", presentation.sshServer)
                    }
                    ConnectionDetailLine("VNC 账号", connection.user.ifBlank { "未填写" })
                    ConnectionDetailLine("密码保存", if (connection.storePassword) "已开启" else "未开启")
                    ConnectionDetailLine("触控滚动步长", touchScrollLabel(connection.touchScrollStep))
                    ConnectionDetailLine("最近使用", formatLastUsed(connection.lastUsedAt))
                    Spacer(modifier = Modifier.height(8.dp))
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ConnectionListPane(
    modifier: Modifier,
    scrollable: Boolean,
    connections: List<ConnectionItem>,
    selectedConnectionId: String,
    keyword: String,
    connecting: Boolean,
    onKeywordChange: (String) -> Unit,
    onClearKeyword: () -> Unit,
    onSelectConnection: (String) -> Unit,
    onCreateConnection: () -> Unit,
    onOpenConnection: (ConnectionItem) -> Unit,
    onEditConnection: (ConnectionItem) -> Unit,
    onDeleteConnection: (ConnectionItem) -> Unit
) {
    val filteredConnections = remember(connections, keyword) {
        connections.filter { matchesConnectionKeyword(it, keyword) }
    }
    val focusRequester = remember { FocusRequester() }
    var searchFieldFocused by remember { mutableStateOf(false) }
    Card(
        modifier = modifier
            .focusRequester(focusRequester)
            .focusable()
            .onPreviewKeyEvent { event ->
                handleConnectionManagerKeyEvent(
                    event = event,
                    shortcutsEnabled = !searchFieldFocused,
                    filteredConnections = filteredConnections,
                    selectedConnectionId = selectedConnectionId,
                    onSelectConnection = onSelectConnection,
                    onOpenConnection = onOpenConnection,
                    onDeleteConnection = onDeleteConnection
                )
            },
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.22f)),
        shape = RoundedCornerShape(24.dp)
    ) {
        androidx.compose.runtime.LaunchedEffect(Unit) {
            focusRequester.requestFocus()
        }
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("已保存连接", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text("按最近使用排序，支持搜索、打开、编辑和删除。", color = MaterialTheme.colorScheme.secondary)
                }
                Button(
                    onClick = onCreateConnection,
                    modifier = Modifier
                        .semantics { contentDescription = "新增连接" },
                    shape = RoundedCornerShape(14.dp)
                ) {
                    Text("新增连接")
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = keyword,
                    onValueChange = onKeywordChange,
                    modifier = Modifier
                        .weight(1f)
                        .onFocusChanged { focusState ->
                            searchFieldFocused = focusState.isFocused
                        },
                    label = { Text("搜索连接") },
                    placeholder = { Text("搜索：名称 / 地址 / 账号") },
                    singleLine = true
                )
                if (keyword.isNotBlank()) {
                    OutlinedButton(onClick = onClearKeyword) {
                        Text("清除")
                    }
                }
            }
            if (connections.isEmpty()) {
                EmptyStateCard(
                    title = "暂无连接配置",
                    message = "新增一个连接后，就可以从这里直接打开远程桌面。",
                    actionLabel = "新增连接",
                    onAction = onCreateConnection
                )
            } else if (filteredConnections.isEmpty()) {
                EmptyStateCard("未找到匹配的连接", "试试搜索名称、地址或账号，或清除当前关键词。")
            } else {
                Column(
                    modifier = if (scrollable) {
                        Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .verticalScroll(rememberScrollState())
                    } else {
                        Modifier.fillMaxWidth()
                    },
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    filteredConnections.forEach { item ->
                        val selected = item.id == selectedConnectionId
                        val presentation = item.presentation()
                        var isFocused by remember { mutableStateOf(false) }
                        Card(
                            modifier = Modifier
                                .fillMaxWidth()
                                .onFocusChanged { isFocused = it.isFocused }
                                .focusable()
                                .border(
                                    width = if (isFocused) 2.dp else if (selected) 1.5.dp else 1.dp,
                                    color = if (isFocused) MaterialTheme.colorScheme.primary else if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.6f) else MaterialTheme.colorScheme.outline,
                                    shape = RoundedCornerShape(20.dp)
                                ),
                            onClick = { onSelectConnection(item.id) },
                            colors = CardDefaults.cardColors(
                                containerColor = if (isFocused) {
                                    MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.15f)
                                } else if (selected) {
                                    MaterialTheme.colorScheme.primary.copy(alpha = 0.08f)
                                } else {
                                    MaterialTheme.colorScheme.surface
                                }
                            )
                        ) {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        text = normalizeConnName(item.name, item.address),
                                        modifier = Modifier.weight(1f),
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                    ConnectionRouteBadge(presentation.routeLabel)
                                }
                                Text(
                                    text = presentation.pathSummary,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.primary
                                )
                                Text("VNC：${presentation.vncTarget}", color = MaterialTheme.colorScheme.secondary)
                                if (presentation.usesSsh) {
                                    Text("SSH：${presentation.sshServer}", color = MaterialTheme.colorScheme.secondary)
                                }
                                if (item.user.isNotBlank()) {
                                    Text("VNC 账号：${item.user}", color = MaterialTheme.colorScheme.secondary)
                                }
                                Text(
                                    formatLastUsed(item.lastUsedAt),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.secondary
                                )
                                FlowRow(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Button(
                                        enabled = !connecting,
                                        onClick = { onOpenConnection(item) }
                                    ) {
                                        Text(if (connecting && selected) "连接中..." else "打开连接")
                                    }
                                    OutlinedButton(onClick = { onEditConnection(item) }) {
                                        Text("编辑")
                                    }
                                    OutlinedButton(onClick = { onDeleteConnection(item) }) {
                                        Text("删除")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ConnectionDetailLine(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.secondary)
        Text(value, style = MaterialTheme.typography.bodyLarge)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ConnectionFormPane(
    modifier: Modifier,
    scrollable: Boolean,
    connName: String,
    address: String,
    user: String,
    password: String,
    storePassword: Boolean,
    touchScrollStep: Int,
    connecting: Boolean,
    onConnNameChange: (String) -> Unit,
    onAddressChange: (String) -> Unit,
    onUserChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onStorePasswordChange: (Boolean) -> Unit,
    onTouchScrollStepChange: (Int) -> Unit,
    onSaveConnection: () -> Unit,
    onAbout: () -> Unit,
    onConnect: () -> Unit
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(28.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .then(if (scrollable) Modifier.verticalScroll(rememberScrollState()) else Modifier)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                Column(
                    modifier = Modifier.weight(1f).padding(end = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text("翠虎远程桌面", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    Text("填写地址后即可连接远程桌面，常用连接可保存后重复使用。", color = MaterialTheme.colorScheme.secondary)
                }
                TextButton(onClick = onAbout) {
                    Text("关于")
                }
            }
            OutlinedTextField(
                value = connName,
                onValueChange = onConnNameChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("连接名称（可选）") }
            )
            OutlinedTextField(
                value = address,
                onValueChange = onAddressChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("地址") },
                placeholder = { Text("192.168.1.2:5900") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next)
            )
            OutlinedTextField(
                value = user,
                onValueChange = onUserChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("用户名（可选）") },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next)
            )
            PasswordField(
                value = password,
                onValueChange = onPasswordChange,
                modifier = Modifier.fillMaxWidth(),
                imeAction = ImeAction.Done,
                onDone = onConnect
            )
            FilterChip(
                selected = storePassword,
                onClick = { onStorePasswordChange(!storePassword) },
                label = { Text(if (storePassword) "保存密码：开" else "保存密码：关") }
            )
            androidx.compose.material3.HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
            Text("高级配置", style = MaterialTheme.typography.titleMedium)
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("触控滚动步长", style = MaterialTheme.typography.titleSmall)
                TouchScrollStepSelector(
                    selectedStep = touchScrollStep,
                    onSelect = { onTouchScrollStepChange(normalizeTouchScrollStep(it)) }
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(
                    modifier = Modifier.weight(1f),
                    onClick = onSaveConnection
                ) {
                    Text("保存")
                }
                Button(
                    modifier = Modifier.weight(1f),
                    enabled = !connecting,
                    onClick = onConnect
                ) {
                    Text(if (connecting) "连接中..." else "连接")
                }
            }
        }
    }
}

@Composable
@OptIn(ExperimentalComposeUiApi::class)
private fun ViewerScreen(
    session: ViewerSession,
    repository: ConnectionsRepository,
    connId: String,
    connName: String,
    address: String,
    ssh: SshConnectionConfig,
    touchScrollStep: Int,
    onBack: () -> Unit,
    onShowToast: (String) -> Unit,
    onOpenSendText: () -> Unit,
    onPushLocalClipboard: () -> Unit,
    onPullRemoteClipboard: () -> Unit,
    onRemoteClipboard: (String) -> Unit
) {
    val context = LocalContext.current
    val activity = context as? Activity
    val view = LocalView.current
    val focusRequester = remember { FocusRequester() }
    val softInputFocusRequester = remember { FocusRequester() }
    val softwareKeyboardController = LocalSoftwareKeyboardController.current
    val inputMethodManager = remember(context) { context.getSystemService(InputMethodManager::class.java) }
    val inputState = remember { ViewerInputState() }
    val density = LocalDensity.current
    var softInputFieldValue by rememberSaveable(stateSaver = androidx.compose.ui.text.input.TextFieldValue.Saver) { 
        mutableStateOf(androidx.compose.ui.text.input.TextFieldValue(" ", selection = androidx.compose.ui.text.TextRange(1))) 
    }
    var softInputCommittedText by rememberSaveable { mutableStateOf(" ") }
    var viewerSize by remember { mutableStateOf(IntSize.Zero) }
    var showControls by rememberSaveable { mutableStateOf(false) }
    var showDisplaySheet by rememberSaveable { mutableStateOf(false) }
    var showSessionList by rememberSaveable { mutableStateOf(false) }
    var openWindows by remember { mutableStateOf(emptyList<OpenViewerWindow>()) }
    var fullscreen by rememberSaveable { mutableStateOf(false) }
    var chromeVisible by rememberSaveable { mutableStateOf(false) }
    var chromeHovering by remember { mutableStateOf(false) }
    var chromeHideNonce by rememberSaveable { mutableIntStateOf(0) }
    var chromeHideDelayMs by rememberSaveable { mutableStateOf(VIEWER_CHROME_AUTO_HIDE_MS) }
    var showNavigationPad by rememberSaveable { mutableStateOf(true) }
    var interactionMode by rememberSaveable { mutableStateOf(ViewerInteractionMode.Control) }
    var isEditingMonitors by rememberSaveable { mutableStateOf(false) }
    var editMonitorsRects by remember { mutableStateOf<List<android.graphics.Rect>>(emptyList()) }
    var editMonitorDragIndex by remember { mutableIntStateOf(-1) }
    var zoomScale by rememberSaveable { mutableStateOf(1f) }
    var zoomOffsetX by rememberSaveable { mutableStateOf(0f) }
    var zoomOffsetY by rememberSaveable { mutableStateOf(0f) }
    val currentBitmap = session.bitmap
    val frameSize = IntSize(currentBitmap?.width ?: 0, currentBitmap?.height ?: 0)
    val titleText = remember(connName, address) {
        normalizeConnName(connName, address).ifBlank { address.ifBlank { "Viewer" } }
    }
    val hostTarget = remember(address, ssh) {
        resolveViewerHostTarget(address, ssh)
    }
    val viewerWindowLabel = remember(titleText, hostTarget) {
        buildViewerWindowLabel(titleText, hostTarget)
    }
    val subtitleText = remember(hostTarget, session.connected, frameSize) {
        buildViewerSubtitleText(hostTarget, session.connected, frameSize)
    }
    val drawSize = remember(viewerSize, frameSize) {
        val viewW = viewerSize.width
        val viewH = viewerSize.height
        if (viewW <= 0 || viewH <= 0 || frameSize.width <= 0 || frameSize.height <= 0) {
            IntSize.Zero
        } else {
            val scale = min(viewW.toFloat() / frameSize.width, viewH.toFloat() / frameSize.height)
            IntSize(
                width = max(1, (frameSize.width * scale).toInt()),
                height = max(1, (frameSize.height * scale).toInt())
            )
        }
    }
    val placement = remember(viewerSize, frameSize, drawSize) {
        RemoteFramePlacement(
            drawSize = drawSize,
            offset = IntOffset(
                x = ((viewerSize.width - drawSize.width) / 2).coerceAtLeast(0),
                y = ((viewerSize.height - drawSize.height) / 2).coerceAtLeast(0)
            ),
            frameSize = frameSize,
            viewerSize = viewerSize
        )
    }
    val zoomState = remember(zoomScale, zoomOffsetX, zoomOffsetY) {
        ViewerZoomState(
            scale = zoomScale,
            offsetX = zoomOffsetX,
            offsetY = zoomOffsetY
        )
    }
    val focusedMonitorBounds = remember(placement, zoomState, session.currentMonitorRect) {
        mapRemoteRectToViewerRect(session.currentMonitorRect, placement, zoomState)
    }
    androidx.compose.runtime.LaunchedEffect(connId, frameSize) {
        if (connId.isNotBlank() && frameSize.width > 0 && frameSize.height > 0) {
            val saved = repository.loadMonitorLayout(connId, frameSize.width, frameSize.height)
            if (saved != null) {
                session.setFallbackMonitors(saved, true)
            }
        }
    }

    val updateZoomState: (ViewerZoomState) -> Unit = { next ->
        zoomScale = next.scale
        zoomOffsetX = next.offsetX
        zoomOffsetY = next.offsetY
    }
    val openControlsSheet: () -> Unit = {
        chromeVisible = true
        showControls = true
    }
    val openDisplaySheet: () -> Unit = {
        chromeVisible = true
        showDisplaySheet = true
    }
    val beginChromeInteraction: () -> Unit = {
        chromeVisible = true
        chromeHideNonce++
    }
    val pulseChromeInteraction: () -> Unit = {
        chromeVisible = true
        chromeHideDelayMs = VIEWER_CHROME_INTERACTION_HIDE_MS
        chromeHideNonce++
    }
    val extendChromeInteractionIfVisible: () -> Unit = {
        if (chromeVisible) {
            chromeHideDelayMs = VIEWER_CHROME_INTERACTION_HIDE_MS
            chromeHideNonce++
        }
    }
    val revealChrome: () -> Unit = {
        chromeVisible = true
        chromeHideDelayMs = VIEWER_CHROME_AUTO_HIDE_MS
        chromeHideNonce++
    }
    val dismissDisplaySheet: () -> Unit = {
        showDisplaySheet = false
        pulseChromeInteraction()
    }
    val focusAllMonitors: () -> Unit = {
        dismissDisplaySheet()
        session.setCurrentMonitor(null)
        interactionMode = ViewerInteractionMode.Control
        updateZoomState(quickToggleViewerZoom(zoomState, placement))
    }
    val focusMonitor: (android.graphics.Rect) -> Unit = { rect ->
        dismissDisplaySheet()
        session.setCurrentMonitor(rect)
        if (placement.drawSize.width > 0 && placement.frameSize.width > 0 && placement.frameSize.height > 0) {
            val drawScaleX = placement.drawSize.width.toFloat() / placement.frameSize.width
            val drawScaleY = placement.drawSize.height.toFloat() / placement.frameSize.height
            val drawW = rect.width() * drawScaleX
            val drawH = rect.height() * drawScaleY
            val scaleX = placement.viewerSize.width.toFloat() / drawW
            val scaleY = placement.viewerSize.height.toFloat() / drawH
            val targetScale = minOf(scaleX, scaleY).coerceIn(VIEWER_ZOOM_MIN_SCALE, VIEWER_ZOOM_MAX_SCALE)

            val (centerX, centerY) = getViewerCenter(placement)
            val rectCenterX = (rect.left + rect.width() / 2f) * drawScaleX + placement.offset.x
            val rectCenterY = (rect.top + rect.height() / 2f) * drawScaleY + placement.offset.y

            val targetOffsetX = (centerX - rectCenterX) * targetScale
            val targetOffsetY = (centerY - rectCenterY) * targetScale

            interactionMode = ViewerInteractionMode.Control
            updateZoomState(
                clampZoomState(
                    placement,
                    ViewerZoomState(
                        scale = targetScale,
                        offsetX = targetOffsetX,
                        offsetY = targetOffsetY
                    ),
                    session.currentMonitorRect
                )
            )
            val px = rect.left + rect.width() / 2
            val py = rect.top + rect.height() / 2
            session.sendPointer(px, py, 1)
            session.sendPointer(px, py, 0)
        }
    }
    val beginMonitorLayoutEdit: () -> Unit = {
        dismissDisplaySheet()
        editMonitorsRects = session.monitors.map { android.graphics.Rect(it) }.ifEmpty {
            listOf(
                android.graphics.Rect(0, 0, frameSize.width / 2, frameSize.height),
                android.graphics.Rect(frameSize.width / 2, 0, frameSize.width, frameSize.height)
            )
        }
        isEditingMonitors = true
        interactionMode = ViewerInteractionMode.Inspect
        updateZoomState(ViewerZoomState())
    }
    val setChromeHovering: (Boolean) -> Unit = { hovering ->
        chromeHovering = hovering
        if (hovering) {
            beginChromeInteraction()
        } else {
            pulseChromeInteraction()
        }
    }
    val handleChromePress: (Boolean) -> Unit = { pressing ->
        if (pressing) {
            beginChromeInteraction()
        } else {
            pulseChromeInteraction()
        }
    }
    val handleRemoteKeyEvent: (androidx.compose.ui.input.key.KeyEvent) -> Boolean = { event ->
        val nativeEvent = event.nativeKeyEvent
        if (nativeEvent.keyCode == android.view.KeyEvent.KEYCODE_F11) {
            if (nativeEvent.action == android.view.KeyEvent.ACTION_DOWN) {
                fullscreen = !fullscreen
                chromeVisible = true
                chromeHideDelayMs = VIEWER_CHROME_INTERACTION_HIDE_MS
                chromeHideNonce++
            }
            true
        } else {
            val keysym = keySymFromAndroidKey(nativeEvent.keyCode, nativeEvent.isShiftPressed, nativeEvent.metaState and android.view.KeyEvent.META_CAPS_LOCK_ON != 0)
            if (keysym == 0) {
                false
            } else {
                session.sendKey(keysym, nativeEvent.action == android.view.KeyEvent.ACTION_DOWN)
                true
            }
        }
    }

    var backPressCount by remember { mutableIntStateOf(0) }

    androidx.compose.runtime.LaunchedEffect(backPressCount) {
        if (backPressCount > 0) {
            kotlinx.coroutines.delay(2000)
            backPressCount = 0
        }
    }

    val isImeVisible = WindowInsets.ime.getBottom(density) > 0
    BackHandler(enabled = !isImeVisible) {
        if (isEditingMonitors) {
            isEditingMonitors = false
        } else if (showDisplaySheet) {
            showDisplaySheet = false
            pulseChromeInteraction()
        } else if (showControls) {
            showControls = false
            pulseChromeInteraction()
        } else {
            if (backPressCount == 0) {
                backPressCount++
                onShowToast("再按一次返回退出远程桌面")
            } else {
                onBack()
            }
        }
    }

    DisposableEffect(session.connected) {
        onDispose {
            if (!session.connected) {
                session.disconnect()
            }
        }
    }

    DisposableEffect(fullscreen, context, view) {
        val window = activity?.window
        if (window != null) {
            WindowCompat.setDecorFitsSystemWindows(window, !fullscreen)
            WindowInsetsControllerCompat(window, view).apply {
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                if (fullscreen) {
                    hide(WindowInsetsCompat.Type.systemBars())
                } else {
                    show(WindowInsetsCompat.Type.systemBars())
                }
            }
        }
        onDispose {
            if (window != null) {
                WindowCompat.setDecorFitsSystemWindows(window, true)
                WindowInsetsControllerCompat(window, view).show(WindowInsetsCompat.Type.systemBars())
            }
        }
    }

    androidx.compose.runtime.SideEffect {
        applyTaskLabel(activity, viewerWindowLabel)
        val clamped = clampZoomState(placement, zoomState, session.currentMonitorRect)
        if (clamped != zoomState) {
            updateZoomState(clamped)
        }
    }

    androidx.compose.runtime.LaunchedEffect(session.connected) {
        if (!session.connected) {
            softInputFieldValue = TextFieldValue("")
            softInputCommittedText = ""
            return@LaunchedEffect
        }
    }

    androidx.compose.runtime.LaunchedEffect(session.connected) {
        if (!session.connected) {
            return@LaunchedEffect
        }
        focusRequester.requestFocus()
        while (isActive && session.connected) {
            val alive = withContext(Dispatchers.Default) {
                session.step()
            }
            if (!alive) {
                onShowToast(session.lastError.ifBlank { "连接已断开" })
                onBack()
                break
            }
            val remoteText = withContext(Dispatchers.Default) {
                session.takeRemoteClipboardText()
            }
            if (remoteText.isNotBlank()) {
                onRemoteClipboard(remoteText)
            }
            delay(16L)
        }
    }

    val imageBitmap = remember(currentBitmap, session.frameVersion) { currentBitmap?.asImageBitmap() }
    val frameReady = imageBitmap != null
    val shouldRenderChrome = !session.connected || showControls || showDisplaySheet || !frameReady || chromeVisible
    val shouldShowChromeHandle = session.connected && !showControls && !showDisplaySheet && frameReady && !chromeVisible

    androidx.compose.runtime.LaunchedEffect(session.connected, frameReady) {
        if (!session.connected) {
            chromeVisible = true
            return@LaunchedEffect
        }
        if (frameReady) {
            revealChrome()
        } else {
            chromeVisible = true
        }
    }

    androidx.compose.runtime.LaunchedEffect(
        chromeVisible,
        chromeHovering,
        showControls,
        showDisplaySheet,
        session.connected,
        frameReady,
        chromeHideNonce,
        chromeHideDelayMs
    ) {
        if (!chromeVisible || chromeHovering || showControls || showDisplaySheet || !session.connected || !frameReady) {
            return@LaunchedEffect
        }
        delay(chromeHideDelayMs)
        if (!chromeHovering && !showControls && !showDisplaySheet && session.connected && frameReady) {
            chromeVisible = false
        }
    }

    if (showSessionList) {
        AlertDialog(
            onDismissRequest = { showSessionList = false },
            title = { Text("已打开会话") },
            text = {
                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                ) {
                    if (openWindows.isEmpty()) {
                        Text("当前没有其他已打开窗口。")
                    } else {
                        openWindows.forEach { windowInfo ->
                            OutlinedButton(
                                onClick = {
                                    if (windowInfo.isCurrent) {
                                        showSessionList = false
                                    } else {
                                        val moved = moveToViewerWindow(context, windowInfo.taskId)
                                        if (!moved) {
                                            onShowToast("切换失败，请从最近任务中打开")
                                        }
                                        showSessionList = false
                                    }
                                },
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text(
                                    if (windowInfo.isCurrent) {
                                        "${buildViewerWindowLabel(windowInfo.title, windowInfo.host)}（当前）"
                                    } else {
                                        buildViewerWindowLabel(windowInfo.title, windowInfo.host)
                                    }
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showSessionList = false }) {
                    Text("关闭")
                }
            }
        )
    }

    if (showControls) {
        ViewerControlSheet(
            titleText = titleText,
            touchScrollStep = touchScrollStep,
            fullscreen = fullscreen,
            securityLevel = session.securityLevel,
            onDismiss = {
                showControls = false
                pulseChromeInteraction()
            },
            onBack = {
                showControls = false
                onBack()
            },
            onShowToast = onShowToast,
            onOpenSessions = {
                openWindows = activity?.let { queryOpenViewerWindows(it, it.taskId) }.orEmpty()
                showControls = false
                showSessionList = true
            },
            onToggleFullscreen = {
                fullscreen = !fullscreen
                pulseChromeInteraction()
            },
            onSendText = {
                showControls = false
                onOpenSendText()
            },
            onPullRemoteClipboard = {
                showControls = false
                onPullRemoteClipboard()
            },
            onPushLocalClipboard = {
                showControls = false
                onPushLocalClipboard()
            },
            onScrollUp = { session.sendScroll(8) },
            onScrollDown = { session.sendScroll(16) }
        )
    }

    if (showDisplaySheet) {
        ViewerDisplaySheet(
            monitors = session.monitors,
            onDismiss = dismissDisplaySheet,
            onShowAll = focusAllMonitors,
            onSelectMonitor = focusMonitor,
            onEditMonitors = beginMonitorLayoutEdit
        )
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0C1416))
            .let {
                if (fullscreen) {
                    it
                } else {
                    it.statusBarsPadding().navigationBarsPadding()
                }
            }
            .focusRequester(focusRequester)
            .focusable()
            .onPreviewKeyEvent(handleRemoteKeyEvent)
    ) {
        BasicTextField(
            value = softInputFieldValue,
            onValueChange = { nextValue ->
                if (!session.connected || nextValue.composition != null) {
                    softInputFieldValue = nextValue
                    return@BasicTextField
                }

                if (nextValue.text.isEmpty()) {
                    sendRemoteBackspace(session, 1)
                    softInputCommittedText = " "
                    softInputFieldValue = androidx.compose.ui.text.input.TextFieldValue(" ", selection = androidx.compose.ui.text.TextRange(1))
                    return@BasicTextField
                }

                val oldRealText = if (softInputCommittedText.startsWith(" ")) softInputCommittedText.substring(1) else softInputCommittedText
                val newRealText = if (nextValue.text.startsWith(" ")) nextValue.text.substring(1) else nextValue.text

                val delta = buildTextDelta(oldRealText, newRealText)
                if (delta.deletedCount > 0) {
                    sendRemoteBackspace(session, delta.deletedCount)
                }
                if (delta.insertedText.isNotEmpty()) {
                    sendCommittedText(session, delta.insertedText)
                }
                softInputCommittedText = " " + newRealText
                softInputFieldValue = nextValue.copy(text = softInputCommittedText)
            },
            modifier = Modifier
                .align(Alignment.TopStart)
                .size(1.dp)
                .alpha(0f)
                .focusRequester(softInputFocusRequester)
                .onPreviewKeyEvent(handleRemoteKeyEvent),
            enabled = session.connected,
            singleLine = false,
            textStyle = MaterialTheme.typography.bodySmall.copy(color = Color.Transparent),
            cursorBrush = SolidColor(Color.Transparent),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
            keyboardActions = KeyboardActions()
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .onSizeChanged { viewerSize = it }
                .pointerInteropFilter { event ->
                    handleViewerMotionEvent(
                        event = event,
                        placement = placement,
                        session = session,
                        touchScrollStep = touchScrollStep,
                        inputState = inputState,
                        interactionMode = interactionMode,
                        zoomState = zoomState,
                        onZoomStateChange = updateZoomState
                    )
                },
            contentAlignment = Alignment.Center
        ) {
            if (imageBitmap == null) {
                EmptyStateCard("正在等待远端画面", "连接成功后会在这里显示远程桌面。")
            } else {
                Box(
                    modifier = Modifier.fillMaxSize()
                ) {
                    AndroidView(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .size(
                                width = density.toDpOrFallback(drawSize.width),
                                height = density.toDpOrFallback(drawSize.height)
                            )
                            .graphicsLayer {
                                scaleX = zoomState.scale
                                scaleY = zoomState.scale
                                translationX = zoomState.offsetX
                                translationY = zoomState.offsetY
                            },
                        factory = { android.widget.ImageView(it) },
                        update = { view ->
                            view.setImageBitmap(currentBitmap)
                            view.scaleType = android.widget.ImageView.ScaleType.FIT_XY
                        }
                    )
                    if (!isEditingMonitors) {
                        focusedMonitorBounds?.let { bounds ->
                            Canvas(modifier = Modifier.fillMaxSize()) {
                                val left = floor(bounds.left).toFloat().coerceIn(0f, size.width)
                                val top = floor(bounds.top).toFloat().coerceIn(0f, size.height)
                                val right = ceil(bounds.right).toFloat().coerceIn(0f, size.width)
                                val bottom = ceil(bounds.bottom).toFloat().coerceIn(0f, size.height)
                                if (right <= left || bottom <= top) {
                                    return@Canvas
                                }

                                val maskColor = Color.Black
                                val seamOverlapPx = max(1f, density.density * 1.5f)
                                val shadowStrokePx = max(3f, density.density * 4f)
                                val outlineStrokePx = max(1f, density.density)
                                val maskLeft = (left + seamOverlapPx).coerceIn(0f, size.width)
                                val maskRight = (right - seamOverlapPx).coerceIn(0f, size.width)
                                val maskTop = (top + seamOverlapPx).coerceIn(0f, size.height)
                                val maskBottom = (bottom - seamOverlapPx).coerceIn(0f, size.height)
                                val horizontalMaskLeft = (left - seamOverlapPx).coerceIn(0f, size.width)
                                val horizontalMaskRight = (right + seamOverlapPx).coerceIn(0f, size.width)
                                if (maskLeft > 0f) {
                                    drawRect(
                                        color = maskColor,
                                        topLeft = androidx.compose.ui.geometry.Offset(0f, 0f),
                                        size = androidx.compose.ui.geometry.Size(maskLeft, size.height)
                                    )
                                }
                                if (maskRight < size.width) {
                                    drawRect(
                                        color = maskColor,
                                        topLeft = androidx.compose.ui.geometry.Offset(maskRight, 0f),
                                        size = androidx.compose.ui.geometry.Size(size.width - maskRight, size.height)
                                    )
                                }
                                if (maskTop > 0f && horizontalMaskRight > horizontalMaskLeft) {
                                    drawRect(
                                        color = maskColor,
                                        topLeft = androidx.compose.ui.geometry.Offset(horizontalMaskLeft, 0f),
                                        size = androidx.compose.ui.geometry.Size(horizontalMaskRight - horizontalMaskLeft, maskTop)
                                    )
                                }
                                if (maskBottom < size.height && horizontalMaskRight > horizontalMaskLeft) {
                                    drawRect(
                                        color = maskColor,
                                        topLeft = androidx.compose.ui.geometry.Offset(horizontalMaskLeft, maskBottom),
                                        size = androidx.compose.ui.geometry.Size(horizontalMaskRight - horizontalMaskLeft, size.height - maskBottom)
                                    )
                                }

                                drawRect(
                                    color = Color.Black.copy(alpha = 0.24f),
                                    topLeft = androidx.compose.ui.geometry.Offset(left, top),
                                    size = androidx.compose.ui.geometry.Size(right - left, bottom - top),
                                    style = androidx.compose.ui.graphics.drawscope.Stroke(width = shadowStrokePx)
                                )
                                drawRect(
                                    color = Color.White.copy(alpha = 0.20f),
                                    topLeft = androidx.compose.ui.geometry.Offset(left, top),
                                    size = androidx.compose.ui.geometry.Size(right - left, bottom - top),
                                    style = androidx.compose.ui.graphics.drawscope.Stroke(width = outlineStrokePx)
                                )
                            }
                        }
                    }
                }
            }
        }

        if (isEditingMonitors) {
            val textPaint = remember(density) {
                android.graphics.Paint().apply {
                    color = android.graphics.Color.WHITE
                    isAntiAlias = true
                    textAlign = android.graphics.Paint.Align.CENTER
                    textSize = 14f * density.density
                    isFakeBoldText = true
                }
            }
            val textBgPaint = remember(density) {
                android.graphics.Paint().apply {
                    color = android.graphics.Color.BLACK
                    alpha = 180
                    isAntiAlias = true
                }
            }
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.4f))
            ) {
                // We need to draw the rects and handles
                Canvas(
                    modifier = Modifier.fillMaxSize().pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) {
                                val event = awaitPointerEvent()
                                val touch = event.changes.firstOrNull()
                                if (touch != null) {
                                    val x = touch.position.x
                                    val y = touch.position.y
                                    val remotePoint = placement.mapToRemote(x, y, zoomState)
                                    if (remotePoint != null) {
                                        val rx = remotePoint.first
                                        val ry = remotePoint.second
                                        when (event.type) {
                                            androidx.compose.ui.input.pointer.PointerEventType.Press -> {
                                                // Find the closest handle or rect center
                                                var bestIndex = -1
                                                var bestType = 0 // 0: none, 1: center, 2: tl, 3: tr, 4: bl, 5: br, 6: l, 7: t, 8: r, 9: b
                                                var bestDist = Float.MAX_VALUE
                                                val handleThreshold = max(24f, frameSize.width * 0.02f)
                                                
                                                for ((i, rect) in editMonitorsRects.withIndex()) {
                                                    val cx = rect.left + rect.width() / 2f
                                                    val cy = rect.top + rect.height() / 2f
                                                    val dCenter = kotlin.math.hypot((rx - cx).toDouble(), (ry - cy).toDouble()).toFloat()
                                                    if (dCenter < handleThreshold * 2 && dCenter < bestDist) {
                                                        bestDist = dCenter
                                                        bestIndex = i
                                                        bestType = 1
                                                    }
                                                    
                                                    val dTL = kotlin.math.hypot((rx - rect.left).toDouble(), (ry - rect.top).toDouble()).toFloat()
                                                    if (dTL < handleThreshold && dTL < bestDist) { bestDist = dTL; bestIndex = i; bestType = 2 }
                                                    val dTR = kotlin.math.hypot((rx - rect.right).toDouble(), (ry - rect.top).toDouble()).toFloat()
                                                    if (dTR < handleThreshold && dTR < bestDist) { bestDist = dTR; bestIndex = i; bestType = 3 }
                                                    val dBL = kotlin.math.hypot((rx - rect.left).toDouble(), (ry - rect.bottom).toDouble()).toFloat()
                                                    if (dBL < handleThreshold && dBL < bestDist) { bestDist = dBL; bestIndex = i; bestType = 4 }
                                                    val dBR = kotlin.math.hypot((rx - rect.right).toDouble(), (ry - rect.bottom).toDouble()).toFloat()
                                                    if (dBR < handleThreshold && dBR < bestDist) { bestDist = dBR; bestIndex = i; bestType = 5 }
                                                }
                                                if (bestIndex >= 0) {
                                                    editMonitorDragIndex = bestIndex
                                                    inputState.touchStartX = rx.toFloat()
                                                    inputState.touchStartY = ry.toFloat()
                                                    // Store the initial rect in inputState using pinch properties or new ones
                                                    inputState.pinchAnchorBaseX = bestType.toFloat()
                                                    val initialRect = editMonitorsRects[bestIndex]
                                                    inputState.touchScrollLastX = initialRect.left.toFloat()
                                                    inputState.touchScrollLastY = initialRect.top.toFloat()
                                                    inputState.touchScrollResidualY = initialRect.right.toFloat()
                                                    inputState.pinchStartDistance = initialRect.bottom.toFloat()
                                                    touch.consume()
                                                }
                                            }
                                            androidx.compose.ui.input.pointer.PointerEventType.Move -> {
                                                if (editMonitorDragIndex >= 0) {
                                                    val dx = (rx - inputState.touchStartX).toInt()
                                                    val dy = (ry - inputState.touchStartY).toInt()
                                                    val type = inputState.pinchAnchorBaseX.toInt()
                                                    val oldL = inputState.touchScrollLastX.toInt()
                                                    val oldT = inputState.touchScrollLastY.toInt()
                                                    val oldR = inputState.touchScrollResidualY.toInt()
                                                    val oldB = inputState.pinchStartDistance.toInt()
                                                    
                                                    val newRect = android.graphics.Rect(oldL, oldT, oldR, oldB)
                                                    when (type) {
                                                        1 -> { newRect.offset(dx, dy) }
                                                        2 -> { newRect.left = oldL + dx; newRect.top = oldT + dy }
                                                        3 -> { newRect.right = oldR + dx; newRect.top = oldT + dy }
                                                        4 -> { newRect.left = oldL + dx; newRect.bottom = oldB + dy }
                                                        5 -> { newRect.right = oldR + dx; newRect.bottom = oldB + dy }
                                                    }
                                                    
                                                    val clamped = MonitorLayoutHelper.clampManualMonitorRect(newRect, frameSize.width, frameSize.height)
                                                    if (clamped != null) {
                                                        editMonitorsRects = editMonitorsRects.toMutableList().also { it[editMonitorDragIndex] = clamped }
                                                    }
                                                    touch.consume()
                                                }
                                            }
                                            androidx.compose.ui.input.pointer.PointerEventType.Release -> {
                                                if (editMonitorDragIndex >= 0) {
                                                    val currentRect = editMonitorsRects[editMonitorDragIndex]
                                                    val rounded = MonitorLayoutHelper.roundManualMonitorRectToCommonSize(currentRect, editMonitorDragIndex, editMonitorsRects, frameSize.width, frameSize.height)
                                                    editMonitorsRects = editMonitorsRects.toMutableList().also { it[editMonitorDragIndex] = rounded }
                                                    editMonitorDragIndex = -1
                                                    touch.consume()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                ) {
                    if (placement.drawSize.width > 0 && placement.frameSize.width > 0 && placement.frameSize.height > 0) {
                        val drawScaleX = placement.drawSize.width.toFloat() / placement.frameSize.width
                        val drawScaleY = placement.drawSize.height.toFloat() / placement.frameSize.height
                        
                        for ((index, rect) in editMonitorsRects.withIndex()) {
                            val color = if (index == 0) Color(0xFF2CB478) else if (index == 1) Color(0xFF2C78B4) else Color(0xFFC96C42)
                            
                            val rectCenterX = (rect.left + rect.width() / 2f) * drawScaleX + placement.offset.x
                            val rectCenterY = (rect.top + rect.height() / 2f) * drawScaleY + placement.offset.y
                            
                            val (cx, cy) = if (canUseZoomViewer(placement) && zoomState.scale > VIEWER_ZOOM_MIN_SCALE) {
                                val (vcX, vcY) = getViewerCenter(placement)
                                Pair(
                                    vcX + (rectCenterX - vcX) * zoomState.scale + zoomState.offsetX,
                                    vcY + (rectCenterY - vcY) * zoomState.scale + zoomState.offsetY
                                )
                            } else {
                                Pair(rectCenterX, rectCenterY)
                            }
                            
                            val mappedLeft = placement.offset.x + rect.left * drawScaleX
                            val mappedTop = placement.offset.y + rect.top * drawScaleY
                            val mappedRight = placement.offset.x + rect.right * drawScaleX
                            val mappedBottom = placement.offset.y + rect.bottom * drawScaleY
                            
                            val mapPoint: (Float, Float) -> Pair<Float, Float> = { px, py ->
                                if (canUseZoomViewer(placement) && zoomState.scale > VIEWER_ZOOM_MIN_SCALE) {
                                    val (vcX, vcY) = getViewerCenter(placement)
                                    Pair(
                                        vcX + (px - vcX) * zoomState.scale + zoomState.offsetX,
                                        vcY + (py - vcY) * zoomState.scale + zoomState.offsetY
                                    )
                                } else {
                                    Pair(px, py)
                                }
                            }
                            
                            val (finalL, finalT) = mapPoint(mappedLeft, mappedTop)
                            val (finalR, finalB) = mapPoint(mappedRight, mappedBottom)
                            
                            drawRect(
                                color = color.copy(alpha = 0.2f),
                                topLeft = androidx.compose.ui.geometry.Offset(finalL, finalT),
                                size = androidx.compose.ui.geometry.Size(finalR - finalL, finalB - finalT)
                            )
                            
                            drawRect(
                                color = color,
                                topLeft = androidx.compose.ui.geometry.Offset(finalL, finalT),
                                size = androidx.compose.ui.geometry.Size(finalR - finalL, finalB - finalT),
                                style = androidx.compose.ui.graphics.drawscope.Stroke(width = 4f * density.density)
                            )
                            
                            // Draw corner handles
                            val handleRadius = 8f * density.density
                            drawCircle(color, handleRadius, androidx.compose.ui.geometry.Offset(finalL, finalT))
                            drawCircle(color, handleRadius, androidx.compose.ui.geometry.Offset(finalR, finalT))
                            drawCircle(color, handleRadius, androidx.compose.ui.geometry.Offset(finalL, finalB))
                            drawCircle(color, handleRadius, androidx.compose.ui.geometry.Offset(finalR, finalB))
                            
                            // Draw center handle
                            drawCircle(color.copy(alpha = 0.8f), handleRadius * 1.5f, androidx.compose.ui.geometry.Offset(cx, cy))
                            
                            // Draw Screen Number Label
                            val label = "屏幕 ${index + 1}"
                            val textWidth = textPaint.measureText(label)
                            val padX = 12f * density.density
                            val padY = 8f * density.density
                            val bgRect = android.graphics.RectF(
                                cx - textWidth / 2f - padX,
                                cy - handleRadius * 3f - textPaint.textSize - padY,
                                cx + textWidth / 2f + padX,
                                cy - handleRadius * 3f + padY
                            )
                            drawContext.canvas.nativeCanvas.drawRoundRect(bgRect, 8f * density.density, 8f * density.density, textBgPaint)
                            drawContext.canvas.nativeCanvas.drawText(label, cx, cy - handleRadius * 3f, textPaint)
                        }
                    }
                }
                
                // Top Action Bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                        .align(Alignment.TopCenter),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    ViewerChromeButton(
                        text = "取消",
                        onClick = { isEditingMonitors = false }
                    )
                    Text(
                        "编辑屏幕布局",
                        color = Color.White,
                        style = MaterialTheme.typography.titleMedium
                    )
                    ViewerChromeButton(
                        text = "保存",
                        active = true,
                        onClick = {
                            session.setFallbackMonitors(editMonitorsRects, true)
                            repository.saveMonitorLayout(connId, frameSize.width, frameSize.height, editMonitorsRects)
                            isEditingMonitors = false
                            onShowToast("已保存当前屏幕布局")
                        }
                    )
                }
            }
        }

        if (shouldRenderChrome && !isEditingMonitors) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 12.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                ViewerTopBar(
                    titleText = viewerWindowLabel,
                    subtitleText = subtitleText,
                    connected = session.connected,
                    securityLevel = session.securityLevel,
                    fullscreen = fullscreen,
                    onHoverChange = setChromeHovering,
                    onTouchPress = handleChromePress,
                    onToggleFullscreen = {
                        pulseChromeInteraction()
                        fullscreen = !fullscreen
                    },
                    onShowMore = openControlsSheet
                )
                if (session.connected) {
                    ViewerBottomDock(
                        interactionMode = interactionMode,
                        canZoom = canUseZoomViewer(placement),
                        zoomScale = zoomState.scale,
                        showDisplayEntry = session.monitors.size > 1,
                        onHoverChange = setChromeHovering,
                        onTouchPress = handleChromePress,
                        onSetControl = {
                            pulseChromeInteraction()
                            interactionMode = ViewerInteractionMode.Control
                        },
                        onSetInspect = {
                            pulseChromeInteraction()
                            interactionMode = ViewerInteractionMode.Inspect
                            onShowToast("查看模式：双指缩放，单指拖动画面，双击切换 1x/2x")
                        },
                        onShowKeyboard = {
                            pulseChromeInteraction()
                            softInputFocusRequester.requestFocus()
                            softwareKeyboardController?.show()
                            inputMethodManager?.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
                        },
                        onQuickZoom = {
                            pulseChromeInteraction()
                            session.setCurrentMonitor(null)
                            val nextZoom = quickToggleViewerZoom(zoomState, placement)
                            if (nextZoom != zoomState) {
                                interactionMode = ViewerInteractionMode.Control
                                updateZoomState(nextZoom)
                            }
                        },
                        onZoomOut = {
                            pulseChromeInteraction()
                            updateZoomState(stepViewerZoom(zoomState, -VIEWER_ZOOM_STEP_SCALE, placement, session.currentMonitorRect))
                        },
                        onZoomIn = {
                            pulseChromeInteraction()
                            updateZoomState(stepViewerZoom(zoomState, VIEWER_ZOOM_STEP_SCALE, placement, session.currentMonitorRect))
                        },
                        onShowMore = {
                            openControlsSheet()
                        },
                        onShowDisplay = openDisplaySheet,
                         showNavigationPad = showNavigationPad,
                         onToggleNavigationPad = {
                             pulseChromeInteraction()
                             showNavigationPad = it
                         }
                     )
                } else {
                    Box(modifier = Modifier.fillMaxWidth())
                }
            }
        }

        if (shouldShowChromeHandle) {
            ViewerChromeHandle(
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .offset(y = 12.dp),
                onReveal = revealChrome
            )
        }

        if (session.connected && interactionMode == ViewerInteractionMode.Control && showNavigationPad && !isEditingMonitors) {
            val panStep = 100f
            FloatingNavigationPad(
                onUp = {
                    extendChromeInteractionIfVisible()
                    updateZoomState(clampZoomState(placement, zoomState.copy(offsetY = zoomState.offsetY + panStep), session.currentMonitorRect))
                },
                onDown = {
                    extendChromeInteractionIfVisible()
                    updateZoomState(clampZoomState(placement, zoomState.copy(offsetY = zoomState.offsetY - panStep), session.currentMonitorRect))
                },
                onLeft = {
                    extendChromeInteractionIfVisible()
                    updateZoomState(clampZoomState(placement, zoomState.copy(offsetX = zoomState.offsetX + panStep), session.currentMonitorRect))
                },
                onRight = {
                    extendChromeInteractionIfVisible()
                    updateZoomState(clampZoomState(placement, zoomState.copy(offsetX = zoomState.offsetX - panStep), session.currentMonitorRect))
                },
                onZoomIn = {
                    extendChromeInteractionIfVisible()
                    updateZoomState(stepViewerZoom(zoomState, VIEWER_ZOOM_STEP_SCALE, placement, session.currentMonitorRect))
                },
                onZoomOut = {
                    extendChromeInteractionIfVisible()
                    updateZoomState(stepViewerZoom(zoomState, -VIEWER_ZOOM_STEP_SCALE, placement, session.currentMonitorRect))
                },
                modifier = Modifier.align(Alignment.BottomEnd).padding(bottom = 32.dp, end = 32.dp)
            )
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
private fun Modifier.viewerChromeRegion(
    onHoverChange: (Boolean) -> Unit,
    onTouchPress: (Boolean) -> Unit
): Modifier {
    return this
        .pointerInteropFilter { event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_HOVER_ENTER,
                MotionEvent.ACTION_HOVER_MOVE -> onHoverChange(true)
                MotionEvent.ACTION_HOVER_EXIT -> onHoverChange(false)
                MotionEvent.ACTION_DOWN -> onTouchPress(true)
                MotionEvent.ACTION_UP,
                MotionEvent.ACTION_CANCEL -> onTouchPress(false)
            }
            false
        }
}

private fun viewerSecurityText(connected: Boolean, securityLevel: Int): String {
    if (!connected) {
        return "准备连接"
    }
    return when (securityLevel) {
        2 -> "安全连接"
        1 -> "认证安全"
        else -> "未加密"
    }
}

private fun viewerSecurityColor(connected: Boolean, securityLevel: Int): Color {
    if (!connected) {
        return Color(0xFF5B6B73)
    }
    return when (securityLevel) {
        2 -> Color(0xFF2CB478)
        1 -> Color(0xFF2C78B4)
        else -> Color(0xFFC96C42)
    }
}

@Composable
private fun ViewerChromeButton(
    text: String,
    modifier: Modifier = Modifier,
    active: Boolean = false,
    onClick: () -> Unit
) {
    Card(
        modifier = modifier.widthIn(min = 68.dp),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (active) VIEWER_CHROME_PRIMARY else Color.White.copy(alpha = 0.08f)
        ),
        border = BorderStroke(
            1.dp,
            if (active) VIEWER_CHROME_PRIMARY else VIEWER_CHROME_BORDER
        ),
        onClick = onClick
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            color = VIEWER_CHROME_PRIMARY_FG,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
            maxLines = 1
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ViewerDockGroup(
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.FlowRowScope.() -> Unit
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = VIEWER_CHROME_SURFACE),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.08f))
    ) {
        FlowRow(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            maxItemsInEachRow = 5,
            content = content
        )
    }
}

@Composable
private fun ViewerTopBar(
    titleText: String,
    subtitleText: String,
    connected: Boolean,
    securityLevel: Int,
    fullscreen: Boolean,
    onHoverChange: (Boolean) -> Unit,
    onTouchPress: (Boolean) -> Unit,
    onToggleFullscreen: () -> Unit,
    onShowMore: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .viewerChromeRegion(onHoverChange = onHoverChange, onTouchPress = onTouchPress),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xC20C1416)),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.08f))
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = titleText,
                    color = Color.White,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1
                )
                Text(
                    text = subtitleText,
                    color = Color.White.copy(alpha = 0.74f),
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1
                )
            }
            ViewerInfoPill(
                text = viewerSecurityText(connected, securityLevel),
                modifier = Modifier
            )
            if (connected) {
                ViewerChromeButton(
                    text = if (fullscreen) "退出全屏" else "全屏",
                    onClick = onToggleFullscreen
                )
            }
            ViewerChromeButton(
                text = "更多",
                onClick = onShowMore
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ViewerBottomDock(
    interactionMode: ViewerInteractionMode,
    canZoom: Boolean,
    zoomScale: Float,
    showDisplayEntry: Boolean,
    onHoverChange: (Boolean) -> Unit,
    onTouchPress: (Boolean) -> Unit,
    onSetControl: () -> Unit,
    onSetInspect: () -> Unit,
    onShowKeyboard: () -> Unit,
    onQuickZoom: () -> Unit,
    onZoomOut: () -> Unit,
    onZoomIn: () -> Unit,
    onShowMore: () -> Unit,
    onShowDisplay: () -> Unit,
    showNavigationPad: Boolean,
    onToggleNavigationPad: (Boolean) -> Unit
) {
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .viewerChromeRegion(onHoverChange = onHoverChange, onTouchPress = onTouchPress),
    ) {
        val groupMaxWidth = if (maxWidth > 840.dp) 760.dp else maxWidth
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            ViewerDockGroup(modifier = Modifier.widthIn(max = groupMaxWidth)) {
                ViewerChromeButton(
                    text = "控制模式",
                    active = interactionMode == ViewerInteractionMode.Control,
                    onClick = onSetControl
                )
                ViewerChromeButton(
                    text = "查看模式",
                    active = interactionMode == ViewerInteractionMode.Inspect,
                    onClick = onSetInspect
                )
                ViewerChromeButton(
                    text = "键盘",
                    onClick = onShowKeyboard
                )
                ViewerChromeButton(
                    text = "导航",
                    active = showNavigationPad,
                    onClick = { onToggleNavigationPad(!showNavigationPad) }
                )
                ViewerChromeButton(
                    text = "更多",
                    onClick = onShowMore
                )
            }
            if (canZoom) {
                ViewerDockGroup(
                    modifier = Modifier.widthIn(max = groupMaxWidth)
                ) {
                    ViewerChromeButton(
                        text = "缩小",
                        onClick = onZoomOut
                    )
                    ViewerChromeButton(
                        text = "倍率 ${getZoomButtonLabel(zoomScale)}",
                        active = zoomScale > 1.05f,
                        onClick = onQuickZoom
                    )
                    ViewerChromeButton(
                        text = "放大",
                        onClick = onZoomIn
                    )
                    if (showDisplayEntry) {
                        ViewerChromeButton(
                            text = "屏幕",
                            onClick = onShowDisplay
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ViewerChromeHandle(
    modifier: Modifier = Modifier,
    onReveal: () -> Unit
) {
    Card(
        modifier = modifier
            .width(VIEWER_CHROME_HANDLE_WIDTH)
            .heightIn(min = VIEWER_CHROME_HANDLE_HEIGHT),
        shape = RoundedCornerShape(topStart = 12.dp, bottomStart = 12.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0x660C1416)),
        border = BorderStroke(1.dp, VIEWER_CHROME_BORDER),
        onClick = onReveal
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            repeat(3) {
                Box(
                    modifier = Modifier
                        .size(4.dp)
                        .background(Color.White.copy(alpha = 0.82f), RoundedCornerShape(2.dp))
                )
            }
        }
    }
}

@Composable
private fun ViewerInfoPill(
    modifier: Modifier = Modifier,
    text: String
) {
    Card(
        modifier = modifier.widthIn(max = 240.dp),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xA0162023))
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            color = Color.White,
            maxLines = 1
        )
    }
}

@Composable
private fun ViewerPill(
    text: String,
    modifier: Modifier = Modifier,
    backgroundColor: Color,
    onClick: () -> Unit
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = backgroundColor),
        onClick = onClick
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            color = Color.White
        )
    }
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
private fun ViewerControlSheet(
    titleText: String,
    touchScrollStep: Int,
    fullscreen: Boolean,
    securityLevel: Int,
    onDismiss: () -> Unit,
    onBack: () -> Unit,
    onShowToast: (String) -> Unit,
    onOpenSessions: () -> Unit,
    onToggleFullscreen: () -> Unit,
    onSendText: () -> Unit,
    onScrollUp: () -> Unit,
    onScrollDown: () -> Unit,
    onPullRemoteClipboard: () -> Unit,
    onPushLocalClipboard: () -> Unit
) {
    val primaryTextColor = Color(0xFFF5F5F4)
    val secondaryTextColor = Color(0xFFD6E3E8)
    val chipContainerColor = VIEWER_CHROME_SURFACE_SOFT
    val securityText = when (securityLevel) {
        2 -> "安全"
        1 -> "认证安全"
        else -> "不安全"
    }
    val securityMessage = when (securityLevel) {
        2 -> "当前连接已全链路加密"
        1 -> "仅凭据加密，数据传输未加密"
        else -> "当前连接未加密，请注意数据安全"
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xF20C1416)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Text(
                text = "控制中心",
                color = primaryTextColor,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )
            ViewerInfoPill(
                modifier = Modifier.fillMaxWidth(),
                text = titleText
            )
            OutlinedButton(
                onClick = { onShowToast(securityMessage) },
                modifier = Modifier.fillMaxWidth(),
                border = BorderStroke(1.dp, Color.White.copy(alpha = 0.24f)),
                colors = ButtonDefaults.outlinedButtonColors(
                    containerColor = VIEWER_CHROME_PRIMARY,
                    contentColor = primaryTextColor
                )
            ) {
                Text(
                    text = "连接状态：$securityText",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium
                )
            }
            HorizontalDivider(color = VIEWER_CHROME_BORDER)
            Text(
                text = "常用操作",
                color = secondaryTextColor,
                style = MaterialTheme.typography.labelLarge
            )
            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                AssistChip(
                    onClick = onBack,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text("返回列表", style = MaterialTheme.typography.bodyMedium) }
                )
                AssistChip(
                    onClick = onOpenSessions,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text("切换会话", style = MaterialTheme.typography.bodyMedium) }
                )
                AssistChip(
                    onClick = onToggleFullscreen,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text(if (fullscreen) "退出全屏" else "进入全屏", style = MaterialTheme.typography.bodyMedium) }
                )
                AssistChip(
                    onClick = onSendText,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text("发送文本", style = MaterialTheme.typography.bodyMedium) }
                )
                AssistChip(
                    onClick = onPullRemoteClipboard,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text("拉取剪贴板", style = MaterialTheme.typography.bodyMedium) }
                )
                AssistChip(
                    onClick = onPushLocalClipboard,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text("推送剪贴板", style = MaterialTheme.typography.bodyMedium) }
                )
                AssistChip(
                    onClick = onScrollUp,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text("滚动上", style = MaterialTheme.typography.bodyMedium) }
                )
                AssistChip(
                    onClick = onScrollDown,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text("滚动下", style = MaterialTheme.typography.bodyMedium) }
                )
            }
            Text(
                text = "触控滚动：${touchScrollLabel(touchScrollStep)}",
                color = secondaryTextColor,
                style = MaterialTheme.typography.bodyMedium
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
private fun ViewerDisplaySheet(
    monitors: List<android.graphics.Rect>,
    onDismiss: () -> Unit,
    onShowAll: () -> Unit,
    onSelectMonitor: (android.graphics.Rect) -> Unit,
    onEditMonitors: () -> Unit
) {
    val primaryTextColor = Color(0xFFF5F5F4)
    val secondaryTextColor = Color(0xFFD6E3E8)
    val chipContainerColor = VIEWER_CHROME_SURFACE_SOFT
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xF20C1416)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Text(
                text = "屏幕布局",
                color = primaryTextColor,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = "将多屏相关操作收纳到这里，保持主工具栏更轻。",
                color = secondaryTextColor,
                style = MaterialTheme.typography.bodyMedium
            )
            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                AssistChip(
                    onClick = onShowAll,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text("全览", style = MaterialTheme.typography.bodyMedium) }
                )
                monitors.forEachIndexed { index, rect ->
                    AssistChip(
                        onClick = { onSelectMonitor(rect) },
                        colors = AssistChipDefaults.assistChipColors(
                            containerColor = chipContainerColor,
                            labelColor = primaryTextColor
                        ),
                        border = AssistChipDefaults.assistChipBorder(
                            enabled = true,
                            borderColor = VIEWER_CHROME_BORDER
                        ),
                        label = { Text("屏幕 ${index + 1}", style = MaterialTheme.typography.bodyMedium) }
                    )
                }
                AssistChip(
                    onClick = onEditMonitors,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = chipContainerColor,
                        labelColor = primaryTextColor
                    ),
                    border = AssistChipDefaults.assistChipBorder(
                        enabled = true,
                        borderColor = VIEWER_CHROME_BORDER
                    ),
                    label = { Text("编辑屏幕布局", style = MaterialTheme.typography.bodyMedium) }
                )
            }
        }
    }
}

@Composable
private fun EditConnectionDialog(
    state: EditConnectionState,
    onStateChange: (EditConnectionState) -> Unit,
    onDismiss: () -> Unit,
    onSave: (EditConnectionState) -> Unit
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp)
        ) {
            val contentMaxHeight = (maxHeight - 32.dp).coerceAtLeast(280.dp)
            val presentation = buildConnectionPresentation(
                address = state.address,
                ssh = state.ssh,
                desktopUser = state.user,
                desktopPassword = state.password
            )
            val formScrollState = rememberScrollState()
            var selectedTab by rememberSaveable(state.id) {
                mutableStateOf(EditConnectionTab.Basic)
            }
            Card(
                modifier = Modifier
                    .align(Alignment.Center)
                    .fillMaxWidth()
                    .widthIn(max = 560.dp)
                    .heightIn(max = contentMaxHeight),
                shape = RoundedCornerShape(28.dp)
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 24.dp, vertical = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Text(
                            text = if (state.id.isBlank()) "新增连接" else "编辑连接",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.SemiBold
                        )
                        CompactConnectionPreview(
                            presentation = presentation,
                            title = "当前连接方式"
                        )
                        EditConnectionTabSelector(
                            selectedTab = selectedTab,
                            advancedConfigured = hasAnyAdvancedEditOptions(state),
                            onTabSelected = { selectedTab = it }
                        )
                    }
                    HorizontalDivider()
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f, fill = false)
                            .verticalScroll(formScrollState)
                            .padding(horizontal = 24.dp, vertical = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        if (selectedTab == EditConnectionTab.Basic) {
                            BasicEditConnectionContent(
                                state = state,
                                onStateChange = onStateChange
                            )
                        } else {
                            AdvancedEditConnectionContent(
                                state = state,
                                onStateChange = onStateChange
                            )
                        }
                    }
                    HorizontalDivider()
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 24.dp, vertical = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        OutlinedButton(
                            modifier = Modifier.weight(1f),
                            onClick = onDismiss
                        ) {
                            Text("取消")
                        }
                        Button(
                            modifier = Modifier.weight(1f),
                            onClick = { onSave(state) }
                        ) {
                            Text("保存")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyStateCard(
    title: String,
    message: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null
) {
    Card(
        shape = RoundedCornerShape(20.dp),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(message, color = MaterialTheme.colorScheme.secondary)
            if (!actionLabel.isNullOrBlank() && onAction != null) {
                Button(onClick = onAction) {
                    Text(actionLabel)
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AboutDialog(
    onDismiss: () -> Unit,
    onShowPrivacyPolicy: () -> Unit,
    onShowUserAgreement: () -> Unit
) {
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val copyText: (String, String) -> Unit = { value, message ->
        clipboardManager.setText(AnnotatedString(value))
        Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("翠虎远程桌面") },
        text = {
            Column(
                modifier = Modifier
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text("Version ${BuildConfig.BUILD_VERSION}")
                HorizontalDivider()
                Text("公司信息", fontWeight = FontWeight.SemiBold)
                AboutInfoRow(label = "开发团队", value = "横渠天地（北京）科技有限公司")
                AboutActionRow(
                    label = "商务合作",
                    value = PROJECT_CONTACT_EMAIL,
                    actionLabel = "写邮件",
                    onOpen = { openEmailClient(context, PROJECT_CONTACT_EMAIL) },
                    onCopy = { copyText(PROJECT_CONTACT_EMAIL, "邮箱已复制") }
                )
                AboutActionRow(
                    label = "官方网站",
                    value = PROJECT_HOMEPAGE_URL,
                    actionLabel = "访问",
                    onOpen = { openExternalLink(context, PROJECT_HOMEPAGE_URL) },
                    onCopy = { copyText(PROJECT_HOMEPAGE_URL, "网址已复制") }
                )
                HorizontalDivider()
                Text("协议与隐私", fontWeight = FontWeight.SemiBold)
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    TextButton(onClick = onShowPrivacyPolicy) {
                        Text("隐私政策全文")
                    }
                    TextButton(onClick = onShowUserAgreement) {
                        Text("用户协议全文")
                    }
                }
                HorizontalDivider()
                Text("开源许可", fontWeight = FontWeight.SemiBold)
                AboutInfoRow(label = "开源许可", value = "本应用采用 GPL-2.0 许可发布，并包含多个第三方开源组件。")
                AboutActionRow(
                    label = "源码获取",
                    value = PROJECT_SOURCE_URL,
                    actionLabel = "访问",
                    onOpen = { openExternalLink(context, PROJECT_SOURCE_URL) },
                    onCopy = { copyText(PROJECT_SOURCE_URL, "网址已复制") }
                )
                Text("第三方组件：\n• TigerVNC (GPL-2.0)\n• libssh2 (BSD-3-Clause)\n• mbedTLS (Apache-2.0 / GPL-2.0)\n• GnuTLS (LGPL-2.1+)\n• Nettle (GPL-2.0+ / LGPL-3.0+)")
                HorizontalDivider()
                Text("免责声明", fontWeight = FontWeight.SemiBold)
                Text("本软件按“现状”提供，不附带任何明示或暗示担保。详见各许可证全文。")
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("关闭")
            }
        }
    )
}

@Composable
private fun AboutInfoRow(
    label: String,
    value: String
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top
    ) {
        Text(
            text = label,
            modifier = Modifier.width(72.dp),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = value,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
private fun AboutActionRow(
    label: String,
    value: String,
    actionLabel: String,
    onOpen: () -> Unit,
    onCopy: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top
    ) {
        Text(
            text = label,
            modifier = Modifier.width(72.dp),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            TextButton(
                onClick = onOpen,
                contentPadding = PaddingValues(0.dp)
            ) {
                Text(value)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TextButton(
                    onClick = onOpen,
                    contentPadding = PaddingValues(0.dp)
                ) {
                    Text(actionLabel)
                }
                TextButton(
                    onClick = onCopy,
                    contentPadding = PaddingValues(0.dp)
                ) {
                    Text("复制")
                }
            }
        }
    }
}

private fun openExternalLink(context: Context, url: String) {
    runCatching {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }.onFailure {
        Toast.makeText(context, "无法打开链接", Toast.LENGTH_SHORT).show()
    }
}

private fun openEmailClient(context: Context, email: String) {
    runCatching {
        context.startActivity(
            Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:$email")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }.onFailure {
        Toast.makeText(context, "无法打开邮箱应用", Toast.LENGTH_SHORT).show()
    }
}

@Composable
private fun AgreementMarkdownContent(
    markdownText: String,
    modifier: Modifier = Modifier
) {
    val blocks = remember(markdownText) { parseMarkdownBlocks(markdownText) }
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        blocks.forEach { block ->
            when (block) {
                is MarkdownBlock.Heading -> {
                    val style = when (block.level) {
                        1 -> MaterialTheme.typography.titleLarge
                        2 -> MaterialTheme.typography.titleMedium
                        else -> MaterialTheme.typography.titleSmall
                    }
                    Text(
                        text = block.text,
                        style = style,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }
                is MarkdownBlock.Paragraph -> {
                    Text(
                        text = block.text,
                        style = MaterialTheme.typography.bodyMedium,
                        lineHeight = 22.sp,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }
                is MarkdownBlock.Bullet -> {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.Top
                    ) {
                        Text(
                            text = "•",
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(top = 1.dp)
                        )
                        Text(
                            text = block.text,
                            modifier = Modifier.weight(1f),
                            style = MaterialTheme.typography.bodyMedium,
                            lineHeight = 22.sp,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AgreementDocumentDialog(
    title: String,
    helperText: String,
    markdownText: String,
    onDismiss: () -> Unit
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp)
        ) {
            val contentMaxHeight = (maxHeight - 32.dp).coerceAtLeast(320.dp)
            val scrollState = rememberScrollState()
            Card(
                modifier = Modifier
                    .align(Alignment.Center)
                    .fillMaxWidth()
                    .widthIn(max = 640.dp)
                    .heightIn(max = contentMaxHeight),
                shape = RoundedCornerShape(28.dp)
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 24.dp, vertical = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                        Text(
                            helperText,
                            color = MaterialTheme.colorScheme.secondary
                        )
                    }
                    HorizontalDivider()
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f, fill = false)
                            .verticalScroll(scrollState)
                            .padding(horizontal = 24.dp, vertical = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        AgreementMarkdownContent(markdownText = markdownText)
                    }
                    HorizontalDivider()
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 24.dp, vertical = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Button(
                            modifier = Modifier.fillMaxWidth(),
                            onClick = onDismiss
                        ) {
                            Text("关闭")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AgreementsConsentDialog(
    privacyPolicyText: String,
    userAgreementText: String,
    onAgree: () -> Unit,
    onExit: () -> Unit
) {
    BackHandler(onBack = onExit)
    Dialog(
        onDismissRequest = {},
        properties = DialogProperties(
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
            usePlatformDefaultWidth = false
        )
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp)
        ) {
            val contentMaxHeight = (maxHeight - 32.dp).coerceAtLeast(360.dp)
            val scrollState = rememberScrollState()
            Card(
                modifier = Modifier
                    .align(Alignment.Center)
                    .fillMaxWidth()
                    .widthIn(max = 640.dp)
                    .heightIn(max = contentMaxHeight),
                shape = RoundedCornerShape(28.dp)
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 24.dp, vertical = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text("协议阅读与确认", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                        Text(
                            "首次使用前，请您完整阅读并确认《翠虎远程桌面隐私协议》与《翠虎远程桌面用户协议》。同意后方可继续使用应用。",
                            color = MaterialTheme.colorScheme.secondary
                        )
                    }
                    HorizontalDivider()
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f, fill = false)
                            .verticalScroll(scrollState)
                            .padding(horizontal = 24.dp, vertical = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(20.dp)
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text("隐私协议", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                            AgreementMarkdownContent(markdownText = privacyPolicyText)
                        }
                        HorizontalDivider()
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text("用户协议", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                            AgreementMarkdownContent(markdownText = userAgreementText)
                        }
                    }
                    HorizontalDivider()
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 24.dp, vertical = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        OutlinedButton(
                            modifier = Modifier.weight(1f),
                            onClick = onExit
                        ) {
                            Text("退出应用")
                        }
                        Button(
                            modifier = Modifier.weight(1f),
                            onClick = onAgree
                        ) {
                            Text("同意并继续")
                        }
                    }
                }
            }
        }
    }
}

private fun androidx.compose.ui.unit.Density.toDpOrFallback(px: Int): Dp = if (px <= 0) 1.dp else px.toDp()

private fun matchesConnectionKeyword(item: ConnectionItem, keyword: String): Boolean {
    val query = keyword.trim()
    if (query.isEmpty()) {
        return true
    }
    return item.name.contains(query, ignoreCase = true) ||
        item.address.contains(query, ignoreCase = true) ||
        item.user.contains(query, ignoreCase = true)
}

private fun formatLastUsed(timestamp: Long): String {
    if (timestamp <= 0L) {
        return "上次连接 未知"
    }
    val formatter = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault())
    return "上次连接 ${formatter.format(Date(timestamp))}"
}

private data class ConnectionPresentation(
    val routeLabel: String,
    val modeTitle: String,
    val modeDescription: String,
    val vncTarget: String,
    val sshServer: String = "",
    val pathSummary: String,
    val usesSsh: Boolean = false
)

private fun formatDisplayHostPort(host: String, port: Int): String {
    val trimmedHost = host.trim()
    if (trimmedHost.isBlank()) {
        return "未填写"
    }
    val displayHost = if (trimmedHost.contains(":") && !trimmedHost.startsWith("[")) {
        "[$trimmedHost]"
    } else {
        trimmedHost
    }
    return "$displayHost:$port"
}

private fun buildConnectionPresentation(
    address: String,
    ssh: SshConnectionConfig,
    desktopUser: String = "",
    desktopPassword: String = ""
): ConnectionPresentation {
    val normalizedSsh = resolveSshConfigForConnection(ssh, address, desktopUser, desktopPassword)
    if (!normalizedSsh.enabled) {
        val directTarget = address.trim().ifBlank { "未填写" }
        return ConnectionPresentation(
            routeLabel = "直连",
            modeTitle = "直连模式",
            modeDescription = "本机直接访问远程 VNC 服务器",
            vncTarget = directTarget,
            pathSummary = "本机 -> VNC $directTarget"
        )
    }
    val parsedAddress = parseAddress(address)
    val targetHost = normalizedSsh.remoteHost.ifBlank { parsedAddress?.host.orEmpty() }
    val targetPort = normalizedSsh.remotePort.takeIf { it in 1..65535 } ?: parsedAddress?.port ?: DEFAULT_VNC_PORT
    val sshUserPrefix = normalizedSsh.sshUser.trim().takeIf { it.isNotEmpty() }?.let { "$it@" }.orEmpty()
    val sshServer = "$sshUserPrefix${formatDisplayHostPort(normalizedSsh.sshHost, normalizedSsh.sshPort)}"
    val vncTarget = formatDisplayHostPort(targetHost, targetPort)
    return ConnectionPresentation(
        routeLabel = "SSH 隧道",
        modeTitle = "SSH 中转",
        modeDescription = "先登录 SSH 服务器，再转发到最终 VNC 目标",
        vncTarget = vncTarget,
        sshServer = sshServer,
        pathSummary = "本机 -> SSH $sshServer -> VNC $vncTarget",
        usesSsh = true
    )
}

private fun ConnectionItem.presentation(): ConnectionPresentation =
    buildConnectionPresentation(address, ssh, user, password)

private fun hasConnectionMoreOptions(state: EditConnectionState): Boolean =
    normalizeTouchScrollStep(state.touchScrollStep) > 0

private fun normalizeEditSshConfig(config: SshConnectionConfig?, address: String): SshConnectionConfig {
    val normalized = normalizeSshConfigForAddress(config, address)
    val reuseDesktopCredentials = normalized.reuseDesktopUser || normalized.reuseDesktopPassword
    return normalized.copy(
        reuseDesktopUser = reuseDesktopCredentials,
        reuseDesktopPassword = reuseDesktopCredentials && normalized.authType == SSH_AUTH_PASSWORD
    )
}

private fun isReusingDesktopCredentials(ssh: SshConnectionConfig): Boolean =
    ssh.reuseDesktopUser || ssh.reuseDesktopPassword

private fun shouldAutoFillSshDefaults(ssh: SshConnectionConfig): Boolean {
    // 只要没有配置过 SSH 服务器地址，就认为是未配置状态，可以直接补全默认值模板
    return ssh.sshHost.isBlank()
}

private fun EditConnectionState.withDesktopUser(value: String): EditConnectionState =
    copy(
        user = value,
        ssh = if (isReusingDesktopCredentials(ssh)) {
            ssh.copy(sshUser = value.trim())
        } else {
            ssh
        }
    )

private fun EditConnectionState.withDesktopPassword(value: String): EditConnectionState =
    copy(
        password = value,
        ssh = if (isReusingDesktopCredentials(ssh) && ssh.authType == SSH_AUTH_PASSWORD) {
            ssh.copy(sshPassword = value)
        } else {
            ssh
        }
    )

private fun EditConnectionState.createAutoFilledSshConfig(): SshConnectionConfig {
    val parsed = parseAddress(address.trim())
    val targetHost = parsed?.host.orEmpty()
    val targetPort = parsed?.port ?: DEFAULT_VNC_PORT
    return normalizeEditSshConfig(
        ssh.copy(
            enabled = true,
            sshHost = if (targetHost.isNotBlank()) targetHost else ssh.sshHost,
            sshPort = DEFAULT_SSH_PORT,
            sshUser = user.trim(),
            reuseDesktopUser = true,
            authType = SSH_AUTH_PASSWORD,
            sshPassword = password,
            reuseDesktopPassword = true,
            remoteHost = "127.0.0.1",
            remotePort = targetPort
        ),
        address
    )
}

private fun EditConnectionState.withSshEnabled(enabled: Boolean): EditConnectionState =
    if (enabled) {
        val nextSsh = if (!ssh.enabled && shouldAutoFillSshDefaults(ssh)) {
            createAutoFilledSshConfig()
        } else {
            normalizeEditSshConfig(ssh.copy(enabled = true), address)
        }
        copy(ssh = nextSsh)
    } else {
        copy(ssh = ssh.copy(enabled = false))
    }

private fun EditConnectionState.withSshAuthType(authType: Int): EditConnectionState {
    val reuseDesktopCredentials = isReusingDesktopCredentials(ssh)
    return copy(
        ssh = ssh.copy(
            authType = authType,
            reuseDesktopUser = reuseDesktopCredentials,
            reuseDesktopPassword = reuseDesktopCredentials && authType == SSH_AUTH_PASSWORD
        )
    )
}

private fun EditConnectionState.withSshDesktopReuse(enabled: Boolean): EditConnectionState =
    copy(
        ssh = ssh.copy(
            reuseDesktopUser = enabled,
            reuseDesktopPassword = enabled && ssh.authType == SSH_AUTH_PASSWORD,
            sshUser = if (enabled) user.trim() else ssh.sshUser,
            sshPassword = if (enabled && ssh.authType == SSH_AUTH_PASSWORD) password else ssh.sshPassword
        )
    )

private fun hasAdvancedSshOptions(ssh: SshConnectionConfig): Boolean =
    ssh.sshPort != DEFAULT_SSH_PORT ||
        ssh.publicKeyPath.isNotBlank() ||
        ssh.knownHostsPath.isNotBlank() ||
        ssh.strictHostKeyCheck ||
        ssh.remoteHost.isNotBlank() ||
        ssh.remotePort > 0

private fun hasAnyAdvancedEditOptions(state: EditConnectionState): Boolean =
    hasConnectionMoreOptions(state) || (state.ssh.enabled && hasAdvancedSshOptions(state.ssh))

@Composable
private fun ConnectionRouteBadge(label: String) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.primary,
            fontWeight = FontWeight.SemiBold
        )
    }
}

@Composable
private fun ConnectionPathPreview(
    presentation: ConnectionPresentation,
    modifier: Modifier = Modifier,
    title: String = "连接路径"
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.06f)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        text = presentation.modeTitle,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                ConnectionRouteBadge(presentation.routeLabel)
            }
            Text(
                text = presentation.modeDescription,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.secondary
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                ConnectionFlowChip("本机", modifier = Modifier.weight(1f))
                if (presentation.usesSsh) {
                    ConnectionFlowChip("SSH 服务器", modifier = Modifier.weight(1f), highlighted = true)
                }
                ConnectionFlowChip("VNC 目标", modifier = Modifier.weight(1f), highlighted = !presentation.usesSsh)
            }
            Text(
                text = presentation.pathSummary,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium
            )
        }
    }
}

@Composable
private fun CompactConnectionPreview(
    presentation: ConnectionPresentation,
    modifier: Modifier = Modifier,
    title: String = "当前连接方式"
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.06f)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        text = if (presentation.usesSsh) "经 SSH 安全连接" else "直接连接",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                ConnectionRouteBadge(presentation.routeLabel)
            }
            Text(
                text = presentation.modeDescription,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.secondary
            )
            Text(
                text = presentation.pathSummary,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium
            )
        }
    }
}

@Composable
private fun EditConnectionTabSelector(
    selectedTab: EditConnectionTab,
    advancedConfigured: Boolean,
    onTabSelected: (EditConnectionTab) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Button(
            onClick = { onTabSelected(EditConnectionTab.Basic) },
            modifier = Modifier
                .weight(1f)
                .height(40.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = if (selectedTab == EditConnectionTab.Basic) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
                },
                contentColor = if (selectedTab == EditConnectionTab.Basic) {
                    MaterialTheme.colorScheme.onPrimary
                } else {
                    MaterialTheme.colorScheme.primary
                }
            )
        ) {
            Text("基本")
        }
        Button(
            onClick = { onTabSelected(EditConnectionTab.Advanced) },
            modifier = Modifier
                .weight(1f)
                .height(40.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = if (selectedTab == EditConnectionTab.Advanced) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
                },
                contentColor = if (selectedTab == EditConnectionTab.Advanced) {
                    MaterialTheme.colorScheme.onPrimary
                } else {
                    MaterialTheme.colorScheme.primary
                }
            )
        ) {
            Text(if (advancedConfigured) "高级（已配置）" else "高级")
        }
    }
}

@Composable
private fun BasicEditConnectionContent(
    state: EditConnectionState,
    onStateChange: (EditConnectionState) -> Unit
) {
    ConnectionSectionCard(
        title = "远程桌面"
    ) {
        OutlinedTextField(
            value = state.name,
            onValueChange = { onStateChange(state.copy(name = it)) },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("连接名称") },
            placeholder = { Text("例如 办公室电脑") }
        )
        OutlinedTextField(
            value = state.address,
            onValueChange = { onStateChange(state.copy(address = it)) },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("桌面地址") },
            placeholder = {
                Text(
                    if (state.ssh.enabled) {
                        "例如 192.168.1.2:5900；不单独指定目标时会使用这里"
                    } else {
                        "例如 192.168.1.2:5900"
                    }
                )
            }
        )
        OutlinedTextField(
            value = state.user,
            onValueChange = { onStateChange(state.withDesktopUser(it)) },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("桌面用户名") }
        )
        PasswordField(
            value = state.password,
            onValueChange = { onStateChange(state.withDesktopPassword(it)) },
            modifier = Modifier.fillMaxWidth(),
            label = "桌面密码",
            imeAction = ImeAction.Done
        )
        SettingSwitchRow(
            title = "保存桌面密码",
            checked = state.storePassword,
            onCheckedChange = { onStateChange(state.copy(storePassword = it)) }
        )
    }
}

@Composable
private fun AdvancedEditConnectionContent(
    state: EditConnectionState,
    onStateChange: (EditConnectionState) -> Unit
) {
    ConnectionSectionCard(
        title = "触控滚动",
        description = "调整触摸滚动步长。"
    ) {
        TouchScrollStepSelector(
            selectedStep = state.touchScrollStep,
            onSelect = { onStateChange(state.copy(touchScrollStep = normalizeTouchScrollStep(it))) }
        )
        Text(
            text = "当前：${touchScrollLabel(state.touchScrollStep)}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.secondary
        )
    }
    ConnectionSectionCard(
        title = "SSH",
        description = if (state.ssh.enabled) {
            "先连接 SSH 服务器，再安全转发到目标桌面。默认会重用基本页账号密码，首次开启时转发目标会预填为远端 127.0.0.1。"
        } else {
            "只有桌面需要通过堡垒机、跳板机或内网隧道访问时，才需要开启这里。"
        }
    ) {
        val parsedAddress = parseAddress(state.address.trim())
        val forwardHost = state.ssh.remoteHost.ifBlank { "127.0.0.1" }
        val forwardPort = state.ssh.remotePort.takeIf { it in 1..65535 } ?: parsedAddress?.port ?: DEFAULT_VNC_PORT
        SettingSwitchRow(
            title = "通过 SSH 隧道连接",
            supportingText = if (state.ssh.enabled) {
                "当前转发目标：${formatDisplayHostPort(forwardHost, forwardPort)}"
            } else {
                "开启后会按基本页信息自动补全一套默认 SSH 配置。"
            },
            checked = state.ssh.enabled,
            onCheckedChange = { onStateChange(state.withSshEnabled(it)) }
        )
        if (state.ssh.enabled) {
            val reuseDesktopCredentials = isReusingDesktopCredentials(state.ssh)
            HorizontalDivider()
            Text(
                text = "默认建议保持转发到远端 127.0.0.1，只有需要再跳转到其他内网主机时，才修改下方转发目标。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.secondary
            )
            OutlinedTextField(
                value = state.ssh.sshHost,
                onValueChange = {
                    onStateChange(state.copy(ssh = state.ssh.copy(sshHost = it)))
                },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("SSH 服务器") },
                placeholder = { Text("例如 bastion.example.com") }
            )
            SettingSwitchRow(
                title = "重用桌面账号密码",
                supportingText = when {
                    !reuseDesktopCredentials -> null
                    state.ssh.authType == SSH_AUTH_PUBLIC_KEY && state.user.isBlank() -> "请先在基本页填写桌面用户名"
                    state.ssh.authType == SSH_AUTH_PUBLIC_KEY -> "当前将重用基本页中的桌面用户名"
                    state.user.isBlank() && state.password.isEmpty() -> "请先在基本页填写桌面用户名和密码"
                    state.user.isBlank() -> "请先在基本页填写桌面用户名"
                    state.password.isEmpty() -> "请先在基本页填写桌面密码"
                    else -> "当前将重用基本页中的桌面账号密码"
                },
                checked = reuseDesktopCredentials,
                onCheckedChange = { onStateChange(state.withSshDesktopReuse(it)) }
            )
            if (reuseDesktopCredentials) {
                LockedInheritedField(
                    label = "SSH 用户名",
                    value = state.user.trim().ifBlank { "等待复用基本页中的桌面用户名" },
                    supportingText = if (state.user.isBlank()) {
                        "当前字段由基本页“账号”接管；先在基本页填写后，这里会自动同步。"
                    } else {
                        "当前字段由基本页“账号”接管；关闭上方复用开关后可单独填写。"
                    }
                )
            } else {
                OutlinedTextField(
                    value = state.ssh.sshUser,
                    onValueChange = {
                        onStateChange(state.copy(ssh = state.ssh.copy(sshUser = it)))
                    },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("SSH 用户名") }
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    text = "登录方式",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.secondary,
                    modifier = Modifier.align(Alignment.CenterVertically)
                )
                FilterChip(
                    selected = state.ssh.authType == SSH_AUTH_PASSWORD,
                    onClick = {
                        onStateChange(state.withSshAuthType(SSH_AUTH_PASSWORD))
                    },
                    label = { Text("密码") }
                )
                FilterChip(
                    selected = state.ssh.authType == SSH_AUTH_PUBLIC_KEY,
                    onClick = {
                        onStateChange(state.withSshAuthType(SSH_AUTH_PUBLIC_KEY))
                    },
                    label = { Text("密钥") }
                )
            }
            if (state.ssh.authType == SSH_AUTH_PUBLIC_KEY) {
                OutlinedTextField(
                    value = state.ssh.privateKeyPath,
                    onValueChange = {
                        onStateChange(
                            state.copy(ssh = state.ssh.copy(privateKeyPath = it))
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("私钥路径") }
                )
                PasswordField(
                    value = state.ssh.privateKeyPassphrase,
                    onValueChange = {
                        onStateChange(state.copy(ssh = state.ssh.copy(privateKeyPassphrase = it)))
                    },
                    modifier = Modifier.fillMaxWidth(),
                    label = "私钥口令"
                )
            } else {
                if (reuseDesktopCredentials) {
                    LockedInheritedField(
                        label = "SSH 密码",
                        value = if (state.password.isBlank()) "等待复用基本页中的桌面密码" else "已复用基本页中的桌面密码",
                        supportingText = if (state.password.isBlank()) {
                            "当前字段由基本页“密码”接管；先在基本页填写后，这里会自动同步。"
                        } else {
                            "当前字段由基本页“密码”接管；关闭上方复用开关后可单独填写。"
                        }
                    )
                } else {
                    PasswordField(
                        value = state.ssh.sshPassword,
                        onValueChange = {
                            onStateChange(state.copy(ssh = state.ssh.copy(sshPassword = it)))
                        },
                        modifier = Modifier.fillMaxWidth(),
                        label = "SSH 密码",
                        imeAction = ImeAction.Done
                    )
                }
            }
            OutlinedTextField(
                value = state.ssh.sshPort.toString(),
                onValueChange = {
                    onStateChange(
                        state.copy(ssh = state.ssh.copy(sshPort = it.toIntOrNull() ?: 0))
                    )
                },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("SSH 端口") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
            )
            if (state.ssh.authType == SSH_AUTH_PUBLIC_KEY) {
                OutlinedTextField(
                    value = state.ssh.publicKeyPath,
                    onValueChange = {
                        onStateChange(state.copy(ssh = state.ssh.copy(publicKeyPath = it)))
                    },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("公钥路径（可选）") }
                )
            }
            SettingSwitchRow(
                title = "严格校验主机指纹",
                checked = state.ssh.strictHostKeyCheck,
                onCheckedChange = {
                    onStateChange(state.copy(ssh = state.ssh.copy(strictHostKeyCheck = it)))
                }
            )
            if (state.ssh.strictHostKeyCheck || state.ssh.knownHostsPath.isNotBlank()) {
                OutlinedTextField(
                    value = state.ssh.knownHostsPath,
                    onValueChange = {
                        onStateChange(state.copy(ssh = state.ssh.copy(knownHostsPath = it)))
                    },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("known_hosts 路径") }
                )
            }
            OutlinedTextField(
                value = state.ssh.remoteHost,
                onValueChange = {
                    onStateChange(state.copy(ssh = state.ssh.copy(remoteHost = it)))
                },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("转发目标主机") },
                placeholder = { Text("默认预填 127.0.0.1；需要其他内网主机时再修改") }
            )
            OutlinedTextField(
                value = if (state.ssh.remotePort > 0) state.ssh.remotePort.toString() else "",
                onValueChange = {
                    onStateChange(state.copy(ssh = state.ssh.copy(remotePort = it.toIntOrNull() ?: 0)))
                },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("转发目标端口") },
                placeholder = { Text("默认使用桌面地址中的端口") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
            )
        }
    }
}

@Composable
private fun ConnectionFlowChip(
    label: String,
    modifier: Modifier = Modifier,
    highlighted: Boolean = false
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(999.dp),
        color = if (highlighted) {
            MaterialTheme.colorScheme.primary.copy(alpha = 0.14f)
        } else {
            MaterialTheme.colorScheme.surface
        }
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelMedium,
            color = if (highlighted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.SemiBold
        )
    }
}

@Composable
private fun ConnectionSectionCard(
    title: String,
    description: String? = null,
    content: @Composable () -> Unit
) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                if (!description.isNullOrBlank()) {
                    Text(
                        text = description,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.secondary
                    )
                }
            }
            content()
        }
    }
}

@Composable
private fun SettingSwitchRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    supportingText: String? = null
) {
    val shape = RoundedCornerShape(18.dp)
    val borderColor = if (checked) {
        MaterialTheme.colorScheme.primary.copy(alpha = 0.14f)
    } else {
        MaterialTheme.colorScheme.outline.copy(alpha = 0.18f)
    }
    val containerColor = if (checked) {
        MaterialTheme.colorScheme.primary.copy(alpha = 0.04f)
    } else {
        MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.22f)
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .border(width = 1.dp, color = borderColor, shape = shape)
            .background(color = containerColor, shape = shape)
            .toggleable(
                value = checked,
                role = Role.Switch,
                onValueChange = onCheckedChange
            )
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Medium
            )
            if (!supportingText.isNullOrBlank()) {
                Text(
                    text = supportingText,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.secondary
                )
            }
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Switch(
                checked = checked,
                onCheckedChange = onCheckedChange,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = MaterialTheme.colorScheme.surface,
                    checkedTrackColor = MaterialTheme.colorScheme.primary,
                    checkedBorderColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.22f),
                    uncheckedThumbColor = MaterialTheme.colorScheme.surface,
                    uncheckedTrackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.24f),
                    uncheckedBorderColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.10f)
                ),
                modifier = Modifier.semantics {
                    contentDescription = "$title，${if (checked) "已开启" else "未开启"}"
                }
            )
        }
    }
}

private fun handleConnectionManagerKeyEvent(
    event: androidx.compose.ui.input.key.KeyEvent,
    shortcutsEnabled: Boolean,
    filteredConnections: List<ConnectionItem>,
    selectedConnectionId: String,
    onSelectConnection: (String) -> Unit,
    onOpenConnection: (ConnectionItem) -> Unit,
    onDeleteConnection: (ConnectionItem) -> Unit
): Boolean {
    if (!shortcutsEnabled || filteredConnections.isEmpty()) {
        return false
    }
    val nativeEvent = event.nativeKeyEvent
    if (nativeEvent.isCtrlPressed || nativeEvent.isAltPressed || nativeEvent.isMetaPressed) {
        return false
    }
    val selectedIndex = filteredConnections.indexOfFirst { it.id == selectedConnectionId }
    return when (event.key) {
        Key.DirectionDown -> {
            if (event.type != KeyEventType.KeyDown) {
                return false
            }
            val nextIndex = (if (selectedIndex >= 0) selectedIndex + 1 else 0).coerceAtMost(filteredConnections.lastIndex)
            onSelectConnection(filteredConnections[nextIndex].id)
            true
        }
        Key.DirectionUp -> {
            if (event.type != KeyEventType.KeyDown) {
                return false
            }
            val nextIndex = if (selectedIndex >= 0) {
                (selectedIndex - 1).coerceAtLeast(0)
            } else {
                0
            }
            onSelectConnection(filteredConnections[nextIndex].id)
            true
        }
        Key.Enter,
        Key.NumPadEnter -> {
            if (event.type != KeyEventType.KeyUp || nativeEvent.repeatCount > 0) {
                return false
            }
            val item = filteredConnections.getOrNull(if (selectedIndex >= 0) selectedIndex else 0) ?: return false
            onOpenConnection(item)
            true
        }
        Key.Delete -> {
            if (event.type != KeyEventType.KeyUp || nativeEvent.repeatCount > 0) {
                return false
            }
            val item = filteredConnections.getOrNull(if (selectedIndex >= 0) selectedIndex else 0) ?: return false
            onDeleteConnection(item)
            true
        }
        else -> false
    }
}

private fun touchScrollLabel(step: Int): String {
    val normalized = normalizeTouchScrollStep(step)
    return touchScrollOptions.firstOrNull { it.first == normalized }?.let { (value, label) ->
        if (value <= 0) label else "$label（${value}px）"
    } ?: "自动"
}

private fun getZoomButtonLabel(scale: Float): String {
    return if (scale > 1.05f) {
        "${((scale * 10f).roundToInt()) / 10f}x"
    } else {
        "1x"
    }
}

private fun canUseZoomViewer(placement: RemoteFramePlacement): Boolean {
    return placement.viewerSize.width > 0 &&
        placement.viewerSize.height > 0 &&
        placement.drawSize.width > 0 &&
        placement.drawSize.height > 0
}

private fun clampFloat(value: Float, minValue: Float, maxValue: Float): Float {
    return max(minValue, min(value, maxValue))
}

private fun getViewerCenter(placement: RemoteFramePlacement): Pair<Float, Float> {
    return placement.viewerSize.width / 2f to placement.viewerSize.height / 2f
}

private fun mapViewerPoint(
    x: Float,
    y: Float,
    placement: RemoteFramePlacement,
    zoomState: ViewerZoomState
): Pair<Float, Float> {
    if (!canUseZoomViewer(placement) || zoomState.scale <= VIEWER_ZOOM_MIN_SCALE) {
        return x to y
    }
    val (centerX, centerY) = getViewerCenter(placement)
    return Pair(
        centerX + (x - centerX) * zoomState.scale + zoomState.offsetX,
        centerY + (y - centerY) * zoomState.scale + zoomState.offsetY
    )
}

private fun mapRemoteRectToViewerRect(
    rect: android.graphics.Rect?,
    placement: RemoteFramePlacement,
    zoomState: ViewerZoomState
): androidx.compose.ui.geometry.Rect? {
    if (
        rect == null ||
        placement.drawSize.width <= 0 ||
        placement.drawSize.height <= 0 ||
        placement.frameSize.width <= 0 ||
        placement.frameSize.height <= 0
    ) {
        return null
    }

    val drawScaleX = placement.drawSize.width.toFloat() / placement.frameSize.width
    val drawScaleY = placement.drawSize.height.toFloat() / placement.frameSize.height
    val mappedLeft = placement.offset.x + rect.left * drawScaleX
    val mappedTop = placement.offset.y + rect.top * drawScaleY
    val mappedRight = placement.offset.x + rect.right * drawScaleX
    val mappedBottom = placement.offset.y + rect.bottom * drawScaleY
    val (finalLeft, finalTop) = mapViewerPoint(mappedLeft, mappedTop, placement, zoomState)
    val (finalRight, finalBottom) = mapViewerPoint(mappedRight, mappedBottom, placement, zoomState)

    return androidx.compose.ui.geometry.Rect(
        left = min(finalLeft, finalRight),
        top = min(finalTop, finalBottom),
        right = max(finalLeft, finalRight),
        bottom = max(finalTop, finalBottom)
    )
}

private fun isRemotePointAllowed(
    point: Pair<Int, Int>?,
    allowedRect: android.graphics.Rect?
): Boolean {
    if (point == null) {
        return false
    }
    if (allowedRect == null) {
        return true
    }
    return point.first >= allowedRect.left &&
        point.first < allowedRect.right &&
        point.second >= allowedRect.top &&
        point.second < allowedRect.bottom
}

private fun clampZoomState(
    placement: RemoteFramePlacement,
    zoomState: ViewerZoomState,
    currentMonitorRect: android.graphics.Rect? = null
): ViewerZoomState {
    if (!canUseZoomViewer(placement)) {
        return ViewerZoomState()
    }
    val scale = max(VIEWER_ZOOM_MIN_SCALE, zoomState.scale)
    val (centerX, centerY) = getViewerCenter(placement)
    
    val baseW = placement.drawSize.width
    val baseH = placement.drawSize.height
    
    val viewL = if (currentMonitorRect != null) {
        currentMonitorRect.left.toFloat() / placement.frameSize.width * baseW
    } else { 0f }
    val viewT = if (currentMonitorRect != null) {
        currentMonitorRect.top.toFloat() / placement.frameSize.height * baseH
    } else { 0f }
    val viewR = if (currentMonitorRect != null) {
        currentMonitorRect.right.toFloat() / placement.frameSize.width * baseW
    } else { baseW.toFloat() }
    val viewB = if (currentMonitorRect != null) {
        currentMonitorRect.bottom.toFloat() / placement.frameSize.height * baseH
    } else { baseH.toFloat() }

    val scaledLeft = centerX + (placement.offset.x + viewL - centerX) * scale
    val scaledTop = centerY + (placement.offset.y + viewT - centerY) * scale
    val scaledW = (viewR - viewL) * scale
    val scaledH = (viewB - viewT) * scale

    var minOffsetX = placement.viewerSize.width - (scaledLeft + scaledW)
    var maxOffsetX = -scaledLeft
    if (minOffsetX > maxOffsetX) {
        val centerOffset = (minOffsetX + maxOffsetX) / 2f
        minOffsetX = centerOffset
        maxOffsetX = centerOffset
    }
    
    val expandX = placement.viewerSize.width / 2f
    minOffsetX -= expandX
    maxOffsetX += expandX

    var minOffsetY = placement.viewerSize.height - (scaledTop + scaledH)
    var maxOffsetY = -scaledTop
    if (minOffsetY > maxOffsetY) {
        val centerOffset = (minOffsetY + maxOffsetY) / 2f
        minOffsetY = centerOffset
        maxOffsetY = centerOffset
    }
    
    val expandY = placement.viewerSize.height / 2f
    minOffsetY -= expandY
    maxOffsetY += expandY

    val nextOffsetX = clampFloat(zoomState.offsetX, minOffsetX, maxOffsetX)
    val nextOffsetY = clampFloat(zoomState.offsetY, minOffsetY, maxOffsetY)

    return zoomState.copy(scale = scale, offsetX = nextOffsetX, offsetY = nextOffsetY)
}

private fun setViewerZoom(
    nextScale: Float,
    anchorX: Float,
    anchorY: Float,
    placement: RemoteFramePlacement,
    currentZoomState: ViewerZoomState,
    currentMonitorRect: android.graphics.Rect? = null
): ViewerZoomState {
    if (!canUseZoomViewer(placement)) {
        return ViewerZoomState()
    }
    val scale = clampFloat(nextScale, VIEWER_ZOOM_MIN_SCALE, VIEWER_ZOOM_MAX_SCALE)
    if (scale <= VIEWER_ZOOM_MIN_SCALE) {
        return ViewerZoomState()
    }
    val basePoint = placement.toBaseViewerPoint(anchorX, anchorY, currentZoomState)
    val (centerX, centerY) = getViewerCenter(placement)
    return clampZoomState(
        placement = placement,
        zoomState = ViewerZoomState(
            scale = scale,
            offsetX = anchorX - centerX - (basePoint.first - centerX) * scale,
            offsetY = anchorY - centerY - (basePoint.second - centerY) * scale
        ),
        currentMonitorRect = currentMonitorRect
    )
}

private fun stepViewerZoom(
    currentZoomState: ViewerZoomState,
    delta: Float,
    placement: RemoteFramePlacement,
    currentMonitorRect: android.graphics.Rect? = null
): ViewerZoomState {
    val (centerX, centerY) = getViewerCenter(placement)
    return setViewerZoom(
        nextScale = currentZoomState.scale + delta,
        anchorX = centerX,
        anchorY = centerY,
        placement = placement,
        currentZoomState = currentZoomState,
        currentMonitorRect = currentMonitorRect
    )
}

private fun quickToggleViewerZoom(
    currentZoomState: ViewerZoomState,
    placement: RemoteFramePlacement,
    currentMonitorRect: android.graphics.Rect? = null
): ViewerZoomState {
    val (centerX, centerY) = getViewerCenter(placement)
    return if (currentZoomState.scale > 1.05f) {
        ViewerZoomState()
    } else {
        setViewerZoom(
            nextScale = 2f,
            anchorX = centerX,
            anchorY = centerY,
            placement = placement,
            currentZoomState = currentZoomState,
            currentMonitorRect = currentMonitorRect
        )
    }
}

private fun pointerMaskFromButtons(buttonState: Int): Int {
    var mask = 0
    if (buttonState and MotionEvent.BUTTON_PRIMARY != 0) {
        mask = mask or 1
    }
    if (buttonState and MotionEvent.BUTTON_TERTIARY != 0) {
        mask = mask or 2
    }
    if (buttonState and MotionEvent.BUTTON_SECONDARY != 0) {
        mask = mask or 4
    }
    return mask
}

private fun isMouseEvent(event: MotionEvent): Boolean {
    return event.source and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE
}

private fun getTouchCenter(event: MotionEvent): Pair<Float, Float>? {
    if (event.pointerCount < 2) {
        return null
    }
    return ((event.getX(0) + event.getX(1)) / 2f) to ((event.getY(0) + event.getY(1)) / 2f)
}

private fun getTouchDistance(event: MotionEvent): Float {
    if (event.pointerCount < 2) {
        return 0f
    }
    val dx = event.getX(0) - event.getX(1)
    val dy = event.getY(0) - event.getY(1)
    return sqrt(dx * dx + dy * dy)
}

private fun handleInspectTap(
    localX: Float,
    localY: Float,
    eventTime: Long,
    placement: RemoteFramePlacement,
    zoomState: ViewerZoomState,
    inputState: ViewerInputState,
    currentMonitorRect: android.graphics.Rect? = null
): ViewerZoomState {
    val withinWindow = eventTime - inputState.lastInspectTapTs <= VIEWER_INSPECT_DOUBLE_TAP_MS
    val nearPrev = abs(localX - inputState.lastInspectTapX) + abs(localY - inputState.lastInspectTapY) <= 28f
    if (withinWindow && nearPrev) {
        inputState.lastInspectTapTs = 0L
        return if (zoomState.scale > 1.05f) {
            ViewerZoomState()
        } else {
            setViewerZoom(
                nextScale = 2f,
                anchorX = localX,
                anchorY = localY,
                placement = placement,
                currentZoomState = zoomState,
                currentMonitorRect = currentMonitorRect
            )
        }
    }
    inputState.lastInspectTapTs = eventTime
    inputState.lastInspectTapX = localX
    inputState.lastInspectTapY = localY
    return zoomState
}

private fun handleInspectMotionEvent(
    event: MotionEvent,
    placement: RemoteFramePlacement,
    inputState: ViewerInputState,
    zoomState: ViewerZoomState,
    onZoomStateChange: (ViewerZoomState) -> Unit,
    currentMonitorRect: android.graphics.Rect? = null
): Boolean {
    if (!canUseZoomViewer(placement)) {
        return true
    }

    if (event.pointerCount >= 2) {
        val center = getTouchCenter(event)
        val distance = getTouchDistance(event)
        if (center != null && distance > 0f) {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN,
                MotionEvent.ACTION_POINTER_DOWN -> {
                    inputState.pinchActive = true
                    inputState.pinchStartDistance = distance
                    inputState.pinchStartScale = zoomState.scale
                    val basePoint = placement.toBaseViewerPoint(center.first, center.second, zoomState)
                    inputState.pinchAnchorBaseX = basePoint.first
                    inputState.pinchAnchorBaseY = basePoint.second
                    inputState.inspectTouchMoved = true
                    inputState.touchMoved = true
                    return true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (!inputState.pinchActive) {
                        inputState.pinchActive = true
                        inputState.pinchStartDistance = distance
                        inputState.pinchStartScale = zoomState.scale
                        val basePoint = placement.toBaseViewerPoint(center.first, center.second, zoomState)
                        inputState.pinchAnchorBaseX = basePoint.first
                        inputState.pinchAnchorBaseY = basePoint.second
                    } else {
                        val scale = clampFloat(
                            inputState.pinchStartScale * (distance / max(1f, inputState.pinchStartDistance)),
                            VIEWER_ZOOM_MIN_SCALE,
                            VIEWER_ZOOM_MAX_SCALE
                        )
                        val (viewerCenterX, viewerCenterY) = getViewerCenter(placement)
                        onZoomStateChange(
                            clampZoomState(
                                placement = placement,
                                zoomState = ViewerZoomState(
                                    scale = scale,
                                    offsetX = center.first - viewerCenterX - (inputState.pinchAnchorBaseX - viewerCenterX) * scale,
                                    offsetY = center.second - viewerCenterY - (inputState.pinchAnchorBaseY - viewerCenterY) * scale
                                ),
                                currentMonitorRect = currentMonitorRect
                            )
                        )
                    }
                    inputState.inspectTouchMoved = true
                    return true
                }
            }
        }
    }

    when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
            inputState.touchStartX = event.x
            inputState.touchStartY = event.y
            inputState.touchStartTs = event.eventTime
            inputState.touchMoved = false
            inputState.inspectTouchMoved = false
            inputState.touchScrollLastX = event.x
            inputState.touchScrollLastY = event.y
            return true
        }

        MotionEvent.ACTION_MOVE -> {
            val distance = abs(event.x - inputState.touchStartX) + abs(event.y - inputState.touchStartY)
            if (distance >= VIEWER_INSPECT_MOVE_SLOP_PX) {
                inputState.touchMoved = true
            }
            val deltaX = event.x - inputState.touchScrollLastX
            val deltaY = event.y - inputState.touchScrollLastY
            inputState.touchScrollLastX = event.x
            inputState.touchScrollLastY = event.y
            if (zoomState.scale > VIEWER_ZOOM_MIN_SCALE + 0.01f) {
                onZoomStateChange(
                    clampZoomState(
                        placement = placement,
                        zoomState = zoomState.copy(
                            offsetX = zoomState.offsetX + deltaX,
                            offsetY = zoomState.offsetY + deltaY
                        ),
                        currentMonitorRect = currentMonitorRect
                    )
                )
            }
            inputState.inspectTouchMoved = inputState.inspectTouchMoved || inputState.touchMoved
            return true
        }

        MotionEvent.ACTION_POINTER_UP,
        MotionEvent.ACTION_UP -> {
            inputState.pinchActive = false
            if (!inputState.touchMoved && !inputState.inspectTouchMoved) {
                onZoomStateChange(
                    handleInspectTap(
                        localX = event.x,
                        localY = event.y,
                        eventTime = event.eventTime,
                        placement = placement,
                        zoomState = zoomState,
                        inputState = inputState,
                        currentMonitorRect = currentMonitorRect
                    )
                )
            }
            return true
        }

        MotionEvent.ACTION_CANCEL -> {
            inputState.pinchActive = false
            inputState.touchMoved = false
            inputState.inspectTouchMoved = false
            return true
        }
    }
    return true
}

private fun handleViewerMotionEvent(
    event: MotionEvent,
    placement: RemoteFramePlacement,
    session: ViewerSession,
    touchScrollStep: Int,
    inputState: ViewerInputState,
    interactionMode: ViewerInteractionMode,
    zoomState: ViewerZoomState,
    onZoomStateChange: (ViewerZoomState) -> Unit
): Boolean {
    if (!session.connected) {
        return false
    }

    val allowedRect = session.currentMonitorRect
    val mapAllowedRemote: (Float, Float) -> Pair<Int, Int>? = { x, y ->
        placement.mapToRemote(x, y, zoomState)?.takeIf { isRemotePointAllowed(it, allowedRect) }
    }

    if (isMouseEvent(event)) {
        val remote = mapAllowedRemote(event.x, event.y)
        if (remote == null) {
            if (
                (event.buttonState != 0 || event.actionMasked == MotionEvent.ACTION_CANCEL) &&
                session.lastPointerX >= 0 &&
                session.lastPointerY >= 0
            ) {
                session.sendPointer(session.lastPointerX, session.lastPointerY, 0)
            }
            return true
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_SCROLL -> {
                val delta = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
                if (delta == 0f) {
                    return false
                }
                val repeatCount = max(1, abs(delta).roundToInt())
                val scrollMask = if (delta > 0f) 8 else 16
                session.sendScrollAt(
                    x = remote.first,
                    y = remote.second,
                    mask = scrollMask,
                    baseMask = pointerMaskFromButtons(event.buttonState),
                    repeatCount = repeatCount
                )
                return true
            }

            MotionEvent.ACTION_HOVER_MOVE,
            MotionEvent.ACTION_MOVE,
            MotionEvent.ACTION_DOWN,
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_BUTTON_PRESS,
            MotionEvent.ACTION_BUTTON_RELEASE -> {
                session.sendPointer(remote.first, remote.second, pointerMaskFromButtons(event.buttonState))
                return true
            }

            MotionEvent.ACTION_CANCEL -> {
                session.sendPointer(remote.first, remote.second, 0)
                return true
            }
        }
        return false
    }

    if (interactionMode == ViewerInteractionMode.Inspect) {
        return handleInspectMotionEvent(
            event = event,
            placement = placement,
            inputState = inputState,
            zoomState = zoomState,
            onZoomStateChange = onZoomStateChange,
            currentMonitorRect = session.currentMonitorRect
        )
    }

    val center = getTouchCenter(event)
    if (center != null) {
        val remote = mapAllowedRemote(center.first, center.second)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN,
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (inputState.touchDragging) {
                    val dragRemote = mapAllowedRemote(center.first, center.second)
                    if (dragRemote != null) {
                        session.sendPointer(dragRemote.first, dragRemote.second, 0)
                    }
                }
                inputState.touchMoved = true
                inputState.touchDragging = false
                inputState.touchScrollActive = true
                inputState.touchScrollLastX = center.first
                inputState.touchScrollLastY = center.second
                inputState.touchScrollResidualY = 0f
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                if (remote == null) {
                    return true
                }
                if (!inputState.touchScrollActive) {
                    inputState.touchScrollActive = true
                    inputState.touchScrollLastX = center.first
                    inputState.touchScrollLastY = center.second
                    inputState.touchScrollResidualY = 0f
                    return true
                }
                val stepPx = getTouchScrollStepPx(touchScrollStep)
                inputState.touchScrollResidualY += center.second - inputState.touchScrollLastY
                inputState.touchScrollLastX = center.first
                inputState.touchScrollLastY = center.second
                var clickCount = 0
                var mask = 0
                while (abs(inputState.touchScrollResidualY) >= stepPx && clickCount < 20) {
                    if (inputState.touchScrollResidualY > 0f) {
                        mask = 16
                        inputState.touchScrollResidualY -= stepPx
                    } else {
                        mask = 8
                        inputState.touchScrollResidualY += stepPx
                    }
                    clickCount++
                }
                if (clickCount > 0) {
                    session.sendScrollAt(remote.first, remote.second, mask, repeatCount = clickCount)
                }
                return true
            }

            MotionEvent.ACTION_POINTER_UP,
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_CANCEL -> {
                inputState.touchScrollActive = false
                inputState.touchScrollResidualY = 0f
                if (remote != null) {
                    session.sendPointer(remote.first, remote.second, 0)
                }
                return true
            }
        }
    }

    val remote = mapAllowedRemote(event.x, event.y)
    when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
            inputState.touchStartX = event.x
            inputState.touchStartY = event.y
            inputState.touchStartTs = event.eventTime
            inputState.touchMoved = false
            inputState.touchDragging = false
            remote?.let { session.sendPointer(it.first, it.second, 0) }
            return true
        }

        MotionEvent.ACTION_MOVE -> {
            val current = if (remote != null) {
                remote
            } else {
                if (inputState.touchDragging && session.lastPointerX >= 0 && session.lastPointerY >= 0) {
                    session.sendPointer(session.lastPointerX, session.lastPointerY, 0)
                    inputState.touchDragging = false
                }
                return true
            }
            val distance = abs(event.x - inputState.touchStartX) + abs(event.y - inputState.touchStartY)
            if (distance >= 6f) {
                inputState.touchMoved = true
            }
            if (inputState.touchMoved && !inputState.touchDragging) {
                inputState.touchDragging = true
                mapAllowedRemote(inputState.touchStartX, inputState.touchStartY)?.let { start ->
                    session.sendPointer(start.first, start.second, 1)
                }
            }
            session.sendPointer(current.first, current.second, if (inputState.touchDragging) 1 else 0)
            return true
        }

        MotionEvent.ACTION_UP -> {
            val current = remote ?: mapAllowedRemote(inputState.touchStartX, inputState.touchStartY)
            if (current != null) {
                val clickElapsed = event.eventTime - inputState.touchStartTs
                if (inputState.touchDragging) {
                    session.sendPointer(current.first, current.second, 0)
                } else if (!inputState.touchMoved && clickElapsed <= 350L) {
                    session.sendClick(current.first, current.second, 1)
                } else {
                    session.sendPointer(current.first, current.second, 0)
                }
            }
            inputState.touchDragging = false
            inputState.touchMoved = false
            inputState.touchScrollActive = false
            inputState.touchScrollResidualY = 0f
            return true
        }

        MotionEvent.ACTION_CANCEL -> {
            val current = remote
            if (current != null) {
                session.sendPointer(current.first, current.second, 0)
            } else {
                session.sendPointer(session.lastPointerX, session.lastPointerY, 0)
            }
            inputState.touchDragging = false
            inputState.touchMoved = false
            inputState.touchScrollActive = false
            inputState.touchScrollResidualY = 0f
            return true
        }
    }
    return false
}

private fun keySymFromAndroidKey(code: Int, shiftDown: Boolean, capsOn: Boolean): Int {
    if (code in android.view.KeyEvent.KEYCODE_A..android.view.KeyEvent.KEYCODE_Z) {
        val uppercase = capsOn.xor(shiftDown)
        val base = if (uppercase) 'A'.code else 'a'.code
        return base + (code - android.view.KeyEvent.KEYCODE_A)
    }

    if (code in android.view.KeyEvent.KEYCODE_0..android.view.KeyEvent.KEYCODE_9) {
        val shifted = listOf(')', '!', '@', '#', '$', '%', '^', '&', '*', '(')
        return if (shiftDown) shifted[code - android.view.KeyEvent.KEYCODE_0].code else '0'.code + (code - android.view.KeyEvent.KEYCODE_0)
    }

    return when (code) {
        android.view.KeyEvent.KEYCODE_ENTER -> 0xff0d
        android.view.KeyEvent.KEYCODE_DEL -> 0xff08
        android.view.KeyEvent.KEYCODE_FORWARD_DEL -> 0xffff
        android.view.KeyEvent.KEYCODE_ESCAPE -> 0xff1b
        android.view.KeyEvent.KEYCODE_BACK -> 0xff1b
        android.view.KeyEvent.KEYCODE_DPAD_LEFT -> 0xff51
        android.view.KeyEvent.KEYCODE_DPAD_UP -> 0xff52
        android.view.KeyEvent.KEYCODE_DPAD_RIGHT -> 0xff53
        android.view.KeyEvent.KEYCODE_DPAD_DOWN -> 0xff54
        android.view.KeyEvent.KEYCODE_TAB -> 0xff09
        android.view.KeyEvent.KEYCODE_SPACE -> 0x20
        android.view.KeyEvent.KEYCODE_SHIFT_LEFT -> 0xffe1
        android.view.KeyEvent.KEYCODE_SHIFT_RIGHT -> 0xffe2
        android.view.KeyEvent.KEYCODE_CTRL_LEFT -> 0xffe3
        android.view.KeyEvent.KEYCODE_CTRL_RIGHT -> 0xffe4
        android.view.KeyEvent.KEYCODE_ALT_LEFT -> 0xffe9
        android.view.KeyEvent.KEYCODE_ALT_RIGHT -> 0xffea
        android.view.KeyEvent.KEYCODE_META_LEFT -> 0xffe7
        android.view.KeyEvent.KEYCODE_META_RIGHT -> 0xffe8
        android.view.KeyEvent.KEYCODE_COMMA -> if (shiftDown) '<'.code else ','.code
        android.view.KeyEvent.KEYCODE_PERIOD -> if (shiftDown) '>'.code else '.'.code
        android.view.KeyEvent.KEYCODE_MINUS -> if (shiftDown) '_'.code else '-'.code
        android.view.KeyEvent.KEYCODE_EQUALS -> if (shiftDown) '+'.code else '='.code
        android.view.KeyEvent.KEYCODE_LEFT_BRACKET -> if (shiftDown) '{'.code else '['.code
        android.view.KeyEvent.KEYCODE_RIGHT_BRACKET -> if (shiftDown) '}'.code else ']'.code
        android.view.KeyEvent.KEYCODE_BACKSLASH -> if (shiftDown) '|'.code else '\\'.code
        android.view.KeyEvent.KEYCODE_SEMICOLON -> if (shiftDown) ':'.code else ';'.code
        android.view.KeyEvent.KEYCODE_APOSTROPHE -> if (shiftDown) '"'.code else '\''.code
        android.view.KeyEvent.KEYCODE_SLASH -> if (shiftDown) '?'.code else '/'.code
        android.view.KeyEvent.KEYCODE_GRAVE -> if (shiftDown) '~'.code else '`'.code
        android.view.KeyEvent.KEYCODE_MOVE_HOME -> 0xff50
        android.view.KeyEvent.KEYCODE_MOVE_END -> 0xff57
        android.view.KeyEvent.KEYCODE_PAGE_UP -> 0xff55
        android.view.KeyEvent.KEYCODE_PAGE_DOWN -> 0xff56
        android.view.KeyEvent.KEYCODE_INSERT -> 0xff63
        android.view.KeyEvent.KEYCODE_CAPS_LOCK -> 0xffe5
        android.view.KeyEvent.KEYCODE_SCROLL_LOCK -> 0xff14
        android.view.KeyEvent.KEYCODE_NUM_LOCK -> 0xff7f
        android.view.KeyEvent.KEYCODE_NUMPAD_0 -> 0xffb0
        android.view.KeyEvent.KEYCODE_NUMPAD_1 -> 0xffb1
        android.view.KeyEvent.KEYCODE_NUMPAD_2 -> 0xffb2
        android.view.KeyEvent.KEYCODE_NUMPAD_3 -> 0xffb3
        android.view.KeyEvent.KEYCODE_NUMPAD_4 -> 0xffb4
        android.view.KeyEvent.KEYCODE_NUMPAD_5 -> 0xffb5
        android.view.KeyEvent.KEYCODE_NUMPAD_6 -> 0xffb6
        android.view.KeyEvent.KEYCODE_NUMPAD_7 -> 0xffb7
        android.view.KeyEvent.KEYCODE_NUMPAD_8 -> 0xffb8
        android.view.KeyEvent.KEYCODE_NUMPAD_9 -> 0xffb9
        android.view.KeyEvent.KEYCODE_NUMPAD_DIVIDE -> 0xffaf
        android.view.KeyEvent.KEYCODE_NUMPAD_MULTIPLY -> 0xffaa
        android.view.KeyEvent.KEYCODE_NUMPAD_SUBTRACT -> 0xffad
        android.view.KeyEvent.KEYCODE_NUMPAD_ADD -> 0xffab
        android.view.KeyEvent.KEYCODE_NUMPAD_DOT -> 0xffae
        android.view.KeyEvent.KEYCODE_NUMPAD_EQUALS -> 0xffbd
        android.view.KeyEvent.KEYCODE_NUMPAD_ENTER -> 0xff8d
        android.view.KeyEvent.KEYCODE_SYSRQ -> 0xff15
        android.view.KeyEvent.KEYCODE_BREAK -> 0xff6b
        android.view.KeyEvent.KEYCODE_F1 -> 0xffbe
        android.view.KeyEvent.KEYCODE_F2 -> 0xffbf
        android.view.KeyEvent.KEYCODE_F3 -> 0xffc0
        android.view.KeyEvent.KEYCODE_F4 -> 0xffc1
        android.view.KeyEvent.KEYCODE_F5 -> 0xffc2
        android.view.KeyEvent.KEYCODE_F6 -> 0xffc3
        android.view.KeyEvent.KEYCODE_F7 -> 0xffc4
        android.view.KeyEvent.KEYCODE_F8 -> 0xffc5
        android.view.KeyEvent.KEYCODE_F9 -> 0xffc6
        android.view.KeyEvent.KEYCODE_F10 -> 0xffc7
        android.view.KeyEvent.KEYCODE_F11 -> 0xffc8
        android.view.KeyEvent.KEYCODE_F12 -> 0xffc9
        else -> 0
    }
}
