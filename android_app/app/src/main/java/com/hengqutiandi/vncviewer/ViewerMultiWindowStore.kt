package com.hengqutiandi.vncviewer

import android.graphics.Bitmap
import android.graphics.Rect

data class SharedViewerRect(
    val x: Int,
    val y: Int,
    val w: Int,
    val h: Int
)

interface VncClientLike {
    fun sendPointer(x: Int, y: Int, mask: Int)
    fun sendKey(keysym: Int, down: Boolean)
}

data class SharedViewerSessionSnapshot(
    val sessionId: String,
    val title: String,
    val connected: Boolean,
    val fbW: Int,
    val fbH: Int,
    val frameVersion: Int,
    val updatedAt: Long,
    val frame: Bitmap?,
    val monitors: List<SharedViewerRect>
)

data class ViewerWindowBinding(
    val windowName: String,
    val sessionId: String,
    val monitorIndex: Int,
    val title: String
)

private class ViewerSessionEntry(val sessionId: String) {
    var snapshot = SharedViewerSessionSnapshot(
        sessionId = sessionId,
        title = "",
        connected = false,
        fbW = 0,
        fbH = 0,
        frameVersion = 0,
        updatedAt = 0L,
        frame = null,
        monitors = emptyList()
    )
    val windowNames = mutableListOf<String>()
    var vncClient: VncClientLike? = null
}

class ViewerMultiWindowStore private constructor() {
    private val sessions = mutableMapOf<String, ViewerSessionEntry>()
    private val windowBindings = mutableMapOf<String, ViewerWindowBinding>()
    private val claimedWindows = mutableSetOf<String>()
    private val lock = Any()

    companion object {
        @Volatile
        private var instance: ViewerMultiWindowStore? = null

        fun getInstance(): ViewerMultiWindowStore {
            return instance ?: synchronized(this) {
                instance ?: ViewerMultiWindowStore().also { instance = it }
            }
        }
    }

    private fun getOrCreateSession(sessionId: String): ViewerSessionEntry {
        return synchronized(lock) {
            sessions.getOrPut(sessionId) { ViewerSessionEntry(sessionId) }
        }
    }

    private fun cloneRects(rects: List<SharedViewerRect>): List<SharedViewerRect> {
        return rects.map { SharedViewerRect(it.x, it.y, it.w, it.h) }
    }

    fun ensureSession(sessionId: String) {
        getOrCreateSession(sessionId)
    }

    fun updateSessionTitle(sessionId: String, title: String) {
        synchronized(lock) {
            getOrCreateSession(sessionId).snapshot = getOrCreateSession(sessionId).snapshot.copy(title = title)
        }
    }

    fun updateSessionConnectionState(sessionId: String, connected: Boolean) {
        synchronized(lock) {
            val entry = getOrCreateSession(sessionId)
            entry.snapshot = entry.snapshot.copy(connected = connected, updatedAt = System.currentTimeMillis())
        }
    }

    fun updateSessionMonitors(sessionId: String, monitors: List<SharedViewerRect>) {
        synchronized(lock) {
            val entry = getOrCreateSession(sessionId)
            entry.snapshot = entry.snapshot.copy(
                monitors = cloneRects(monitors),
                updatedAt = System.currentTimeMillis()
            )
        }
    }

    fun publishFrame(
        sessionId: String,
        title: String,
        connected: Boolean,
        fbW: Int,
        fbH: Int,
        frame: Bitmap?,
        monitors: List<SharedViewerRect>
    ) {
        synchronized(lock) {
            val entry = getOrCreateSession(sessionId)
            entry.snapshot = entry.snapshot.copy(
                title = title,
                connected = connected,
                fbW = maxOf(0, fbW),
                fbH = maxOf(0, fbH),
                frame = frame,
                monitors = cloneRects(monitors),
                frameVersion = entry.snapshot.frameVersion + 1,
                updatedAt = System.currentTimeMillis()
            )
        }
    }

    fun clearSessionFrame(sessionId: String, title: String) {
        synchronized(lock) {
            val entry = getOrCreateSession(sessionId)
            val oldFrame = entry.snapshot.frame
            entry.snapshot = entry.snapshot.copy(
                title = title,
                connected = false,
                fbW = 0,
                fbH = 0,
                frame = null,
                monitors = emptyList(),
                frameVersion = entry.snapshot.frameVersion + 1,
                updatedAt = System.currentTimeMillis()
            )
            if (oldFrame != null && !oldFrame.isRecycled) {
                try { oldFrame.recycle() } catch (_: Throwable) {}
            }
        }
    }

    fun getSessionSnapshot(sessionId: String): SharedViewerSessionSnapshot? {
        return synchronized(lock) {
            val entry = sessions[sessionId] ?: return@synchronized null
            val currentFrame = entry.snapshot.frame
            val clonedFrame = if (currentFrame != null && !currentFrame.isRecycled) {
                currentFrame.copy(currentFrame.config ?: Bitmap.Config.ARGB_8888, true)
            } else null
            entry.snapshot.copy(
                monitors = cloneRects(entry.snapshot.monitors),
                frame = clonedFrame
            )
        }
    }

    fun registerWindow(binding: ViewerWindowBinding) {
        synchronized(lock) {
            val entry = getOrCreateSession(binding.sessionId)
            windowBindings[binding.windowName] = binding
            if (!entry.windowNames.contains(binding.windowName)) {
                entry.windowNames.add(binding.windowName)
            }
        }
    }

    fun getWindowBinding(windowName: String): ViewerWindowBinding? {
        return synchronized(lock) {
            windowBindings[windowName]?.copy()
        }
    }

    fun removeWindow(windowName: String) {
        synchronized(lock) {
            val binding = windowBindings[windowName] ?: return@synchronized
            windowBindings.remove(windowName)
            claimedWindows.remove(windowName)
            val entry = sessions[binding.sessionId] ?: return@synchronized
            entry.windowNames.remove(windowName)
        }
    }

    fun isWindowClaimed(windowName: String): Boolean {
        return synchronized(lock) { claimedWindows.contains(windowName) }
    }

    fun claimWindow(windowName: String) {
        synchronized(lock) { claimedWindows.add(windowName) }
    }

    fun listWindowNames(sessionId: String): List<String> {
        return synchronized(lock) {
            sessions[sessionId]?.windowNames?.toList() ?: emptyList()
        }
    }

    fun listAllSessions(): List<String> {
        return synchronized(lock) { sessions.keys.toList() }
    }

    fun setVncClient(sessionId: String, client: VncClientLike?) {
        synchronized(lock) { getOrCreateSession(sessionId).vncClient = client }
    }

    fun getVncClient(sessionId: String): VncClientLike? {
        return synchronized(lock) { sessions[sessionId]?.vncClient }
    }

    fun disposeSession(sessionId: String) {
        synchronized(lock) {
            val entry = sessions[sessionId] ?: return@synchronized
            val names = entry.windowNames.toList()
            for (name in names) {
                windowBindings.remove(name)
            }
            val oldFrame = entry.snapshot.frame
            sessions.remove(sessionId)
            if (oldFrame != null && !oldFrame.isRecycled) {
                try { oldFrame.recycle() } catch (_: Throwable) {}
            }
        }
    }
}

val viewerMultiWindowStore = ViewerMultiWindowStore.getInstance()

fun Rect.toSharedRect(): SharedViewerRect {
    return SharedViewerRect(left, top, width(), height())
}
