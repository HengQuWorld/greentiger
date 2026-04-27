package com.hengqutiandi.vncviewer.native

import android.graphics.Bitmap

data class FramebufferInfo(
    val width: Int,
    val height: Int,
    val stride: Int,
    val state: Int
)

data class DamageRect(
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int
)

data class SshTunnelConfig(
    val enabled: Boolean,
    val sshHost: String,
    val sshPort: Int = 22,
    val sshUser: String,
    val authType: Int = AUTH_PASSWORD,
    val sshPassword: String = "",
    val privateKeyPath: String = "",
    val publicKeyPath: String = "",
    val privateKeyPassphrase: String = "",
    val knownHostsPath: String = "",
    val strictHostKeyCheck: Boolean = false,
    val remoteHost: String = "",
    val remotePort: Int = 0
) {
    companion object {
        const val AUTH_NONE = 0
        const val AUTH_PASSWORD = 1
        const val AUTH_PUBLIC_KEY = 2
    }
}

class VncClient : AutoCloseable {
    private var handle: Long = nativeCreate()

    fun connect(host: String, port: Int, user: String, password: String): Int =
        nativeConnect(handle, host, port, user, password)

    fun setSshTunnel(config: SshTunnelConfig): Int =
        nativeSetSshTunnel(
            handle = handle,
            enabled = config.enabled,
            sshHost = config.sshHost,
            sshPort = config.sshPort,
            sshUser = config.sshUser,
            authType = config.authType,
            sshPassword = config.sshPassword,
            privateKeyPath = config.privateKeyPath,
            publicKeyPath = config.publicKeyPath,
            privateKeyPassphrase = config.privateKeyPassphrase,
            knownHostsPath = config.knownHostsPath,
            strictHostKeyCheck = config.strictHostKeyCheck,
            remoteHost = config.remoteHost,
            remotePort = config.remotePort
        )

    fun clearSshTunnel() {
        nativeClearSshTunnel(handle)
    }

    fun disconnect() {
        if (handle != 0L) {
            nativeDisconnect(handle)
        }
    }

    fun process(): Int = nativeProcess(handle)

    fun refresh(): Int = nativeRefresh(handle)

    fun requestUpdate(incremental: Boolean = true): Int = nativeRequestUpdate(handle, incremental)

    fun getFramebufferInfo(): FramebufferInfo {
        val values = nativeGetFramebufferInfo(handle)
        return FramebufferInfo(
            width = values.getOrElse(0) { 0 },
            height = values.getOrElse(1) { 0 },
            stride = values.getOrElse(2) { 0 },
            state = values.getOrElse(3) { -1 }
        )
    }

    fun copyFrameRgba(): ByteArray? = nativeCopyFrameRgba(handle)

    fun copyRectRgba(x: Int, y: Int, width: Int, height: Int): ByteArray? =
        nativeCopyRectRgba(handle, x, y, width, height)

    fun blitFrameToBitmap(bitmap: Bitmap): Boolean =
        nativeBlitFrameToBitmap(handle, bitmap) == 0

    fun blitRectToBitmap(x: Int, y: Int, width: Int, height: Int, bitmap: Bitmap): Boolean =
        nativeBlitRectToBitmap(handle, x, y, width, height, bitmap) == 0

    fun consumeDamage(): DamageRect? {
        val values = nativeConsumeDamage(handle) ?: return null
        if (values.size < 4) {
            return null
        }
        val width = values[2]
        val height = values[3]
        if (width <= 0 || height <= 0) {
            return null
        }
        return DamageRect(
            x = values[0],
            y = values[1],
            width = width,
            height = height
        )
    }

    fun sendPointer(x: Int, y: Int, mask: Int) {
        nativeSendPointer(handle, x, y, mask)
    }

    fun sendKey(keysym: Int, down: Boolean) {
        nativeSendKey(handle, keysym, down)
    }

    fun setClipboardText(text: String) {
        nativeSetClipboardText(handle, text)
    }

    fun requestClipboard() {
        nativeRequestClipboard(handle)
    }

    fun takeRemoteClipboardText(): String = nativeTakeRemoteClipboardText(handle)

    fun hasRemoteClipboardText(): Boolean = nativeHasRemoteClipboardText(handle)

    fun getLastError(): String = nativeGetLastError(handle)

    fun isSecure(): Boolean = nativeIsSecure(handle)

    fun getSecurityLevel(): Int = nativeGetSecurityLevel(handle)

    fun hasReceivedFirstUpdate(): Boolean = nativeHasReceivedFirstUpdate(handle)

    fun getServerName(): String = nativeGetServerName(handle)

    fun detectMonitors(fallback: Array<android.graphics.Rect>? = null): Array<android.graphics.Rect> = nativeDetectMonitors(handle, fallback)

    override fun close() {
        if (handle != 0L) {
            nativeDestroy(handle)
            handle = 0L
        }
    }

    companion object {
        init {
            System.loadLibrary("vncbridge")
        }

        @JvmStatic
        fun configureStorageRoot(rootPath: String) {
            nativeSetStorageRoot(rootPath)
        }

        @JvmStatic
        external fun nativeCreate(): Long

        @JvmStatic
        external fun nativeSetStorageRoot(rootPath: String)

        @JvmStatic
        external fun nativeDestroy(handle: Long)

        @JvmStatic
        external fun nativeConnect(handle: Long, host: String, port: Int, user: String, password: String): Int

        @JvmStatic
        external fun nativeSetSshTunnel(
            handle: Long,
            enabled: Boolean,
            sshHost: String,
            sshPort: Int,
            sshUser: String,
            authType: Int,
            sshPassword: String,
            privateKeyPath: String,
            publicKeyPath: String,
            privateKeyPassphrase: String,
            knownHostsPath: String,
            strictHostKeyCheck: Boolean,
            remoteHost: String,
            remotePort: Int
        ): Int

        @JvmStatic
        external fun nativeClearSshTunnel(handle: Long)

        @JvmStatic
        external fun nativeDisconnect(handle: Long)

        @JvmStatic
        external fun nativeProcess(handle: Long): Int

        @JvmStatic
        external fun nativeRefresh(handle: Long): Int

        @JvmStatic
        external fun nativeRequestUpdate(handle: Long, incremental: Boolean): Int

        @JvmStatic
        external fun nativeGetFramebufferInfo(handle: Long): IntArray

        @JvmStatic
        external fun nativeCopyFrameRgba(handle: Long): ByteArray?

        @JvmStatic
        external fun nativeCopyRectRgba(handle: Long, x: Int, y: Int, width: Int, height: Int): ByteArray?

        @JvmStatic
        external fun nativeBlitFrameToBitmap(handle: Long, bitmap: Bitmap): Int

        @JvmStatic
        external fun nativeBlitRectToBitmap(
            handle: Long,
            x: Int,
            y: Int,
            width: Int,
            height: Int,
            bitmap: Bitmap
        ): Int

        @JvmStatic
        external fun nativeConsumeDamage(handle: Long): IntArray?

        @JvmStatic
        external fun nativeSendPointer(handle: Long, x: Int, y: Int, mask: Int)

        @JvmStatic
        external fun nativeSendKey(handle: Long, keysym: Int, down: Boolean)

        @JvmStatic
        external fun nativeSetClipboardText(handle: Long, text: String)

        @JvmStatic
        external fun nativeRequestClipboard(handle: Long)

        @JvmStatic
        external fun nativeTakeRemoteClipboardText(handle: Long): String

        @JvmStatic
        external fun nativeHasRemoteClipboardText(handle: Long): Boolean

        @JvmStatic
        external fun nativeGetLastError(handle: Long): String

        @JvmStatic
        external fun nativeIsSecure(handle: Long): Boolean

        @JvmStatic
        external fun nativeGetSecurityLevel(handle: Long): Int

        @JvmStatic
        external fun nativeHasReceivedFirstUpdate(handle: Long): Boolean

        @JvmStatic
        external fun nativeGetServerName(handle: Long): String

        @JvmStatic
        external fun nativeDetectMonitors(handle: Long, fallback: Array<android.graphics.Rect>?): Array<android.graphics.Rect>
    }
}
