#include "vncclient.h"
#include "ssh_tunnel.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <core/Configuration.h>
#include <core/Exception.h>
#include <core/LogWriter.h>
#include <core/Region.h>
#include <core/xdgdirs.h>

#include <network/TcpSocket.h>

#include <rdr/InStream.h>
#include <rdr/OutStream.h>
#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>

#include <rfb/CConnection.h>
#include <rfb/CMsgWriter.h>
#include <rfb/Exception.h>
#include <rfb/PixelBuffer.h>
#include <rfb/CSecurity.h>
#include <rfb/Security.h>
#include <rfb/SecurityClient.h>

static core::LogWriter vlog("shared-vncclient");

namespace {

constexpr unsigned long long kInitialBandwidthEstimateBps = 20000000ULL;
constexpr unsigned long long kBandwidthEstimateWindowMs = 1000ULL;
constexpr unsigned long long kBandwidthEstimateMaxWeight = 200000ULL;
constexpr unsigned long long kLanQualityThresholdBps = 16000000ULL;
constexpr int kLanQualityLevel = 8;
constexpr int kWanQualityLevel = 6;
constexpr int kLanCompressLevel = 2;
constexpr int kWanCompressLevel = 5;

std::once_flag gSecurityInitFlag;

std::string copyCString(const char* value)
{
  return value ? std::string(value) : std::string();
}

shared::SshTunnelAuthType toSshAuthType(int authType)
{
  switch (authType) {
    case VNCCLIENT_SSH_AUTH_NONE:
      return shared::SshTunnelAuthType::kNone;
    case VNCCLIENT_SSH_AUTH_PUBLIC_KEY:
      return shared::SshTunnelAuthType::kPublicKey;
    case VNCCLIENT_SSH_AUTH_PASSWORD:
    default:
      return shared::SshTunnelAuthType::kPassword;
  }
}

shared::SshTunnelConfig toSshTunnelConfig(const vncclient_ssh_config* config)
{
  shared::SshTunnelConfig out;
  if (!config)
    return out;

  out.enabled = config->enabled != 0;
  out.sshHost = copyCString(config->ssh_host);
  out.sshPort = config->ssh_port;
  out.sshUser = copyCString(config->ssh_user);
  out.authType = toSshAuthType(config->auth_type);
  out.sshPassword = copyCString(config->ssh_password);
  out.privateKeyPath = copyCString(config->private_key_path);
  out.publicKeyPath = copyCString(config->public_key_path);
  out.privateKeyPassphrase = copyCString(config->private_key_passphrase);
  out.knownHostsPath = copyCString(config->known_hosts_path);
  out.strictHostKeyCheck = config->strict_host_key_check != 0;
  out.remoteHost = copyCString(config->remote_host);
  out.remotePort = config->remote_port;
  return out;
}

std::string joinPath(const std::string& base, const char* leaf)
{
  if (base.empty())
    return leaf ? std::string(leaf) : std::string();
  if (!leaf || leaf[0] == '\0')
    return base;
  if (base.back() == '/')
    return base + leaf;
  return base + "/" + leaf;
}

void configureSecurityDefaults()
{
  rfb::Security security;

#ifdef HAVE_GNUTLS
  security.EnableSecType(rfb::secTypeX509Vnc);
  security.EnableSecType(rfb::secTypeX509Plain);
  security.EnableSecType(rfb::secTypeX509None);
  security.EnableSecType(rfb::secTypeTLSVnc);
  security.EnableSecType(rfb::secTypeTLSPlain);
  security.EnableSecType(rfb::secTypeTLSNone);
#endif
#ifdef HAVE_NETTLE
  security.EnableSecType(rfb::secTypeRA256);
  security.EnableSecType(rfb::secTypeRA2);
  security.EnableSecType(rfb::secTypeRAne256);
  security.EnableSecType(rfb::secTypeRA2ne);
  security.EnableSecType(rfb::secTypeDH);
  security.EnableSecType(rfb::secTypeMSLogonII);
#elif defined(OHOS) && !defined(ANDROID_BASIC)
  security.EnableSecType(rfb::secTypeDH);
#endif
  security.EnableSecType(rfb::secTypeVncAuth);
  security.EnableSecType(rfb::secTypePlain);
  security.EnableSecType(rfb::secTypeNone);

  rfb::SecurityClient::secTypes.setParam(security.ToString());

#ifdef HAVE_GNUTLS
  rfb::Security::GnuTLSPriority.setParam("NORMAL:-VERS-ALL:+VERS-TLS1.3:+VERS-TLS1.2");
#endif
}

void configureStorageRootInternal(const char* rootPath)
{
  if (!rootPath || rootPath[0] == '\0')
    return;

  std::string root(rootPath);
  std::string configHome = joinPath(root, ".config");
  std::string dataHome = joinPath(root, ".local/share");
  std::string stateHome = joinPath(root, ".local/state");
  std::string configDir = joinPath(configHome, "tigervnc");
  std::string dataDir = joinPath(dataHome, "tigervnc");
  std::string stateDir = joinPath(stateHome, "tigervnc");

  setenv("HOME", root.c_str(), 1);
  setenv("XDG_CONFIG_HOME", configHome.c_str(), 1);
  setenv("XDG_DATA_HOME", dataHome.c_str(), 1);
  setenv("XDG_STATE_HOME", stateHome.c_str(), 1);

  core::mkdir_p(configDir.c_str(), 0700);
  core::mkdir_p(dataDir.c_str(), 0700);
  core::mkdir_p(stateDir.c_str(), 0700);

#ifdef HAVE_GNUTLS
  core::Configuration::setParam("X509CA", joinPath(configDir, "x509_ca.pem").c_str());
  core::Configuration::setParam("X509CRL", joinPath(configDir, "x509_crl.pem").c_str());
#endif
}

void configureClientRuntime()
{
  std::call_once(gSecurityInitFlag, []() {
    configureSecurityDefaults();
  });
}

class SharedPixelBuffer final : public rfb::FullFramePixelBuffer {
public:
  SharedPixelBuffer(int width, int height)
    : rfb::FullFramePixelBuffer(rfb::PixelFormat(32, 24, false, true,
                                                 255, 255, 255, 0, 8, 16),
                                0, 0, nullptr, 0),
      width_(width),
      height_(height),
      buffer_(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u)
  {
    setBuffer(width_, height_, buffer_.data(), width_);
  }

  void commitBufferRW(const core::Rect& r) override
  {
    rfb::FullFramePixelBuffer::commitBufferRW(r);
    std::lock_guard<std::mutex> lock(mutex_);
    damage_.assign_union(r);
  }

  core::Rect consumeDamage()
  {
    std::lock_guard<std::mutex> lock(mutex_);
    core::Rect r = damage_.get_bounding_rect();
    damage_.clear();
    return r;
  }

  const uint8_t* data() const { return buffer_.data(); }
  int width() const { return width_; }
  int height() const { return height_; }
  int strideBytes() const { return width_ * 4; }

private:
  int width_;
  int height_;
  std::vector<uint8_t> buffer_;
  std::mutex mutex_;
  core::Region damage_;
};

class SharedConn final : public rfb::CConnection {
public:
  explicit SharedConn(vncclient_callbacks callbacks)
    : callbacks_(callbacks)
  {
    // Default to shared session to avoid disconnecting other viewers (or our own zombie session),
    // which can cause hangs or authentication failures on some servers (e.g. MacOS).
    setShared(true);
    supportsLocalCursor = true;
    supportsCursorPosition = true;
    supportsDesktopResize = true;
    supportsLEDState = true;

    setPreferredEncoding(rfb::encodingTight);
    setCompressLevel(kLanCompressLevel);
    setQualityLevel(kLanQualityLevel);
  }

  ~SharedConn() override
  {
    setFramebuffer(nullptr);
  }

  void bindSocket(network::Socket* sock, const char* serverName)
  {
    setServerName(serverName);
    setStreams(&sock->inStream(), &sock->outStream());
    initialiseProtocol();
  }

  SharedPixelBuffer* framebuffer() const { return framebuffer_; }

  int getSecurityLevel() const {
    if (!csecurity) return 0;
    int type = csecurity->getType();
    
    // Fully secure (Encryption of both Auth and Transmission)
    if (type == rfb::secTypeTLSNone || type == rfb::secTypeTLSVnc || type == rfb::secTypeTLSPlain ||
        type == rfb::secTypeX509None || type == rfb::secTypeX509Vnc || type == rfb::secTypeX509Plain ||
        type == rfb::secTypeTLS || type == rfb::secTypeVeNCrypt) {
        return 2;
    }
    
    // Auth secure (Encryption of Auth only)
    if (type == rfb::secTypeDH || type == rfb::secTypeVncAuth || 
        type == rfb::secTypeRA2 || type == rfb::secTypeRA2ne || 
        type == rfb::secTypeRA256 || type == rfb::secTypeRAne256 ||
        type == rfb::secTypeMSLogonII) {
        return 1;
    }
    
    // Insecure (No encryption or Plain text)
    return 0;
  }

  bool showMsgBox(rfb::MsgBoxFlags flags, const char* title,
                  const char* text) override
  {
    if (callbacks_.show_msg_box)
      return callbacks_.show_msg_box(callbacks_.user, static_cast<int>(flags), title, text) != 0;
    return false;
  }

  void getUserPasswd(bool secure, std::string* user,
                     std::string* password) override
  {
    if (!callbacks_.get_user_passwd)
      throw rfb::auth_cancelled();

    char userBuf[256] = {0};
    char passBuf[256] = {0};

    int ok = callbacks_.get_user_passwd(callbacks_.user, secure ? 1 : 0,
                                        user ? userBuf : nullptr,
                                        user ? sizeof(userBuf) : 0,
                                        passBuf, sizeof(passBuf));
    if (!ok)
      throw rfb::auth_cancelled();

    if (user)
      *user = userBuf;
    if (password)
      *password = passBuf;
  }

  void initDone() override
  {
    resizeFramebuffer();
    if (framebuffer_)
      setPF(framebuffer_->getPF());
  }

  void resizeFramebuffer() override
  {
    auto* newFb = new SharedPixelBuffer(server.width(), server.height());
    // DO NOT delete framebuffer_ here. CConnection::setFramebuffer takes ownership and will delete the old one.
    framebuffer_ = newFb;
    setFramebuffer(newFb);

    if (callbacks_.on_framebuffer_resize)
      callbacks_.on_framebuffer_resize(callbacks_.user, server.width(), server.height());
  }

  void framebufferUpdateEnd() override
  {
    rfb::CConnection::framebufferUpdateEnd();
    updateBandwidthEstimate();
    updateEncodingHints();

    if (!framebuffer_ || !callbacks_.on_framebuffer_update)
      return;

    core::Rect r = framebuffer_->consumeDamage();
    if (r.width() <= 0 || r.height() <= 0)
      return;

    callbacks_.on_framebuffer_update(callbacks_.user, r.tl.x, r.tl.y, r.width(), r.height());
  }

  void framebufferUpdateStart() override
  {
    rfb::CConnection::framebufferUpdateStart();

    auto* in = getInStream();
    if (!in)
      return;

    updateStartTime_ = std::chrono::steady_clock::now();
    updateStartPos_ = in->pos();
  }

  void setCursor(int width, int height, const core::Point& hotspot,
                 const uint8_t* data) override
  {
    rfb::CConnection::setCursor(width, height, hotspot, data);

    if (!callbacks_.on_cursor)
      return;

    int len = 0;
    if (width > 0 && height > 0) {
      size_t slen = static_cast<size_t>(width) * static_cast<size_t>(height) * 4u;
      if (slen > static_cast<size_t>(INT32_MAX))
        return;
      len = static_cast<int>(slen);
    }

    callbacks_.on_cursor(callbacks_.user, width, height,
                         hotspot.x, hotspot.y,
                         data, len);
  }

  void bell() override
  {
  }

  void handleClipboardAnnounce(bool available) override
  {
    if (callbacks_.on_clipboard_announce)
      callbacks_.on_clipboard_announce(callbacks_.user, available ? 1 : 0);
  }

  void handleClipboardData(const char* data) override
  {
    if (callbacks_.on_clipboard_data)
      callbacks_.on_clipboard_data(callbacks_.user, data ? data : "");
  }

private:
  void updateBandwidthEstimate()
  {
    auto* in = getInStream();
    if (!in)
      return;

    const auto now = std::chrono::steady_clock::now();
    const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(now - updateStartTime_).count();
    if (elapsed <= 0)
      return;

    const size_t endPos = in->pos();
    if (endPos <= updateStartPos_)
      return;

    const unsigned long long bitsRead =
      static_cast<unsigned long long>(endPos - updateStartPos_) * 8ULL;
    const unsigned long long elapsedUs = static_cast<unsigned long long>(elapsed);
    const unsigned long long bps = std::max(1ULL, bitsRead * 1000000ULL / elapsedUs);
    unsigned long long weight = elapsedUs * 1000ULL / kBandwidthEstimateWindowMs;
    weight = std::min(weight, kBandwidthEstimateMaxWeight);

    bandwidthEstimateBps_ =
      ((bandwidthEstimateBps_ * (1000000ULL - weight)) + (bps * weight)) / 1000000ULL;
  }

  void updateEncodingHints()
  {
    const int targetQuality =
      bandwidthEstimateBps_ > kLanQualityThresholdBps ? kLanQualityLevel : kWanQualityLevel;
    const int targetCompress =
      bandwidthEstimateBps_ > kLanQualityThresholdBps ? kLanCompressLevel : kWanCompressLevel;

    setPreferredEncoding(rfb::encodingTight);
    setQualityLevel(targetQuality);
    setCompressLevel(targetCompress);
  }

  vncclient_callbacks callbacks_;
  SharedPixelBuffer* framebuffer_ = nullptr;
  std::chrono::steady_clock::time_point updateStartTime_ = std::chrono::steady_clock::now();
  size_t updateStartPos_ = 0;
  unsigned long long bandwidthEstimateBps_ = kInitialBandwidthEstimateBps;
};

struct Client {
  vncclient_callbacks callbacks{};
  std::string lastError;

  shared::SshTunnelConfig sshConfig;
  std::unique_ptr<shared::SshTunnel> sshTunnel;
  std::string host;
  int port = 0;

  network::Socket* sock = nullptr;
  SharedConn* conn = nullptr;
};

static int getEffectiveSecurityLevel(const Client* c)
{
  if (!c || !c->conn)
    return 0;

  int level = c->conn->getSecurityLevel();

  // SSH tunneling encrypts the transport even when the inner VNC security
  // type only protects authentication.
  if (c->sshTunnel)
    return 2;

  return level;
}

static void setError(Client* c, const std::string& s)
{
  if (!c)
    return;
  c->lastError = s;
  vlog.error("%s", s.c_str());
}

static void disconnectOnFailure(Client* c)
{
  if (!c)
    return;

  // Already disconnected?
  if (!c->sock)
    return;

  try {
    if (c->conn) {
      c->conn->releaseAllKeys();
    }
  } catch (std::exception&) {
  }

  try {
    if (c->sock) {
      c->sock->shutdown();
    }
  } catch (std::exception&) {
  }

  try {
    if (c->conn)
      c->conn->close();
  } catch (std::exception&) {
  }

  if (c->sock) {
    delete c->sock;
    c->sock = nullptr;
  }

  c->sshTunnel.reset();

  c->host.clear();
  c->port = 0;
}

static int fail(Client* c, const std::string& s)
{
  setError(c, s);
  return -1;
}

static bool validClient(vncclient_handle* client)
{
  return client != nullptr;
}

}

struct vncclient_handle {
  Client impl;
};

vncclient_handle* vncclient_create(const vncclient_callbacks* callbacks)
{
  configureClientRuntime();
  auto* h = new vncclient_handle();
  if (callbacks)
    h->impl.callbacks = *callbacks;
  h->impl.conn = new SharedConn(h->impl.callbacks);
  return h;
}

void vncclient_destroy(vncclient_handle* client)
{
  if (!client)
    return;
  vncclient_disconnect(client);
  delete client->impl.conn;
  client->impl.conn = nullptr;
  delete client;
}

void vncclient_set_storage_root(const char* root_path)
{
  configureClientRuntime();
  configureStorageRootInternal(root_path);
}

int vncclient_set_ssh_tunnel(vncclient_handle* client, const vncclient_ssh_config* config)
{
  if (!validClient(client))
    return -1;

  client->impl.sshConfig = toSshTunnelConfig(config);
  if (!client->impl.sshConfig.enabled)
    client->impl.sshTunnel.reset();

  std::string error;
  if (!client->impl.sshConfig.Validate(&error))
    return fail(&client->impl, error);

  client->impl.lastError.clear();
  return 0;
}

void vncclient_clear_ssh_tunnel(vncclient_handle* client)
{
  if (!validClient(client))
    return;
  client->impl.sshConfig = shared::SshTunnelConfig();
  client->impl.sshTunnel.reset();
}

int vncclient_connect(vncclient_handle* client, const char* host_port, int base_port)
{
  if (!validClient(client))
    return -1;
  if (!host_port || host_port[0] == '\0')
    return fail(&client->impl, "empty host");

  vncclient_disconnect(client);

  // Recreate the connection object to ensure a clean protocol state for the new session
  if (client->impl.conn) {
    delete client->impl.conn;
  }
  client->impl.conn = new SharedConn(client->impl.callbacks);

  try {
    network::getHostAndPort(host_port, &client->impl.host, &client->impl.port, base_port);
    std::string connectHost = client->impl.host;
    int connectPort = client->impl.port;

    shared::SshTunnelConfig tunnelConfig = shared::NormalizeSshTunnelConfig(
      client->impl.sshConfig, client->impl.host, client->impl.port);
    if (tunnelConfig.IsEnabled()) {
      std::string sshError;
      client->impl.sshTunnel = shared::SshTunnel::Open(tunnelConfig, &sshError);
      if (!client->impl.sshTunnel)
        return fail(&client->impl, sshError);
      if (!client->impl.sshTunnel->WaitUntilReady(3000, &sshError)) {
        client->impl.sshTunnel.reset();
        return fail(&client->impl, sshError);
      }
      connectHost = "127.0.0.1";
      connectPort = client->impl.sshTunnel->localPort();
    }

    client->impl.sock = new network::TcpSocket(connectHost.c_str(), connectPort);
    client->impl.conn->bindSocket(client->impl.sock, connectHost.c_str());
    client->impl.lastError.clear();
    return 0;
  } catch (std::exception& e) {
    vncclient_disconnect(client);
    return fail(&client->impl, e.what());
  }
}

int vncclient_disconnect(vncclient_handle* client)
{
  if (!validClient(client))
    return -1;

  // Already disconnected?
  if (!client->impl.sock)
    return 0;

  try {
    if (client->impl.conn) {
      client->impl.conn->releaseAllKeys();
    }
  } catch (std::exception&) {
  }

  try {
    if (client->impl.sock) {
      client->impl.sock->shutdown();
    }
  } catch (std::exception&) {
  }

  try {
    if (client->impl.conn)
      client->impl.conn->close();
  } catch (std::exception&) {
  }

  if (client->impl.conn) {
    delete client->impl.conn;
    client->impl.conn = nullptr;
  }

  if (client->impl.sock) {
    delete client->impl.sock;
    client->impl.sock = nullptr;
  }

  client->impl.sshTunnel.reset();

  client->impl.host.clear();
  client->impl.port = 0;
  return 0;
}

int vncclient_is_connected(vncclient_handle* client)
{
  if (!validClient(client))
    return 0;
  return client->impl.sock != nullptr ? 1 : 0;
}

int vncclient_get_fd(vncclient_handle* client)
{
  if (!validClient(client) || !client->impl.sock)
    return -1;
  return client->impl.sock->getFd();
}

int vncclient_get_state(vncclient_handle* client)
{
  if (!validClient(client) || !client->impl.conn)
    return -1;
  return static_cast<int>(client->impl.conn->state());
}

int vncclient_is_secure(vncclient_handle* client) {
  if (!client || !client->impl.conn) return 0;
  return getEffectiveSecurityLevel(&client->impl) >= 2 ? 1 : 0;
}

int vncclient_get_security_level(vncclient_handle* client) {
  if (!client || !client->impl.conn) return 0;
  return getEffectiveSecurityLevel(&client->impl);
}

const char* vncclient_get_name(vncclient_handle* client) {
  if (!validClient(client) || !client->impl.conn)
    return "";
  return client->impl.conn->server.name();
}

static int processInternal(Client* c)
{
  if (!c || !c->sock || !c->conn)
    return -1;

  try {
    c->sock->outStream().flush();

    c->conn->getOutStream()->cork(true);
    while (c->conn->processMsg()) {
      c->sock->outStream().flush();
    }
    c->conn->getOutStream()->cork(false);
    c->sock->outStream().flush();

    return 0;
  } catch (rdr::end_of_stream& e) {
    setError(c, e.what());
    disconnectOnFailure(c);
    return 1;
  } catch (rfb::auth_cancelled& e) {
    setError(c, e.what());
    disconnectOnFailure(c);
    return 2;
  } catch (rfb::auth_error& e) {
    setError(c, e.what());
    disconnectOnFailure(c);
    return 3;
  } catch (std::exception& e) {
    setError(c, e.what());
    disconnectOnFailure(c);
    return 4;
  }
}

int vncclient_process(vncclient_handle* client)
{
  if (!validClient(client))
    return -1;
  return processInternal(&client->impl);
}

int vncclient_refresh(vncclient_handle* client)
{
  if (!validClient(client) || !client->impl.conn || !client->impl.sock)
    return -1;
  try {
    client->impl.conn->refreshFramebuffer();
    client->impl.sock->outStream().flush();
    return 0;
  } catch (std::exception& e) {
    return fail(&client->impl, e.what());
  }
}

int vncclient_get_framebuffer(vncclient_handle* client,
                              int* width, int* height,
                              int* stride_bytes,
                              const uint8_t** rgba)
{
  if (!validClient(client) || !client->impl.conn)
    return -1;
  SharedPixelBuffer* fb = client->impl.conn->framebuffer();
  if (!fb)
    return -1;
  if (width)
    *width = fb->width();
  if (height)
    *height = fb->height();
  if (stride_bytes)
    *stride_bytes = fb->strideBytes();
  if (rgba)
    *rgba = fb->data();
  return 0;
}

int vncclient_consume_damage(vncclient_handle* client,
                             int* x, int* y, int* w, int* h)
{
  if (!validClient(client) || !client->impl.conn)
    return 0;
  SharedPixelBuffer* fb = client->impl.conn->framebuffer();
  if (!fb)
    return 0;
  core::Rect r = fb->consumeDamage();
  if (r.width() <= 0 || r.height() <= 0)
    return 0;
  if (x)
    *x = r.tl.x;
  if (y)
    *y = r.tl.y;
  if (w)
    *w = r.width();
  if (h)
    *h = r.height();
  return 1;
}

int vncclient_send_pointer(vncclient_handle* client,
                           int x, int y, uint16_t button_mask)
{
  if (!validClient(client) || !client->impl.conn || !client->impl.sock)
    return -1;
  try {
    if (client->impl.conn->state() != rfb::CConnection::RFBSTATE_NORMAL)
      return -1;
    rfb::CMsgWriter* w = client->impl.conn->writer();
    if (!w)
      return -1;
    w->writePointerEvent(core::Point(x, y), button_mask);
    client->impl.sock->outStream().flush();
    return 0;
  } catch (std::exception& e) {
    return fail(&client->impl, e.what());
  }
}

int vncclient_send_key_press(vncclient_handle* client,
                             int system_key_code,
                             uint32_t key_code, uint32_t key_sym)
{
  if (!validClient(client) || !client->impl.conn || !client->impl.sock)
    return -1;
  try {
    client->impl.conn->sendKeyPress(system_key_code, key_code, key_sym);
    client->impl.sock->outStream().flush();
    return 0;
  } catch (std::exception& e) {
    return fail(&client->impl, e.what());
  }
}

int vncclient_send_key_release(vncclient_handle* client,
                               int system_key_code)
{
  if (!validClient(client) || !client->impl.conn || !client->impl.sock)
    return -1;
  try {
    client->impl.conn->sendKeyRelease(system_key_code);
    client->impl.sock->outStream().flush();
    return 0;
  } catch (std::exception& e) {
    return fail(&client->impl, e.what());
  }
}

int vncclient_release_all_keys(vncclient_handle* client)
{
  if (!validClient(client) || !client->impl.conn || !client->impl.sock)
    return -1;
  try {
    client->impl.conn->releaseAllKeys();
    client->impl.sock->outStream().flush();
    return 0;
  } catch (std::exception& e) {
    return fail(&client->impl, e.what());
  }
}

int vncclient_request_clipboard(vncclient_handle* client)
{
  if (!validClient(client) || !client->impl.conn || !client->impl.sock)
    return -1;
  try {
    client->impl.conn->requestClipboard();
    client->impl.sock->outStream().flush();
    return 0;
  } catch (std::exception& e) {
    return fail(&client->impl, e.what());
  }
}

int vncclient_announce_clipboard(vncclient_handle* client, int available)
{
  if (!validClient(client) || !client->impl.conn || !client->impl.sock)
    return -1;
  try {
    client->impl.conn->announceClipboard(available != 0);
    client->impl.sock->outStream().flush();
    return 0;
  } catch (std::exception& e) {
    return fail(&client->impl, e.what());
  }
}

int vncclient_send_clipboard(vncclient_handle* client, const char* utf8)
{
  if (!validClient(client) || !client->impl.conn || !client->impl.sock)
    return -1;
  try {
    client->impl.conn->sendClipboardData(utf8 ? utf8 : "");
    client->impl.sock->outStream().flush();
    return 0;
  } catch (std::exception& e) {
    return fail(&client->impl, e.what());
  }
}

const char* vncclient_last_error(vncclient_handle* client)
{
  if (!validClient(client))
    return "";
  return client->impl.lastError.c_str();
}
