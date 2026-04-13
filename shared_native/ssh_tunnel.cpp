#include "ssh_tunnel.h"

#include <cerrno>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <libssh2.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

namespace shared {

namespace {

constexpr size_t kBufferLimit = 256 * 1024;
constexpr int kSelectTimeoutMs = 200;

int CloseFd(int fd)
{
  if (fd >= 0)
    return close(fd);
  return 0;
}

std::string SafeString(const char* value)
{
  return value ? std::string(value) : std::string();
}

bool IsSocketWouldBlock()
{
  return errno == EAGAIN || errno == EWOULDBLOCK;
}

bool SetNonBlocking(int fd, bool enabled, std::string* error)
{
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) {
    if (error)
      *error = "fcntl(F_GETFL) failed: " + std::string(std::strerror(errno));
    return false;
  }

  int nextFlags = enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK);
  if (fcntl(fd, F_SETFL, nextFlags) != 0) {
    if (error)
      *error = "fcntl(F_SETFL) failed: " + std::string(std::strerror(errno));
    return false;
  }
  return true;
}

int ConnectTcp(const std::string& host, int port, std::string* error)
{
  struct addrinfo hints {};
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;

  struct addrinfo* result = nullptr;
  const std::string portText = std::to_string(port);
  int rc = getaddrinfo(host.c_str(), portText.c_str(), &hints, &result);
  if (rc != 0) {
    if (error)
      *error = "resolve SSH host failed: " + std::string(gai_strerror(rc));
    return -1;
  }

  int fd = -1;
  for (struct addrinfo* it = result; it; it = it->ai_next) {
    fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
    if (fd < 0)
      continue;
    if (connect(fd, it->ai_addr, it->ai_addrlen) == 0)
      break;
    CloseFd(fd);
    fd = -1;
  }

  freeaddrinfo(result);

  if (fd < 0 && error)
    *error = "connect SSH host failed: " + std::string(std::strerror(errno));
  return fd;
}

int HostKeyToKnownHostType(int hostKeyType)
{
  switch (hostKeyType) {
    case LIBSSH2_HOSTKEY_TYPE_RSA:
      return LIBSSH2_KNOWNHOST_KEY_SSHRSA;
    case LIBSSH2_HOSTKEY_TYPE_DSS:
      return LIBSSH2_KNOWNHOST_KEY_SSHDSS;
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_256:
      return LIBSSH2_KNOWNHOST_KEY_ECDSA_256;
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_384:
      return LIBSSH2_KNOWNHOST_KEY_ECDSA_384;
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_521:
      return LIBSSH2_KNOWNHOST_KEY_ECDSA_521;
    case LIBSSH2_HOSTKEY_TYPE_ED25519:
      return LIBSSH2_KNOWNHOST_KEY_ED25519;
    default:
      return LIBSSH2_KNOWNHOST_KEY_UNKNOWN;
  }
}

bool VerifyHostKey(LIBSSH2_SESSION* session, const SshTunnelConfig& config, std::string* error)
{
  if (!config.strictHostKeyCheck)
    return true;
  if (config.knownHostsPath.empty()) {
    if (error)
      *error = "strict host key check requires known_hosts_path";
    return false;
  }

  size_t keyLen = 0;
  int keyType = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
  const char* hostKey = libssh2_session_hostkey(session, &keyLen, &keyType);
  if (!hostKey || keyLen == 0) {
    if (error)
      *error = "unable to read SSH host key";
    return false;
  }

  LIBSSH2_KNOWNHOSTS* knownHosts = libssh2_knownhost_init(session);
  if (!knownHosts) {
    if (error)
      *error = "libssh2_knownhost_init failed";
    return false;
  }

  int rc = libssh2_knownhost_readfile(knownHosts, config.knownHostsPath.c_str(),
                                      LIBSSH2_KNOWNHOST_FILE_OPENSSH);
  if (rc < 0) {
    libssh2_knownhost_free(knownHosts);
    if (error)
      *error = "failed to read known_hosts file: " + config.knownHostsPath;
    return false;
  }

  int keyMask = LIBSSH2_KNOWNHOST_TYPE_PLAIN |
                LIBSSH2_KNOWNHOST_KEYENC_RAW |
                HostKeyToKnownHostType(keyType);
  struct libssh2_knownhost* match = nullptr;
  rc = libssh2_knownhost_checkp(knownHosts, config.sshHost.c_str(), config.sshPort,
                                hostKey, keyLen, keyMask, &match);
  libssh2_knownhost_free(knownHosts);

  if (rc != LIBSSH2_KNOWNHOST_CHECK_MATCH) {
    if (error)
      *error = "SSH host key verification failed";
    return false;
  }
  return true;
}

bool Authenticate(LIBSSH2_SESSION* session, const SshTunnelConfig& config, std::string* error)
{
  if (config.authType == SshTunnelAuthType::kNone) {
    if (libssh2_userauth_authenticated(session))
      return true;
    if (error)
      *error = "SSH auth_type is none but server requires authentication";
    return false;
  }

  if (config.authType == SshTunnelAuthType::kPublicKey) {
    if (config.privateKeyPath.empty()) {
      if (error)
        *error = "SSH private key path is required";
      return false;
    }
    int rc = libssh2_userauth_publickey_fromfile_ex(
      session,
      config.sshUser.c_str(),
      static_cast<unsigned int>(config.sshUser.size()),
      config.publicKeyPath.empty() ? nullptr : config.publicKeyPath.c_str(),
      config.privateKeyPath.c_str(),
      config.privateKeyPassphrase.empty() ? nullptr : config.privateKeyPassphrase.c_str());
    if (rc == 0)
      return true;
    if (error)
      *error = "SSH public key auth failed";
    return false;
  }

  int rc = libssh2_userauth_password_ex(
    session,
    config.sshUser.c_str(),
    static_cast<unsigned int>(config.sshUser.size()),
    config.sshPassword.c_str(),
    static_cast<unsigned int>(config.sshPassword.size()),
    nullptr);
  if (rc == 0)
    return true;
  if (error)
    *error = "SSH password auth failed";
  return false;
}

}  // namespace

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

bool EnsureSshLibraryReady(std::string* error)
{
  static std::once_flag once;
  static int initRc = 0;

  std::call_once(once, []() {
    initRc = libssh2_init(0);
  });

  if (initRc != 0) {
    if (error)
      *error = "libssh2_init failed";
    return false;
  }
  return true;
}

std::unique_ptr<SshTunnel> SshTunnel::Open(const SshTunnelConfig& config, std::string* error)
{
  std::string validateError;
  if (!config.Validate(&validateError)) {
    if (error)
      *error = validateError;
    return nullptr;
  }
  if (!EnsureSshLibraryReady(error))
    return nullptr;

  std::unique_ptr<SshTunnel> tunnel(new SshTunnel(config));
  if (!tunnel->ConnectSession(error))
    return nullptr;
  if (!tunnel->CreateListener(error))
    return nullptr;

  tunnel->workerThread_ = std::thread([ptr = tunnel.get()]() {
    ptr->WorkerMain();
  });
  tunnel->SetReady();
  return tunnel;
}

SshTunnel::SshTunnel(SshTunnelConfig config)
  : config_(std::move(config))
{
}

SshTunnel::~SshTunnel()
{
  Shutdown();
}

bool SshTunnel::WaitUntilReady(int timeoutMs, std::string* error)
{
  std::unique_lock<std::mutex> lock(mutex_);
  if (!ready_ && !failed_) {
    stateCv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this]() {
      return ready_ || failed_;
    });
  }
  if (ready_)
    return true;
  if (error)
    *error = lastError_.empty() ? "SSH tunnel startup timed out" : lastError_;
  return false;
}

void SshTunnel::Shutdown()
{
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopRequested_ && !workerThread_.joinable() && sshSocket_ < 0 &&
        listenSocket_ < 0 && clientSocket_ < 0 && !session_) {
      return;
    }
    stopRequested_ = true;
  }

  if (clientSocket_ >= 0)
    shutdown(clientSocket_, SHUT_RDWR);
  if (listenSocket_ >= 0)
    shutdown(listenSocket_, SHUT_RDWR);
  if (sshSocket_ >= 0)
    shutdown(sshSocket_, SHUT_RDWR);

  if (workerThread_.joinable())
    workerThread_.join();

  CloseClientSocket();
  CloseListenerSocket();
  CloseChannel();
  CloseSession();
}

bool SshTunnel::ConnectSession(std::string* error)
{
  sshSocket_ = ConnectTcp(config_.sshHost, config_.sshPort, error);
  if (sshSocket_ < 0)
    return false;

  LIBSSH2_SESSION* session = libssh2_session_init_ex(nullptr, nullptr, nullptr, nullptr);
  if (!session) {
    if (error)
      *error = "libssh2_session_init_ex failed";
    CloseSession();
    return false;
  }
  session_ = session;

  libssh2_session_set_blocking(session, 1);

  if (libssh2_session_handshake(session, sshSocket_) != 0) {
    if (error)
      *error = "SSH handshake failed";
    CloseSession();
    return false;
  }
  if (!VerifyHostKey(session, config_, error)) {
    CloseSession();
    return false;
  }
  if (!Authenticate(session, config_, error)) {
    CloseSession();
    return false;
  }

  libssh2_session_set_blocking(session, 0);
  return true;
}

bool SshTunnel::CreateListener(std::string* error)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    if (error)
      *error = "create local listener failed: " + std::string(std::strerror(errno));
    return false;
  }

  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  sockaddr_in addr {};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(0);

  if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    if (error)
      *error = "bind local tunnel port failed: " + std::string(std::strerror(errno));
    CloseFd(fd);
    return false;
  }
  if (listen(fd, 1) != 0) {
    if (error)
      *error = "listen local tunnel port failed: " + std::string(std::strerror(errno));
    CloseFd(fd);
    return false;
  }

  sockaddr_in bound {};
  socklen_t len = sizeof(bound);
  if (getsockname(fd, reinterpret_cast<sockaddr*>(&bound), &len) != 0) {
    if (error)
      *error = "read local tunnel port failed: " + std::string(std::strerror(errno));
    CloseFd(fd);
    return false;
  }

  listenSocket_ = fd;
  localPort_ = ntohs(bound.sin_port);
  return true;
}

void SshTunnel::WorkerMain()
{
  std::string error;
  while (true) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopRequested_)
        break;
    }

    sockaddr_storage addr {};
    socklen_t addrLen = sizeof(addr);
    int fd = accept(listenSocket_, reinterpret_cast<sockaddr*>(&addr), &addrLen);
    if (fd < 0) {
      if (errno == EINTR)
        continue;
      if (IsSocketWouldBlock())
        continue;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopRequested_)
          break;
      }
      SetFailed("accept local tunnel client failed: " + std::string(std::strerror(errno)));
      break;
    }

    clientSocket_ = fd;
    CloseListenerSocket();
    if (!SetNonBlocking(clientSocket_, true, &error)) {
      SetFailed(error);
      break;
    }
    if (!OpenForwardChannel(&error)) {
      SetFailed(error);
      break;
    }
    if (!Pump(&error))
      SetFailed(error);
    break;
  }

  CloseClientSocket();
  CloseListenerSocket();
  CloseChannel();
}

bool SshTunnel::OpenForwardChannel(std::string* error)
{
  LIBSSH2_SESSION* session = static_cast<LIBSSH2_SESSION*>(session_);
  if (!session) {
    if (error)
      *error = "SSH session is not ready";
    return false;
  }

  while (true) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopRequested_) {
        if (error)
          *error = "SSH tunnel stopped";
        return false;
      }
    }

    LIBSSH2_CHANNEL* channel = libssh2_channel_direct_tcpip_ex(
      session,
      config_.remoteHost.c_str(),
      config_.remotePort,
      "127.0.0.1",
      localPort_);
    if (channel) {
      channel_ = channel;
      return true;
    }

    int sshErr = libssh2_session_last_errno(session);
    if (sshErr != LIBSSH2_ERROR_EAGAIN) {
      if (error)
        *error = "open SSH direct-tcpip channel failed";
      return false;
    }

    fd_set readSet;
    fd_set writeSet;
    FD_ZERO(&readSet);
    FD_ZERO(&writeSet);
    FD_SET(sshSocket_, &readSet);
    FD_SET(sshSocket_, &writeSet);
    timeval tv {};
    tv.tv_sec = 0;
    tv.tv_usec = kSelectTimeoutMs * 1000;
    select(sshSocket_ + 1, &readSet, &writeSet, nullptr, &tv);
  }
}

bool SshTunnel::Pump(std::string* error)
{
  LIBSSH2_CHANNEL* channel = static_cast<LIBSSH2_CHANNEL*>(channel_);
  if (!channel || clientSocket_ < 0) {
    if (error)
      *error = "SSH tunnel data path is not ready";
    return false;
  }

  std::vector<char> clientToRemote;
  std::vector<char> remoteToClient;
  bool clientEof = false;
  bool remoteEof = false;
  bool sentRemoteEof = false;

  while (true) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopRequested_)
        return true;
    }

    bool progressed = false;

    if (!clientEof && clientToRemote.size() < kBufferLimit) {
      char buf[8192];
      ssize_t n = recv(clientSocket_, buf, sizeof(buf), 0);
      if (n > 0) {
        clientToRemote.insert(clientToRemote.end(), buf, buf + n);
        progressed = true;
      } else if (n == 0) {
        clientEof = true;
      } else if (!IsSocketWouldBlock() && errno != EINTR) {
        if (error)
          *error = "read local tunnel client failed: " + std::string(std::strerror(errno));
        return false;
      }
    }

    while (!clientToRemote.empty()) {
      ssize_t n = libssh2_channel_write_ex(
        channel, 0, clientToRemote.data(), clientToRemote.size());
      if (n > 0) {
        clientToRemote.erase(clientToRemote.begin(), clientToRemote.begin() + n);
        progressed = true;
        continue;
      }
      if (n == LIBSSH2_ERROR_EAGAIN)
        break;
      if (error)
        *error = "write SSH channel failed";
      return false;
    }

    while (!remoteEof && remoteToClient.size() < kBufferLimit) {
      char buf[8192];
      ssize_t n = libssh2_channel_read_ex(channel, 0, buf, sizeof(buf));
      if (n > 0) {
        remoteToClient.insert(remoteToClient.end(), buf, buf + n);
        progressed = true;
        continue;
      }
      if (n == 0) {
        remoteEof = true;
        break;
      }
      if (n == LIBSSH2_ERROR_EAGAIN)
        break;
      if (error)
        *error = "read SSH channel failed";
      return false;
    }

    while (!remoteToClient.empty()) {
      ssize_t n = send(clientSocket_, remoteToClient.data(), remoteToClient.size(), 0);
      if (n > 0) {
        remoteToClient.erase(remoteToClient.begin(), remoteToClient.begin() + n);
        progressed = true;
        continue;
      }
      if (n < 0 && (IsSocketWouldBlock() || errno == EINTR))
        break;
      if (error)
        *error = "write local tunnel client failed: " + std::string(std::strerror(errno));
      return false;
    }

    if (clientEof && !sentRemoteEof && clientToRemote.empty()) {
      libssh2_channel_send_eof(channel);
      sentRemoteEof = true;
      progressed = true;
    }

    if ((remoteEof || libssh2_channel_eof(channel)) &&
        remoteToClient.empty() &&
        clientEof &&
        clientToRemote.empty()) {
      return true;
    }

    if (progressed)
      continue;

    fd_set readSet;
    fd_set writeSet;
    FD_ZERO(&readSet);
    FD_ZERO(&writeSet);

    int maxFd = -1;
    if (!clientEof && clientToRemote.size() < kBufferLimit) {
      FD_SET(clientSocket_, &readSet);
      if (clientSocket_ > maxFd)
        maxFd = clientSocket_;
    }
    if (!remoteToClient.empty()) {
      FD_SET(clientSocket_, &writeSet);
      if (clientSocket_ > maxFd)
        maxFd = clientSocket_;
    }

    FD_SET(sshSocket_, &readSet);
    if (sshSocket_ > maxFd)
      maxFd = sshSocket_;
    if (!clientToRemote.empty()) {
      FD_SET(sshSocket_, &writeSet);
      if (sshSocket_ > maxFd)
        maxFd = sshSocket_;
    }

    timeval tv {};
    tv.tv_sec = 0;
    tv.tv_usec = kSelectTimeoutMs * 1000;
    int rc = select(maxFd + 1, &readSet, &writeSet, nullptr, &tv);
    if (rc < 0 && errno != EINTR) {
      if (error)
        *error = "select tunnel socket failed: " + std::string(std::strerror(errno));
      return false;
    }
  }
}

void SshTunnel::SetReady()
{
  std::lock_guard<std::mutex> lock(mutex_);
  ready_ = true;
  stateCv_.notify_all();
}

void SshTunnel::SetFailed(const std::string& error)
{
  std::lock_guard<std::mutex> lock(mutex_);
  failed_ = true;
  lastError_ = error;
  stateCv_.notify_all();
}

void SshTunnel::CloseClientSocket()
{
  if (clientSocket_ >= 0) {
    CloseFd(clientSocket_);
    clientSocket_ = -1;
  }
}

void SshTunnel::CloseListenerSocket()
{
  if (listenSocket_ >= 0) {
    CloseFd(listenSocket_);
    listenSocket_ = -1;
  }
}

void SshTunnel::CloseChannel()
{
  LIBSSH2_CHANNEL* channel = static_cast<LIBSSH2_CHANNEL*>(channel_);
  if (channel) {
    libssh2_channel_close(channel);
    libssh2_channel_free(channel);
    channel_ = nullptr;
  }
}

void SshTunnel::CloseSession()
{
  LIBSSH2_SESSION* session = static_cast<LIBSSH2_SESSION*>(session_);
  if (session) {
    libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION,
                                  "closed", "");
    libssh2_session_free(session);
    session_ = nullptr;
  }
  if (sshSocket_ >= 0) {
    CloseFd(sshSocket_);
    sshSocket_ = -1;
  }
}

}  // namespace shared
