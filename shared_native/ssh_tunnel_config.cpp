#include "ssh_tunnel.h"

namespace shared {

// Kept separate from ssh_tunnel.cpp so the validation rules can be tested
// without pulling in libssh2 or any socket headers.

bool SshTunnelConfig::IsEnabled() const
{
  return enabled;
}

bool SshTunnelConfig::Validate(std::string* error) const
{
  if (!enabled)
    return true;
  if (sshHost.empty()) {
    if (error)
      *error = "SSH host is required";
    return false;
  }
  if (sshPort < 1 || sshPort > 65535) {
    if (error)
      *error = "SSH port is invalid";
    return false;
  }
  if (sshUser.empty()) {
    if (error)
      *error = "SSH user is required";
    return false;
  }
  if (remoteHost.empty()) {
    if (error)
      *error = "SSH remote host is required";
    return false;
  }
  if (remotePort < 1 || remotePort > 65535) {
    if (error)
      *error = "SSH remote port is invalid";
    return false;
  }
  if (authType == SshTunnelAuthType::kPassword && sshPassword.empty()) {
    if (error)
      *error = "SSH password is required";
    return false;
  }
  if (authType != SshTunnelAuthType::kPassword &&
      authType != SshTunnelAuthType::kPublicKey &&
      authType != SshTunnelAuthType::kNone) {
    if (error)
      *error = "SSH auth type is invalid";
    return false;
  }
  if (authType == SshTunnelAuthType::kPublicKey && privateKeyPath.empty()) {
    if (error)
      *error = "SSH private key path is required";
    return false;
  }
  return true;
}

SshTunnelConfig NormalizeSshTunnelConfig(const SshTunnelConfig& config,
                                         const std::string& defaultRemoteHost,
                                         int defaultRemotePort)
{
  SshTunnelConfig out = config;
  if (!out.enabled)
    return out;
  if (out.remoteHost.empty())
    out.remoteHost = defaultRemoteHost;
  if (out.remotePort <= 0)
    out.remotePort = defaultRemotePort;
  if (out.sshPort <= 0)
    out.sshPort = 22;
  return out;
}

}  // namespace shared
