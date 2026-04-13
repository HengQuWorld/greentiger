package com.hengqutiandi.vncviewer.model

import org.json.JSONObject
import java.util.UUID

data class SshConnectionConfig(
    val enabled: Boolean = false,
    val sshHost: String = "",
    val sshPort: Int = 22,
    val sshUser: String = "",
    val reuseDesktopUser: Boolean = false,
    val authType: Int = 1,
    val sshPassword: String = "",
    val reuseDesktopPassword: Boolean = false,
    val privateKeyPath: String = "",
    val publicKeyPath: String = "",
    val privateKeyPassphrase: String = "",
    val knownHostsPath: String = "",
    val strictHostKeyCheck: Boolean = false,
    val remoteHost: String = "",
    val remotePort: Int = 0
)

data class ConnectionItem(
    val id: String,
    val name: String,
    val address: String,
    val user: String,
    val password: String,
    val storePassword: Boolean,
    val touchScrollStep: Int,
    val lastUsedAt: Long,
    val ssh: SshConnectionConfig = SshConnectionConfig()
)

data class HostPort(
    val host: String,
    val port: Int
)

const val DEFAULT_VNC_PORT = 5900
const val DEFAULT_SSH_PORT = 22
const val SSH_AUTH_NONE = 0
const val SSH_AUTH_PASSWORD = 1
const val SSH_AUTH_PUBLIC_KEY = 2

fun generateConnectionId(): String = UUID.randomUUID().toString()

fun normalizeConnName(name: String, address: String): String {
    val cleanName = name.trim()
    return if (cleanName.isNotEmpty()) cleanName else address.trim().ifEmpty { "未命名连接" }
}

fun parseAddress(input: String): HostPort? {
    val raw = input.trim()
    if (raw.isEmpty()) {
        return null
    }

    val defaultPort = DEFAULT_VNC_PORT

    if (raw.startsWith("[")) {
        val end = raw.indexOf(']')
        if (end <= 1) {
            return null
        }
        val host = raw.substring(1, end).trim()
        val rest = raw.substring(end + 1).trim()
        if (rest.startsWith(":")) {
            val port = rest.substring(1).trim().toIntOrNull() ?: return null
            return if (host.isNotEmpty() && port in 1..65535) HostPort(host, port) else null
        }
        return if (host.isNotEmpty()) HostPort(host, defaultPort) else null
    }

    val lastColon = raw.lastIndexOf(':')
    if (lastColon > 0) {
        val hostPart = raw.substring(0, lastColon).trim()
        val portPart = raw.substring(lastColon + 1).trim()
        if (portPart.all(Char::isDigit)) {
            val port = portPart.toIntOrNull() ?: return null
            if (hostPart.isEmpty() || port !in 1..65535) {
                return null
            }
            return HostPort(hostPart, port)
        }
    }

    return HostPort(raw, defaultPort)
}

fun normalizeSshAuthType(authType: Int): Int = when (authType) {
    SSH_AUTH_NONE, SSH_AUTH_PUBLIC_KEY -> authType
    else -> SSH_AUTH_PASSWORD
}

fun normalizePort(port: Int, fallback: Int): Int = if (port in 1..65535) port else fallback

fun normalizeSshConfig(
    config: SshConnectionConfig?,
    remoteHost: String = "",
    remotePort: Int = DEFAULT_VNC_PORT
): SshConnectionConfig {
    val configRemoteHost = config?.remoteHost.orEmpty().trim()
    val nextRemoteHost = remoteHost.trim()
    val nextRemotePort = normalizePort(remotePort, DEFAULT_VNC_PORT)
    return SshConnectionConfig(
        enabled = config?.enabled == true,
        sshHost = config?.sshHost.orEmpty().trim(),
        sshPort = normalizePort(config?.sshPort ?: DEFAULT_SSH_PORT, DEFAULT_SSH_PORT),
        sshUser = config?.sshUser.orEmpty().trim(),
        reuseDesktopUser = config?.reuseDesktopUser == true,
        authType = normalizeSshAuthType(config?.authType ?: SSH_AUTH_PASSWORD),
        sshPassword = config?.sshPassword.orEmpty(),
        reuseDesktopPassword = config?.reuseDesktopPassword == true,
        privateKeyPath = config?.privateKeyPath.orEmpty().trim(),
        publicKeyPath = config?.publicKeyPath.orEmpty().trim(),
        privateKeyPassphrase = config?.privateKeyPassphrase.orEmpty(),
        knownHostsPath = config?.knownHostsPath.orEmpty().trim(),
        strictHostKeyCheck = config?.strictHostKeyCheck == true,
        remoteHost = configRemoteHost.ifEmpty { nextRemoteHost },
        remotePort = normalizePort(config?.remotePort ?: nextRemotePort, nextRemotePort)
    )
}

fun normalizeSshConfigForAddress(config: SshConnectionConfig?, address: String): SshConnectionConfig {
    val parsed = parseAddress(address)
    return normalizeSshConfig(config, parsed?.host.orEmpty(), parsed?.port ?: DEFAULT_VNC_PORT)
}

fun resolveSshConfigForConnection(
    config: SshConnectionConfig?,
    address: String,
    desktopUser: String = "",
    desktopPassword: String = ""
): SshConnectionConfig {
    val normalized = normalizeSshConfigForAddress(config, address)
    if (!normalized.enabled) {
        return normalized
    }
    val effectiveUser = if (normalized.reuseDesktopUser && desktopUser.trim().isNotEmpty()) {
        desktopUser.trim()
    } else {
        normalized.sshUser.trim()
    }
    val effectivePassword = if (
        normalized.authType == SSH_AUTH_PASSWORD &&
        normalized.reuseDesktopPassword &&
        desktopPassword.isNotEmpty()
    ) {
        desktopPassword
    } else {
        normalized.sshPassword
    }
    return normalized.copy(
        sshUser = effectiveUser,
        sshPassword = effectivePassword
    )
}

fun validateSshConfig(config: SshConnectionConfig): String? {
    if (!config.enabled) return null
    if (config.sshHost.isBlank()) return "SSH 服务器不能为空"
    if (config.sshUser.isBlank()) return "SSH 用户名不能为空"
    if (config.sshPort !in 1..65535) return "SSH 端口必须在 1 到 65535 之间"
    if (config.remoteHost.isBlank()) return "SSH 转发目标不能为空"
    if (config.remotePort !in 1..65535) return "SSH 转发目标端口必须在 1 到 65535 之间"
    if (config.authType == SSH_AUTH_PUBLIC_KEY && config.privateKeyPath.isBlank()) {
        return "SSH 私钥路径不能为空"
    }
    if (config.authType == SSH_AUTH_PASSWORD && config.sshPassword.isBlank()) {
        return "SSH 密码不能为空"
    }
    if (config.strictHostKeyCheck && config.knownHostsPath.isBlank()) {
        return "开启严格主机校验时必须提供 known_hosts 路径"
    }
    return null
}

fun ConnectionItem.toJson(includePassword: Boolean = true): JSONObject = JSONObject()
    .put("id", id)
    .put("name", name)
    .put("address", address)
    .put("user", user)
    .put("password", if (includePassword) password else "")
    .put("storePassword", storePassword)
    .put("touchScrollStep", touchScrollStep)
    .put("lastUsedAt", lastUsedAt)
    .put("ssh", JSONObject()
        .put("enabled", ssh.enabled)
        .put("sshHost", ssh.sshHost)
        .put("sshPort", ssh.sshPort)
        .put("sshUser", ssh.sshUser)
        .put("reuseDesktopUser", ssh.reuseDesktopUser)
        .put("authType", ssh.authType)
        .put("sshPassword", ssh.sshPassword)
        .put("reuseDesktopPassword", ssh.reuseDesktopPassword)
        .put("privateKeyPath", ssh.privateKeyPath)
        .put("publicKeyPath", ssh.publicKeyPath)
        .put("privateKeyPassphrase", ssh.privateKeyPassphrase)
        .put("knownHostsPath", ssh.knownHostsPath)
        .put("strictHostKeyCheck", ssh.strictHostKeyCheck)
        .put("remoteHost", ssh.remoteHost)
        .put("remotePort", ssh.remotePort))

fun connectionFromJson(json: JSONObject): ConnectionItem? {
    val address = json.optString("address").trim()
    if (address.isEmpty()) {
        return null
    }

    val sshJson = json.optJSONObject("ssh")

    return ConnectionItem(
        id = json.optString("id").ifBlank { generateConnectionId() },
        name = json.optString("name"),
        address = address,
        user = json.optString("user"),
        password = json.optString("password"),
        storePassword = json.optBoolean("storePassword", json.optString("password").isNotEmpty()),
        touchScrollStep = json.optInt("touchScrollStep").coerceIn(0, 48),
        lastUsedAt = json.optLong("lastUsedAt", 0L),
        ssh = normalizeSshConfigForAddress(
            config = SshConnectionConfig(
                enabled = sshJson?.optBoolean("enabled", false) == true,
                sshHost = sshJson?.optString("sshHost").orEmpty(),
                sshPort = sshJson?.optInt("sshPort", DEFAULT_SSH_PORT) ?: DEFAULT_SSH_PORT,
                sshUser = sshJson?.optString("sshUser").orEmpty(),
                reuseDesktopUser = sshJson?.optBoolean("reuseDesktopUser", false) == true,
                authType = sshJson?.optInt("authType", SSH_AUTH_PASSWORD) ?: SSH_AUTH_PASSWORD,
                sshPassword = sshJson?.optString("sshPassword").orEmpty(),
                reuseDesktopPassword = sshJson?.optBoolean("reuseDesktopPassword", false) == true,
                privateKeyPath = sshJson?.optString("privateKeyPath").orEmpty(),
                publicKeyPath = sshJson?.optString("publicKeyPath").orEmpty(),
                privateKeyPassphrase = sshJson?.optString("privateKeyPassphrase").orEmpty(),
                knownHostsPath = sshJson?.optString("knownHostsPath").orEmpty(),
                strictHostKeyCheck = sshJson?.optBoolean("strictHostKeyCheck", false) == true,
                remoteHost = sshJson?.optString("remoteHost").orEmpty(),
                remotePort = sshJson?.optInt("remotePort", 0) ?: 0
            ),
            address = address
        )
    )
}
