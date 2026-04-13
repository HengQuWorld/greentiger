package com.hengqutiandi.vncviewer

import com.hengqutiandi.vncviewer.model.SshConnectionConfig
import com.hengqutiandi.vncviewer.native.SshTunnelConfig

internal fun SshConnectionConfig.toNativeConfig(): SshTunnelConfig = SshTunnelConfig(
    enabled = enabled,
    sshHost = sshHost,
    sshPort = sshPort,
    sshUser = sshUser,
    authType = authType,
    sshPassword = sshPassword,
    privateKeyPath = privateKeyPath,
    publicKeyPath = publicKeyPath,
    privateKeyPassphrase = privateKeyPassphrase,
    knownHostsPath = knownHostsPath,
    strictHostKeyCheck = strictHostKeyCheck,
    remoteHost = remoteHost,
    remotePort = remotePort
)
