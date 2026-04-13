package com.hengqutiandi.vncviewer

import android.content.Context
import android.content.Intent
import com.hengqutiandi.vncviewer.model.HostPort
import com.hengqutiandi.vncviewer.model.SSH_AUTH_PASSWORD
import com.hengqutiandi.vncviewer.model.SshConnectionConfig
import com.hengqutiandi.vncviewer.model.normalizeSshConfigForAddress
import com.hengqutiandi.vncviewer.model.parseAddress

internal data class ViewerLaunchArgs(
    val connName: String,
    val address: String,
    val user: String,
    val password: String,
    val touchScrollStep: Int,
    val ssh: SshConnectionConfig = SshConnectionConfig()
) {
    val hostPort: HostPort? get() = parseAddress(address)
}

private const val EXTRA_VIEWER_MODE = "viewer_mode"
private const val EXTRA_VIEWER_CONN_NAME = "viewer_conn_name"
private const val EXTRA_VIEWER_ADDRESS = "viewer_address"
private const val EXTRA_VIEWER_USER = "viewer_user"
private const val EXTRA_VIEWER_PASSWORD = "viewer_password"
private const val EXTRA_VIEWER_TOUCH_SCROLL_STEP = "viewer_touch_scroll_step"
private const val EXTRA_VIEWER_SSH_ENABLED = "viewer_ssh_enabled"
private const val EXTRA_VIEWER_SSH_HOST = "viewer_ssh_host"
private const val EXTRA_VIEWER_SSH_PORT = "viewer_ssh_port"
private const val EXTRA_VIEWER_SSH_USER = "viewer_ssh_user"
private const val EXTRA_VIEWER_SSH_REUSE_DESKTOP_USER = "viewer_ssh_reuse_desktop_user"
private const val EXTRA_VIEWER_SSH_AUTH_TYPE = "viewer_ssh_auth_type"
private const val EXTRA_VIEWER_SSH_PASSWORD = "viewer_ssh_password"
private const val EXTRA_VIEWER_SSH_REUSE_DESKTOP_PASSWORD = "viewer_ssh_reuse_desktop_password"
private const val EXTRA_VIEWER_SSH_PRIVATE_KEY_PATH = "viewer_ssh_private_key_path"
private const val EXTRA_VIEWER_SSH_PUBLIC_KEY_PATH = "viewer_ssh_public_key_path"
private const val EXTRA_VIEWER_SSH_PRIVATE_KEY_PASSPHRASE = "viewer_ssh_private_key_passphrase"
private const val EXTRA_VIEWER_SSH_KNOWN_HOSTS_PATH = "viewer_ssh_known_hosts_path"
private const val EXTRA_VIEWER_SSH_STRICT_HOST_KEY_CHECK = "viewer_ssh_strict_host_key_check"
private const val EXTRA_VIEWER_SSH_REMOTE_HOST = "viewer_ssh_remote_host"
private const val EXTRA_VIEWER_SSH_REMOTE_PORT = "viewer_ssh_remote_port"

internal fun Intent.toViewerLaunchArgs(): ViewerLaunchArgs? {
    if (!getBooleanExtra(EXTRA_VIEWER_MODE, false)) {
        return null
    }
    val address = getStringExtra(EXTRA_VIEWER_ADDRESS).orEmpty()
    if (parseAddress(address) == null) {
        return null
    }
    return ViewerLaunchArgs(
        connName = getStringExtra(EXTRA_VIEWER_CONN_NAME).orEmpty(),
        address = address,
        user = getStringExtra(EXTRA_VIEWER_USER).orEmpty(),
        password = getStringExtra(EXTRA_VIEWER_PASSWORD).orEmpty(),
        touchScrollStep = normalizeTouchScrollStep(getIntExtra(EXTRA_VIEWER_TOUCH_SCROLL_STEP, 0)),
        ssh = normalizeSshConfigForAddress(
            SshConnectionConfig(
                enabled = getBooleanExtra(EXTRA_VIEWER_SSH_ENABLED, false),
                sshHost = getStringExtra(EXTRA_VIEWER_SSH_HOST).orEmpty(),
                sshPort = getIntExtra(EXTRA_VIEWER_SSH_PORT, 22),
                sshUser = getStringExtra(EXTRA_VIEWER_SSH_USER).orEmpty(),
                reuseDesktopUser = getBooleanExtra(EXTRA_VIEWER_SSH_REUSE_DESKTOP_USER, false),
                authType = getIntExtra(EXTRA_VIEWER_SSH_AUTH_TYPE, SSH_AUTH_PASSWORD),
                sshPassword = getStringExtra(EXTRA_VIEWER_SSH_PASSWORD).orEmpty(),
                reuseDesktopPassword = getBooleanExtra(EXTRA_VIEWER_SSH_REUSE_DESKTOP_PASSWORD, false),
                privateKeyPath = getStringExtra(EXTRA_VIEWER_SSH_PRIVATE_KEY_PATH).orEmpty(),
                publicKeyPath = getStringExtra(EXTRA_VIEWER_SSH_PUBLIC_KEY_PATH).orEmpty(),
                privateKeyPassphrase = getStringExtra(EXTRA_VIEWER_SSH_PRIVATE_KEY_PASSPHRASE).orEmpty(),
                knownHostsPath = getStringExtra(EXTRA_VIEWER_SSH_KNOWN_HOSTS_PATH).orEmpty(),
                strictHostKeyCheck = getBooleanExtra(EXTRA_VIEWER_SSH_STRICT_HOST_KEY_CHECK, false),
                remoteHost = getStringExtra(EXTRA_VIEWER_SSH_REMOTE_HOST).orEmpty(),
                remotePort = getIntExtra(EXTRA_VIEWER_SSH_REMOTE_PORT, 0)
            ),
            address = address
        )
    )
}

internal fun createViewerIntent(context: Context, args: ViewerLaunchArgs): Intent {
    return Intent(context, MainActivity::class.java)
        .putExtra(EXTRA_VIEWER_MODE, true)
        .putExtra(EXTRA_VIEWER_CONN_NAME, args.connName)
        .putExtra(EXTRA_VIEWER_ADDRESS, args.address)
        .putExtra(EXTRA_VIEWER_USER, args.user)
        .putExtra(EXTRA_VIEWER_PASSWORD, args.password)
        .putExtra(EXTRA_VIEWER_TOUCH_SCROLL_STEP, args.touchScrollStep)
        .putExtra(EXTRA_VIEWER_SSH_ENABLED, args.ssh.enabled)
        .putExtra(EXTRA_VIEWER_SSH_HOST, args.ssh.sshHost)
        .putExtra(EXTRA_VIEWER_SSH_PORT, args.ssh.sshPort)
        .putExtra(EXTRA_VIEWER_SSH_USER, args.ssh.sshUser)
        .putExtra(EXTRA_VIEWER_SSH_REUSE_DESKTOP_USER, args.ssh.reuseDesktopUser)
        .putExtra(EXTRA_VIEWER_SSH_AUTH_TYPE, args.ssh.authType)
        .putExtra(EXTRA_VIEWER_SSH_PASSWORD, args.ssh.sshPassword)
        .putExtra(EXTRA_VIEWER_SSH_REUSE_DESKTOP_PASSWORD, args.ssh.reuseDesktopPassword)
        .putExtra(EXTRA_VIEWER_SSH_PRIVATE_KEY_PATH, args.ssh.privateKeyPath)
        .putExtra(EXTRA_VIEWER_SSH_PUBLIC_KEY_PATH, args.ssh.publicKeyPath)
        .putExtra(EXTRA_VIEWER_SSH_PRIVATE_KEY_PASSPHRASE, args.ssh.privateKeyPassphrase)
        .putExtra(EXTRA_VIEWER_SSH_KNOWN_HOSTS_PATH, args.ssh.knownHostsPath)
        .putExtra(EXTRA_VIEWER_SSH_STRICT_HOST_KEY_CHECK, args.ssh.strictHostKeyCheck)
        .putExtra(EXTRA_VIEWER_SSH_REMOTE_HOST, args.ssh.remoteHost)
        .putExtra(EXTRA_VIEWER_SSH_REMOTE_PORT, args.ssh.remotePort)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
}
