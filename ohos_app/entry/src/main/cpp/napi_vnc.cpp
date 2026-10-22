#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdarg>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include <poll.h>

#include <napi/native_api.h>

#include "vncclient.h"
#include "desktop_resize.h"
#include "monitor_segmentation.h"
#include "pixel_convert.h"
#include <vector>

namespace {

struct DamageRect {
  int x;
  int y;
  int w;
  int h;
};

struct PendingSshConfig {
  bool enabled = false;
  std::string sshHost;
  int32_t sshPort = 22;
  std::string sshUser;
  int32_t authType = VNCCLIENT_SSH_AUTH_PASSWORD;
  std::string sshPassword;
  std::string privateKeyPath;
  std::string publicKeyPath;
  std::string privateKeyPassphrase;
  std::string knownHostsPath;
  bool strictHostKeyCheck = false;
  std::string remoteHost;
  int32_t remotePort = 0;
};

struct ClientState {
  // Guards `client` and `clientGeneration`. Held while a vncclient_* call is in
  // flight. Lock order: clientMu before mu, never the other way around.
  std::mutex clientMu;
  vncclient_handle* client = nullptr;
  // Bumped whenever the handle is replaced, so an asynchronous connect that
  // finishes after the session was torn down can tell it is stale.
  uint64_t clientGeneration = 0;

  std::mutex mu;
  // Background pump. It only drains the socket and never calls into JS, so it is
  // safe to run off the UI thread; the JS side keeps owning rendering.
  std::mutex pumpMu;
  std::thread pumpThread;
  std::atomic<bool> pumpRun{false};
  std::atomic<bool> pumpActive{false};
  std::optional<DamageRect> damage;
  int remoteClipboardAnnounce = -1;
  bool remoteClipboardDirty = false;
  std::string remoteClipboardUtf8;

  std::string user;
  std::string password;

  bool debugEnabled = false;
  int32_t debugLevel = 0;
  int32_t byteOrder = 0;
  int32_t pixelMapFormat = 0;
  uint64_t fbUpdateCount = 0;
  DamageRect lastFbUpdate{0, 0, 0, 0};
  uint64_t processCount = 0;
  int32_t lastProcessRc = 0;
  uint32_t lastChecksum = 0;
  std::string debugLog;
  std::optional<PendingSshConfig> pendingSshConfig;
};

static bool GetStringArg(napi_env env, napi_value v, std::string* out);
static bool GetInt32Arg(napi_env env, napi_value v, int32_t* out);
static bool GetBoolArg(napi_env env, napi_value v, bool* out);
static bool GetDoubleArg(napi_env env, napi_value v, double* out);
static bool GetNamedProperty(napi_env env, napi_value obj, const char* name, napi_value* out);



static void MergeDamage(std::optional<DamageRect>& dst, const DamageRect& add)
{
  if (!dst.has_value()) {
    dst = add;
    return;
  }

  int x1 = std::min(dst->x, add.x);
  int y1 = std::min(dst->y, add.y);
  int x2 = std::max(dst->x + dst->w, add.x + add.w);
  int y2 = std::max(dst->y + dst->h, add.y + add.h);
  dst = DamageRect{ x1, y1, x2 - x1, y2 - y1 };
}

static void AppendDebugLogLocked(ClientState& st, const char* fmt, ...)
{
  if (!st.debugEnabled || st.debugLevel <= 0)
    return;

  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);

  if (n <= 0)
    return;

  st.debugLog.append(buf, static_cast<size_t>(std::min(n, static_cast<int>(sizeof(buf) - 1))));
  st.debugLog.push_back('\n');
  if (st.debugLog.size() > 64 * 1024) {
    st.debugLog.erase(0, st.debugLog.size() - 48 * 1024);
  }
}

static uint32_t Fnv1a32(const uint8_t* data, size_t len)
{
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < len; i++) {
    h ^= data[i];
    h *= 16777619u;
  }
  return h;
}

static bool ParseSshTunnelConfig(napi_env env, napi_value value, PendingSshConfig* out)
{
  if (!out)
    return false;

  PendingSshConfig config;
  napi_value prop;
  if (GetNamedProperty(env, value, "enabled", &prop))
    GetBoolArg(env, prop, &config.enabled);
  if (GetNamedProperty(env, value, "sshHost", &prop))
    GetStringArg(env, prop, &config.sshHost);
  if (GetNamedProperty(env, value, "sshPort", &prop))
    GetInt32Arg(env, prop, &config.sshPort);
  if (GetNamedProperty(env, value, "sshUser", &prop))
    GetStringArg(env, prop, &config.sshUser);
  if (GetNamedProperty(env, value, "authType", &prop))
    GetInt32Arg(env, prop, &config.authType);
  if (GetNamedProperty(env, value, "sshPassword", &prop))
    GetStringArg(env, prop, &config.sshPassword);
  if (GetNamedProperty(env, value, "privateKeyPath", &prop))
    GetStringArg(env, prop, &config.privateKeyPath);
  if (GetNamedProperty(env, value, "publicKeyPath", &prop))
    GetStringArg(env, prop, &config.publicKeyPath);
  if (GetNamedProperty(env, value, "privateKeyPassphrase", &prop))
    GetStringArg(env, prop, &config.privateKeyPassphrase);
  if (GetNamedProperty(env, value, "knownHostsPath", &prop))
    GetStringArg(env, prop, &config.knownHostsPath);
  if (GetNamedProperty(env, value, "strictHostKeyCheck", &prop))
    GetBoolArg(env, prop, &config.strictHostKeyCheck);
  if (GetNamedProperty(env, value, "remoteHost", &prop))
    GetStringArg(env, prop, &config.remoteHost);
  if (GetNamedProperty(env, value, "remotePort", &prop))
    GetInt32Arg(env, prop, &config.remotePort);

  *out = std::move(config);
  return true;
}

static int ApplySshTunnelConfig(vncclient_handle* client, const PendingSshConfig& config)
{
  if (!client)
    return -1;

  vncclient_ssh_config nativeConfig{};
  nativeConfig.enabled = config.enabled ? 1 : 0;
  nativeConfig.ssh_host = config.sshHost.c_str();
  nativeConfig.ssh_port = config.sshPort;
  nativeConfig.ssh_user = config.sshUser.c_str();
  nativeConfig.auth_type = config.authType;
  nativeConfig.ssh_password = config.sshPassword.c_str();
  nativeConfig.private_key_path = config.privateKeyPath.c_str();
  nativeConfig.public_key_path = config.publicKeyPath.c_str();
  nativeConfig.private_key_passphrase = config.privateKeyPassphrase.c_str();
  nativeConfig.known_hosts_path = config.knownHostsPath.c_str();
  nativeConfig.strict_host_key_check = config.strictHostKeyCheck ? 1 : 0;
  nativeConfig.remote_host = config.remoteHost.c_str();
  nativeConfig.remote_port = config.remotePort;
  return vncclient_set_ssh_tunnel(client, &nativeConfig);
}

static int cb_get_user_passwd(void* user, int /*secure*/,
                              char* user_buf, size_t user_len,
                              char* pass_buf, size_t pass_len)
{
  auto* st = static_cast<ClientState*>(user);
  if (!st) return 0;

  std::lock_guard<std::mutex> lock(st->mu);

  if (user_buf && user_len > 0) {
    if (st->user.empty()) {
      user_buf[0] = '\0';
    } else {
      std::strncpy(user_buf, st->user.c_str(), user_len - 1);
      user_buf[user_len - 1] = '\0';
    }
  }

  if (!pass_buf || pass_len == 0)
    return 0;
  if (st->password.empty())
    return 0;
  std::strncpy(pass_buf, st->password.c_str(), pass_len - 1);
  pass_buf[pass_len - 1] = '\0';
  return 1;
}

static int cb_show_msg_box(void*, int, const char*, const char*)
{
  return 1;
}

static void cb_on_framebuffer_update(void* user, int x, int y, int w, int h)
{
  auto* st = static_cast<ClientState*>(user);
  if (!st) return;

  std::lock_guard<std::mutex> lock(st->mu);
  MergeDamage(st->damage, DamageRect{ x, y, w, h });
  st->fbUpdateCount++;
  st->lastFbUpdate = DamageRect{ x, y, w, h };
  if (st->debugEnabled && st->debugLevel >= 2) {
    AppendDebugLogLocked(*st, "fb_update #%llu rect=%d,%d %dx%d",
                         static_cast<unsigned long long>(st->fbUpdateCount),
                         x, y, w, h);
  }
}

static void cb_on_clipboard_announce(void* user, int available)
{
  auto* st = static_cast<ClientState*>(user);
  if (!st) return;

  std::lock_guard<std::mutex> lock(st->mu);
  st->remoteClipboardAnnounce = available != 0 ? 1 : 0;
  if (st->debugEnabled && st->debugLevel >= 1) {
    AppendDebugLogLocked(*st, "clipboard announce available=%d", available);
  }
  if (available == 0) {
    st->remoteClipboardDirty = false;
    st->remoteClipboardUtf8.clear();
  }
}

static void cb_on_clipboard_data(void* user, const char* utf8)
{
  auto* st = static_cast<ClientState*>(user);
  if (!st) return;

  std::lock_guard<std::mutex> lock(st->mu);
  st->remoteClipboardUtf8 = utf8 ? utf8 : "";
  st->remoteClipboardDirty = true;
  if (st->debugEnabled && st->debugLevel >= 1) {
    AppendDebugLogLocked(*st, "clipboard data len=%zu",
                         st->remoteClipboardUtf8.size());
  }
}

static napi_value MakeString(napi_env env, const std::string& s)
{
  napi_value out;
  napi_create_string_utf8(env, s.c_str(), s.size(), &out);
  return out;
}

static bool GetStringArg(napi_env env, napi_value v, std::string* out)
{
  size_t len = 0;
  napi_status st = napi_get_value_string_utf8(env, v, nullptr, 0, &len);
  if (st != napi_ok) return false;
  std::string s;
  s.resize(len);
  napi_get_value_string_utf8(env, v, s.data(), s.size() + 1, &len);
  *out = std::move(s);
  return true;
}

static bool GetInt32Arg(napi_env env, napi_value v, int32_t* out)
{
  return napi_get_value_int32(env, v, out) == napi_ok;
}

static bool GetBoolArg(napi_env env, napi_value v, bool* out)
{
  return napi_get_value_bool(env, v, out) == napi_ok;
}

static bool GetDoubleArg(napi_env env, napi_value v, double* out)
{
  return napi_get_value_double(env, v, out) == napi_ok;
}

static bool GetNamedProperty(napi_env env, napi_value obj, const char* name, napi_value* out)
{
  bool has = false;
  if (napi_has_named_property(env, obj, name, &has) != napi_ok || !has)
    return false;
  return napi_get_named_property(env, obj, name, out) == napi_ok;
}

static bool NormalizeCopyRect(int fb_w, int fb_h, int x, int y, int w, int h, DamageRect* out)
{
  if (!out || fb_w <= 0 || fb_h <= 0)
    return false;

  int nx = std::max(0, x);
  int ny = std::max(0, y);
  int rx = std::max(0, x + w);
  int by = std::max(0, y + h);

  nx = std::min(nx, fb_w);
  ny = std::min(ny, fb_h);
  rx = std::min(rx, fb_w);
  by = std::min(by, fb_h);

  int nw = rx - nx;
  int nh = by - ny;
  if (nw <= 0 || nh <= 0)
    return false;

  *out = DamageRect{ nx, ny, nw, nh };
  return true;
}

// Callers must hold ClientState::clientMu: this reads the shared framebuffer
// and converts it, and must not run concurrently with process().
static napi_value CopyFrameRectRGBA(napi_env env, ClientState& st, int32_t byteOrder, int32_t pixelMapFormat,
                                    std::optional<DamageRect> rect)
{
  napi_value nullValue;
  napi_get_null(env, &nullValue);

  if (!st.client)
    return nullValue;

  int fbW = 0;
  int fbH = 0;
  int stride = 0;
  const uint8_t* rgba = nullptr;

  try {
    if (vncclient_get_framebuffer(st.client, &fbW, &fbH, &stride, &rgba) != 0)
      return nullValue;
  } catch (...) {
    return nullValue;
  }

  if (fbW <= 0 || fbH <= 0 || !rgba || stride < fbW * 4)
    return nullValue;

  DamageRect copyRect{ 0, 0, fbW, fbH };
  if (rect.has_value()) {
    if (!NormalizeCopyRect(fbW, fbH, rect->x, rect->y, rect->w, rect->h, &copyRect))
      return nullValue;
  }

  size_t size = static_cast<size_t>(copyRect.w) * static_cast<size_t>(copyRect.h) * 4u;
  void* data = nullptr;
  napi_value arraybuffer;
  napi_create_arraybuffer(env, size, &data, &arraybuffer);
  if (!data)
    return arraybuffer;

  uint8_t* dst = static_cast<uint8_t*>(data);
  const bool wantBGRA = (pixelMapFormat != 0);

  try {
    const size_t srcStride = static_cast<size_t>(std::max(0, stride));
    const size_t dstStride = static_cast<size_t>(copyRect.w) * 4u;
    const size_t srcOffset = static_cast<size_t>(copyRect.y) * srcStride +
                             static_cast<size_t>(copyRect.x) * 4u;
    shared::pixel::ConvertRectPixels(rgba + srcOffset, srcStride, dst, dstStride,
                                     copyRect.w, copyRect.h, byteOrder, wantBGRA);
  } catch (...) {
  }

  {
    std::lock_guard<std::mutex> lock(st.mu);
    if (st.debugEnabled) {
      size_t sample = std::min<size_t>(4096, size);
      st.lastChecksum = Fnv1a32(dst, sample);
    }
  }

  return arraybuffer;
}

// ---------------------------------------------------------------------------
// Background pump
//
// Reading and decoding a framebuffer update used to happen inside process() on
// the UI thread, so a large or slow update could monopolise it for seconds. The
// pump drains the socket on its own thread instead; the UI thread keeps calling
// process(), which now just reports status and returns immediately.

// How long the pump waits for the server before checking whether it should stop.
// The wait ends immediately when data arrives, so this only bounds shutdown
// latency, not update latency.
constexpr int kPumpPollTimeoutMs = 50;

static void PumpLoop(ClientState* st)
{
  while (st->pumpRun.load(std::memory_order_acquire)) {
    // Wait for the server instead of polling: waking every few milliseconds cost
    // about 6% of a core while the session sat idle.
    int fd = -1;
    {
      std::lock_guard<std::mutex> clientLock(st->clientMu);
      if (!st->client)
        break;
      fd = vncclient_get_fd(st->client);
    }

    if (fd >= 0) {
      struct pollfd pfd;
      pfd.fd = fd;
      pfd.events = POLLIN;
      pfd.revents = 0;
      const int ready = ::poll(&pfd, 1, kPumpPollTimeoutMs);
      if (ready < 0) {
        if (errno == EINTR)
          continue;
        break;
      }
    } else {
      std::this_thread::sleep_for(std::chrono::milliseconds(kPumpPollTimeoutMs));
    }

    if (!st->pumpRun.load(std::memory_order_acquire))
      break;

    int rc = 0;
    {
      std::lock_guard<std::mutex> clientLock(st->clientMu);
      if (!st->client)
        break;
      rc = vncclient_process(st->client);
      if (rc == 0) {
        std::lock_guard<std::mutex> stateLock(st->mu);
        st->processCount++;
        st->lastProcessRc = 0;
      }
    }

    if (rc != 0)
      break;
  }

  st->pumpActive.store(false, std::memory_order_release);
}

static bool StartPump(ClientState* st)
{
  std::lock_guard<std::mutex> pumpLock(st->pumpMu);
  if (st->pumpThread.joinable())
    return true;
  {
    std::lock_guard<std::mutex> clientLock(st->clientMu);
    if (!st->client)
      return false;
  }
  st->pumpRun.store(true, std::memory_order_release);
  st->pumpActive.store(true, std::memory_order_release);
  try {
    st->pumpThread = std::thread(PumpLoop, st);
  } catch (...) {
    st->pumpActive.store(false, std::memory_order_release);
    st->pumpRun.store(false, std::memory_order_release);
    return false;
  }
  return true;
}

// Must be called without holding clientMu: the pump takes that lock on every
// iteration, so joining while holding it would deadlock.
static void StopPump(ClientState* st)
{
  std::thread worker;
  {
    std::lock_guard<std::mutex> pumpLock(st->pumpMu);
    if (!st->pumpThread.joinable()) {
      st->pumpActive.store(false, std::memory_order_release);
      return;
    }
    st->pumpRun.store(false, std::memory_order_release);
    worker = std::move(st->pumpThread);
  }
  if (worker.joinable())
    worker.join();
  st->pumpActive.store(false, std::memory_order_release);
}

struct ConnectData {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  napi_ref selfRef = nullptr;
  ClientState* st = nullptr;
  // Pinned for the duration of the async work: the owning ClientState may be
  // torn down while the worker is still connecting, and this reference keeps
  // the handle alive until the worker is done with it.
  vncclient_handle* client = nullptr;
  uint64_t generation = 0;
  std::string addr;
  int32_t basePort = 5900;
  std::string user;
  std::string pass;
  int rc = -1;
};

static void VncConnectExecute(napi_env env, void* data) {
  auto* req = static_cast<ConnectData*>(data);
  // Never touch req->st here: only the pinned handle and the request itself are
  // guaranteed to outlive the worker.
  if (!req->client) return;
  req->rc = vncclient_connect(req->client, req->addr.c_str(), req->basePort);
  if (req->rc == 0) {
    vncclient_announce_clipboard(req->client, 1);
  }
}

static void VncConnectComplete(napi_env env, napi_status status, void* data) {
  auto* req = static_cast<ConnectData*>(data);

  int rc = req->rc;
  if (req->st) {
    std::lock_guard<std::mutex> lock(req->st->clientMu);
    // The session may have been disconnected (or replaced) while we were
    // connecting. Report that instead of claiming a live connection.
    if (req->st->client != req->client || req->st->clientGeneration != req->generation) {
      if (rc == 0) rc = -1;
    }
  }
  if (rc != req->rc) {
    // Stale attempt: roll the connection back on the pinned handle.
    if (req->client) vncclient_disconnect(req->client);
  }

  // A live session is drained by the pump from here on.
  if (rc == 0 && req->st)
    StartPump(req->st);

  if (req->client) {
    vncclient_release(req->client);
    req->client = nullptr;
  }

  napi_value result;
  napi_create_int32(env, rc, &result);
  napi_resolve_deferred(env, req->deferred, result);
  napi_delete_async_work(env, req->work);
  if (req->selfRef) {
    napi_delete_reference(env, req->selfRef);
    req->selfRef = nullptr;
  }
  delete req;
}

static napi_value VncConnect(napi_env env, napi_callback_info info)
{
  size_t argc = 4;
  napi_value argv[4];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);

  std::string addr;
  int32_t basePort = 5900;
  std::string user;
  std::string pass;

  if (argc < 1 || !GetStringArg(env, argv[0], &addr)) {
    napi_throw_error(env, nullptr, "address is required");
    return nullptr;
  }
  if (argc >= 2) GetInt32Arg(env, argv[1], &basePort);
  if (argc >= 3) GetStringArg(env, argv[2], &user);
  if (argc >= 4) GetStringArg(env, argv[3], &pass);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;

  // Pin the JS object for the whole connect attempt. Without this the object
  // can be collected while the background worker is still running, which frees
  // ClientState and the client handle underneath it.
  napi_ref selfRef = nullptr;
  if (napi_create_reference(env, jsthis, 1, &selfRef) != napi_ok) {
    napi_throw_error(env, nullptr, "failed to pin client object");
    return nullptr;
  }

  vncclient_handle* attempt = nullptr;
  uint64_t generation = 0;
  int sshRc = 0;
  bool hasPendingSsh = false;

  // The pump holds clientMu on every iteration, so it has to be stopped before
  // taking that lock to replace the handle.
  StopPump(&st);

  {
    std::lock_guard<std::mutex> clientLock(st.clientMu);

    if (st.client) {
      vncclient_handle* previous = st.client;
      st.client = nullptr;
      st.clientGeneration++;
      vncclient_disconnect(previous);
      vncclient_destroy(previous);
    }

    vncclient_callbacks cbs{};
    cbs.user = &st;
    cbs.get_user_passwd = cb_get_user_passwd;
    cbs.show_msg_box = cb_show_msg_box;
    cbs.on_framebuffer_update = cb_on_framebuffer_update;
    cbs.on_clipboard_announce = cb_on_clipboard_announce;
    cbs.on_clipboard_data = cb_on_clipboard_data;

    attempt = vncclient_create(&cbs);
    if (!attempt) {
      napi_delete_reference(env, selfRef);
      napi_throw_error(env, nullptr, "failed to create client");
      return nullptr;
    }
    st.client = attempt;
    st.clientGeneration++;
    generation = st.clientGeneration;

    {
      std::lock_guard<std::mutex> lock(st.mu);
      st.user = user;
      st.password = pass;
      st.damage.reset();
      st.remoteClipboardAnnounce = -1;
      st.remoteClipboardDirty = false;
      st.remoteClipboardUtf8.clear();
    }

    if (st.pendingSshConfig.has_value()) {
      hasPendingSsh = true;
      sshRc = ApplySshTunnelConfig(attempt, *st.pendingSshConfig);
    }
  }

  if (hasPendingSsh && sshRc != 0) {
    napi_value promise;
    napi_deferred deferred;
    napi_create_promise(env, &deferred, &promise);
    napi_value result;
    napi_create_int32(env, sshRc, &result);
    napi_resolve_deferred(env, deferred, result);
    napi_delete_reference(env, selfRef);
    return promise;
  }

  auto* req = new ConnectData();
  req->st = &st;
  req->selfRef = selfRef;
  req->client = attempt;
  req->generation = generation;
  // The worker keeps its own reference so teardown can proceed concurrently.
  vncclient_acquire(attempt);
  req->addr = addr;
  req->basePort = basePort;
  req->user = user;
  req->pass = pass;

  napi_value promise;
  napi_create_promise(env, &req->deferred, &promise);

  napi_value resourceName;
  napi_create_string_utf8(env, "VncConnect", NAPI_AUTO_LENGTH, &resourceName);
  napi_create_async_work(env, nullptr, resourceName, VncConnectExecute, VncConnectComplete, req, &req->work);
  napi_queue_async_work(env, req->work);

  return promise;
}

static napi_value VncDisconnect(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  StopPump(&st);
  {
    std::lock_guard<std::mutex> clientLock(st.clientMu);
    if (st.client) {
      vncclient_handle* previous = st.client;
      st.client = nullptr;
      // Invalidate any connect attempt still in flight so it reports failure
      // instead of resurrecting a session the user just closed.
      st.clientGeneration++;
      vncclient_disconnect(previous);
      vncclient_destroy(previous);
    }
  }
  napi_value out;
  napi_get_undefined(env, &out);
  return out;
}

static napi_value VncSetSshTunnel(napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) {
    napi_throw_error(env, nullptr, "client state is not initialized");
    return nullptr;
  }
  if (argc < 1) {
    napi_throw_error(env, nullptr, "ssh config is required");
    return nullptr;
  }

  PendingSshConfig config;
  if (!ParseSshTunnelConfig(env, argv[0], &config)) {
    napi_throw_error(env, nullptr, "invalid ssh config");
    return nullptr;
  }

  {
    std::lock_guard<std::mutex> lock(st_ptr->mu);
    st_ptr->pendingSshConfig = config;
  }

  int rc = 0;
  {
    std::lock_guard<std::mutex> clientLock(st_ptr->clientMu);
    if (st_ptr->client)
      rc = ApplySshTunnelConfig(st_ptr->client, config);
  }
  napi_value out;
  napi_create_int32(env, rc, &out);
  return out;
}

static napi_value VncClearSshTunnel(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (st_ptr) {
    {
      std::lock_guard<std::mutex> lock(st_ptr->mu);
      st_ptr->pendingSshConfig.reset();
    }
    std::lock_guard<std::mutex> clientLock(st_ptr->clientMu);
    if (st_ptr->client)
      vncclient_clear_ssh_tunnel(st_ptr->client);
  }
  napi_value out;
  napi_get_undefined(env, &out);
  return out;
}

static napi_value VncProcess(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;

  // While the pump owns the socket there is nothing to drain here; report its
  // status so the caller's error handling still fires if the session died.
  if (st.pumpActive.load(std::memory_order_acquire)) {
    napi_value out;
    napi_create_int32(env, 0, &out);
    return out;
  }

  std::lock_guard<std::mutex> clientLock(st.clientMu);
  int rc = -1;
  try {
    if (st.client) rc = vncclient_process(st.client);
    {
      std::lock_guard<std::mutex> lock(st.mu);
      st.processCount++;
      st.lastProcessRc = rc;
      if (st.debugEnabled && st.debugLevel >= 2) {
        AppendDebugLogLocked(st, "process #%llu rc=%d",
                             static_cast<unsigned long long>(st.processCount),
                             rc);
      }
    }
  } catch (...) {
    rc = -999;
  }
  napi_value out;
  napi_create_int32(env, rc, &out);
  return out;
}

static napi_value VncRefresh(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  int rc = -1;
  try {
    if (st.client) rc = vncclient_refresh(st.client);
  } catch (...) {
    rc = -999;
  }
  napi_value out;
  napi_create_int32(env, rc, &out);
  return out;
}

static napi_value VncRequestUpdate(napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  bool incremental = true;
  if (argc >= 1)
    GetBoolArg(env, argv[0], &incremental);
  int rc = -1;
  try {
    if (st.client) rc = vncclient_request_update(st.client, incremental ? 1 : 0);
  } catch (...) {
    rc = -999;
  }
  napi_value out;
  napi_create_int32(env, rc, &out);
  return out;
}

static napi_value VncSetDesktopSize(napi_env env, napi_callback_info info)
{
  size_t argc = 2;
  napi_value argv[2];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);

  int32_t width = 0, height = 0;
  if (argc >= 1) GetInt32Arg(env, argv[0], &width);
  if (argc >= 2) GetInt32Arg(env, argv[1], &height);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;

  int rc = VNCCLIENT_DESKTOP_RESIZE_NOT_CONNECTED;
  try {
    std::lock_guard<std::mutex> clientLock(st.clientMu);
    if (st.client)
      rc = vncclient_set_desktop_size(st.client, width, height);
  } catch (...) {
    rc = VNCCLIENT_DESKTOP_RESIZE_NOT_CONNECTED;
  }

  {
    std::lock_guard<std::mutex> lock(st.mu);
    if (st.debugEnabled && st.debugLevel >= 1) {
      AppendDebugLogLocked(st, "setDesktopSize %dx%d rc=%d", width, height, rc);
    }
  }

  napi_value out;
  napi_create_int32(env, rc, &out);
  return out;
}

static napi_value VncTakeDesktopResizeFailure(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;

  bool failed = false;
  {
    std::lock_guard<std::mutex> clientLock(st.clientMu);
    if (st.client)
      failed = vncclient_take_desktop_resize_failure(st.client) != 0;
  }

  napi_value out;
  napi_get_boolean(env, failed, &out);
  return out;
}

static napi_value VncComputeDesktopSizeTarget(napi_env env, napi_callback_info info)
{
  size_t argc = 3;
  napi_value argv[3];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);

  double viewportWidth = 0.0;
  double viewportHeight = 0.0;
  double pixelRatio = 1.0;
  if (argc >= 1) GetDoubleArg(env, argv[0], &viewportWidth);
  if (argc >= 2) GetDoubleArg(env, argv[1], &viewportHeight);
  if (argc >= 3) GetDoubleArg(env, argv[2], &pixelRatio);

  int targetWidth = 0;
  int targetHeight = 0;
  const bool ok = shared::ComputeDesktopTarget(viewportWidth, viewportHeight, pixelRatio,
                                               &targetWidth, &targetHeight);

  napi_value obj;
  napi_create_object(env, &obj);
  napi_value v;
  napi_get_boolean(env, ok, &v);
  napi_set_named_property(env, obj, "ok", v);
  napi_create_int32(env, ok ? targetWidth : 0, &v);
  napi_set_named_property(env, obj, "width", v);
  napi_create_int32(env, ok ? targetHeight : 0, &v);
  napi_set_named_property(env, obj, "height", v);
  return obj;
}

static napi_value VncConsumeDamage(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;

  std::optional<DamageRect> dmg;
  {
    std::lock_guard<std::mutex> lock(st.mu);
    dmg = st.damage;
    st.damage.reset();
  }

  if (!dmg.has_value()) {
    napi_value out;
    napi_get_null(env, &out);
    return out;
  }

  napi_value obj;
  napi_create_object(env, &obj);

  napi_value v;
  napi_create_int32(env, dmg->x, &v);
  napi_set_named_property(env, obj, "x", v);
  napi_create_int32(env, dmg->y, &v);
  napi_set_named_property(env, obj, "y", v);
  napi_create_int32(env, dmg->w, &v);
  napi_set_named_property(env, obj, "w", v);
  napi_create_int32(env, dmg->h, &v);
  napi_set_named_property(env, obj, "h", v);

  return obj;
}

static napi_value VncGetFramebufferInfo(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);

  int w = 0, h = 0, stride = 0;
  int state = -1;
  const char* name = "";
  try {
    if (st.client) {
      const uint8_t* data = nullptr;
      vncclient_get_framebuffer(st.client, &w, &h, &stride, &data);
      state = vncclient_get_state(st.client);
      name = vncclient_get_name(st.client);
    }
  } catch (...) {
    w = h = stride = 0;
    state = -1;
  }

  napi_value obj;
  napi_create_object(env, &obj);
  napi_value v;
  napi_create_int32(env, w, &v);
  napi_set_named_property(env, obj, "width", v);
  napi_create_int32(env, h, &v);
  napi_set_named_property(env, obj, "height", v);
  napi_create_int32(env, stride, &v);
  napi_set_named_property(env, obj, "stride", v);
  
  napi_create_int32(env, state, &v);
  napi_set_named_property(env, obj, "state", v);

  napi_value n;
  napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &n);
  napi_set_named_property(env, obj, "name", n);

  return obj;
}

static napi_value VncCopyFrameRGBA(napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;

  int32_t byteOrder = 0;
  int32_t pixelMapFormat = 0;
  {
    std::lock_guard<std::mutex> lock(st.mu);
    byteOrder = st.byteOrder;
    pixelMapFormat = st.pixelMapFormat;
  }
  if (argc >= 1) GetInt32Arg(env, argv[0], &byteOrder);
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  return CopyFrameRectRGBA(env, st, byteOrder, pixelMapFormat, std::nullopt);
}

static napi_value VncCopyRectRGBA(napi_env env, napi_callback_info info)
{
  size_t argc = 5;
  napi_value argv[5];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;

  int32_t byteOrder = 0;
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  int32_t pixelMapFormat = 0;
  {
    std::lock_guard<std::mutex> lock(st.mu);
    byteOrder = st.byteOrder;
    pixelMapFormat = st.pixelMapFormat;
  }
  if (argc >= 1) GetInt32Arg(env, argv[0], &byteOrder);
  if (argc >= 2) GetInt32Arg(env, argv[1], &x);
  if (argc >= 3) GetInt32Arg(env, argv[2], &y);
  if (argc >= 4) GetInt32Arg(env, argv[3], &w);
  if (argc >= 5) GetInt32Arg(env, argv[4], &h);

  std::lock_guard<std::mutex> clientLock(st.clientMu);
  return CopyFrameRectRGBA(env, st, byteOrder, pixelMapFormat, DamageRect{ x, y, w, h });
}

static napi_value VncSetDebugOptions(napi_env env, napi_callback_info info)
{
  size_t argc = 4;
  napi_value argv[4];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);

  bool enabled = false;
  int32_t level = 0;
  int32_t byteOrder = 0;
  int32_t pixelMapFormat = 0;

  if (argc >= 1) napi_get_value_bool(env, argv[0], &enabled);
  if (argc >= 2) GetInt32Arg(env, argv[1], &level);
  if (argc >= 3) GetInt32Arg(env, argv[2], &byteOrder);
  if (argc >= 4) GetInt32Arg(env, argv[3], &pixelMapFormat);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  {
    std::lock_guard<std::mutex> lock(st.mu);
    st.debugEnabled = enabled;
    st.debugLevel = level;
    st.byteOrder = byteOrder;
    st.pixelMapFormat = pixelMapFormat;
    if (!enabled) {
      st.debugLog.clear();
    } else {
      AppendDebugLogLocked(st, "debug enabled level=%d byteOrder=%d pixelMapFormat=%d",
                           st.debugLevel, st.byteOrder, st.pixelMapFormat);
    }
  }

  napi_value out;
  napi_get_undefined(env, &out);
  return out;
}

static napi_value VncGetDebugInfo(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);

  int w = 0, h = 0, stride = 0;
  const uint8_t* buf = nullptr;
  if (st.client) {
    vncclient_get_framebuffer(st.client, &w, &h, &stride, &buf);
  }
  int state = st.client ? vncclient_get_state(st.client) : -1;

  uint64_t fbUpdateCount = 0;
  DamageRect lastFbUpdate{0, 0, 0, 0};
  uint64_t processCount = 0;
  int32_t lastProcessRc = 0;
  uint32_t checksum = 0;
  std::optional<DamageRect> pendingDamage;

  {
    std::lock_guard<std::mutex> lock(st.mu);
    fbUpdateCount = st.fbUpdateCount;
    lastFbUpdate = st.lastFbUpdate;
    processCount = st.processCount;
    lastProcessRc = st.lastProcessRc;
    checksum = st.lastChecksum;
    pendingDamage = st.damage;
  }

  uint8_t p00[4] = {0, 0, 0, 0};
  uint8_t pcc[4] = {0, 0, 0, 0};
  if (buf && w > 0 && h > 0 && stride >= w * 4) {
    const uint8_t* p = buf;
    p00[0] = p[0]; p00[1] = p[1]; p00[2] = p[2]; p00[3] = p[3];

    int cx = w / 2;
    int cy = h / 2;
    const uint8_t* pc = buf + static_cast<size_t>(cy) * static_cast<size_t>(stride) + static_cast<size_t>(cx) * 4u;
    pcc[0] = pc[0]; pcc[1] = pc[1]; pcc[2] = pc[2]; pcc[3] = pc[3];
  }

  napi_value obj;
  napi_create_object(env, &obj);

  napi_value v;
  napi_create_int32(env, w, &v);
  napi_set_named_property(env, obj, "width", v);
  napi_create_int32(env, h, &v);
  napi_set_named_property(env, obj, "height", v);
  napi_create_int32(env, stride, &v);
  napi_set_named_property(env, obj, "stride", v);
  napi_create_int32(env, state, &v);
  napi_set_named_property(env, obj, "state", v);

  napi_create_int64(env, static_cast<int64_t>(fbUpdateCount), &v);
  napi_set_named_property(env, obj, "fbUpdateCount", v);
  napi_create_int32(env, lastFbUpdate.x, &v);
  napi_set_named_property(env, obj, "lastUpdateX", v);
  napi_create_int32(env, lastFbUpdate.y, &v);
  napi_set_named_property(env, obj, "lastUpdateY", v);
  napi_create_int32(env, lastFbUpdate.w, &v);
  napi_set_named_property(env, obj, "lastUpdateW", v);
  napi_create_int32(env, lastFbUpdate.h, &v);
  napi_set_named_property(env, obj, "lastUpdateH", v);

  napi_create_int64(env, static_cast<int64_t>(processCount), &v);
  napi_set_named_property(env, obj, "processCount", v);
  napi_create_int32(env, lastProcessRc, &v);
  napi_set_named_property(env, obj, "lastProcessRc", v);

  napi_create_int32(env, static_cast<int32_t>(checksum), &v);
  napi_set_named_property(env, obj, "checksum", v);

  napi_value a;
  napi_create_array(env, &a);
  for (int i = 0; i < 4; i++) {
    napi_value iv;
    napi_create_int32(env, p00[i], &iv);
    napi_set_element(env, a, i, iv);
  }
  napi_set_named_property(env, obj, "p00", a);

  napi_create_array(env, &a);
  for (int i = 0; i < 4; i++) {
    napi_value iv;
    napi_create_int32(env, pcc[i], &iv);
    napi_set_element(env, a, i, iv);
  }
  napi_set_named_property(env, obj, "pCenter", a);

  if (pendingDamage.has_value()) {
    napi_value d;
    napi_create_object(env, &d);
    napi_create_int32(env, pendingDamage->x, &v);
    napi_set_named_property(env, d, "x", v);
    napi_create_int32(env, pendingDamage->y, &v);
    napi_set_named_property(env, d, "y", v);
    napi_create_int32(env, pendingDamage->w, &v);
    napi_set_named_property(env, d, "w", v);
    napi_create_int32(env, pendingDamage->h, &v);
    napi_set_named_property(env, d, "h", v);
    napi_set_named_property(env, obj, "pendingDamage", d);
  }

  return obj;
}

static napi_value VncGetDebugLog(napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);

  bool clear = false;
  if (argc >= 1) napi_get_value_bool(env, argv[0], &clear);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::string outStr;
  {
    std::lock_guard<std::mutex> lock(st.mu);
    outStr = st.debugLog;
    if (clear)
      st.debugLog.clear();
  }
  return MakeString(env, outStr);
}

static napi_value VncSendPointer(napi_env env, napi_callback_info info)
{
  size_t argc = 3;
  napi_value argv[3];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);

  int32_t x = 0, y = 0, mask = 0;
  if (argc >= 1) GetInt32Arg(env, argv[0], &x);
  if (argc >= 2) GetInt32Arg(env, argv[1], &y);
  if (argc >= 3) GetInt32Arg(env, argv[2], &mask);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  int rc = -1;
  if (st.client)
    rc = vncclient_send_pointer(st.client, x, y, mask);
  {
    std::lock_guard<std::mutex> lock(st.mu);
    if (st.debugEnabled && st.debugLevel >= 1) {
      AppendDebugLogLocked(st, "sendPointer x=%d y=%d mask=%d rc=%d", x, y, mask, rc);
    }
  }

  napi_value out;
  napi_get_undefined(env, &out);
  return out;
}

static napi_value VncSendKey(napi_env env, napi_callback_info info)
{
  size_t argc = 2;
  napi_value argv[2];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);

  int32_t keysym = 0;
  bool down = false;
  if (argc >= 1) GetInt32Arg(env, argv[0], &keysym);
  if (argc >= 2) napi_get_value_bool(env, argv[1], &down);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  int rc = -1;
  if (st.client) {
    if (down)
      rc = vncclient_send_key_press(st.client, keysym, 0, static_cast<uint32_t>(keysym));
    else
      rc = vncclient_send_key_release(st.client, keysym);
    {
      std::lock_guard<std::mutex> lock(st.mu);
      if (st.debugEnabled && st.debugLevel >= 1) {
        AppendDebugLogLocked(st, "sendKey down=%d keysym=0x%x rc=%d", down ? 1 : 0,
                             static_cast<unsigned>(keysym), rc);
      }
    }
  }

  napi_value out;
  napi_get_undefined(env, &out);
  return out;
}

static napi_value VncSetClipboard(napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);

  std::string text;
  if (argc >= 1) GetStringArg(env, argv[0], &text);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  if (st.client) {
    vncclient_announce_clipboard(st.client, 1);
    vncclient_send_clipboard(st.client, text.c_str());
  }

  napi_value out;
  napi_get_undefined(env, &out);
  return out;
}

static napi_value VncRequestClipboard(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  if (st.client) {
    vncclient_request_clipboard(st.client);
  }

  napi_value out;
  napi_get_undefined(env, &out);
  return out;
}

static napi_value VncTakeRemoteClipboardAnnounce(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);

  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;

  int32_t announce = -1;
  {
    std::lock_guard<std::mutex> lock(st.mu);
    announce = st.remoteClipboardAnnounce;
    st.remoteClipboardAnnounce = -1;
  }

  napi_value out;
  napi_create_int32(env, announce, &out);
  return out;
}

static napi_value VncTakeRemoteClipboard(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::string text;
  {
    std::lock_guard<std::mutex> lock(st.mu);
    if (st.remoteClipboardDirty) {
      text = std::move(st.remoteClipboardUtf8);
      st.remoteClipboardUtf8.clear();
      st.remoteClipboardDirty = false;
    }
  }
  return MakeString(env, text);
}

static napi_value VncHasRemoteClipboard(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  bool hasRemoteClipboard = false;
  {
    std::lock_guard<std::mutex> lock(st.mu);
    hasRemoteClipboard = st.remoteClipboardDirty;
  }

  napi_value out;
  napi_get_boolean(env, hasRemoteClipboard, &out);
  return out;
}

static napi_value VncGetLastError(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  const char* err = st.client ? vncclient_last_error(st.client) : "not connected";
  return MakeString(env, err ? std::string(err) : std::string());
}

static napi_value VncGetSecurityLevel(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  int level = st.client ? vncclient_get_security_level(st.client) : 0;
  napi_value out;
  napi_create_int32(env, level, &out);
  return out;
}

static napi_value VncHasReceivedFirstUpdate(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  bool has_received = st.client ? (vncclient_has_received_first_update(st.client) != 0) : false;
  napi_value out;
  napi_get_boolean(env, has_received, &out);
  return out;
}

static napi_value VncIsSecure(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);
  bool is_secure = st.client ? (vncclient_is_secure(st.client) != 0) : false;
  napi_value out;
  napi_get_boolean(env, is_secure, &out);
  return out;
}


static napi_value VncDetectMonitors(napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value argv[1];
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, &argc, argv, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  std::lock_guard<std::mutex> clientLock(st.clientMu);

  std::vector<MonitorRect> fallback;
  if (argc >= 1) {
    bool is_array = false;
    napi_is_array(env, argv[0], &is_array);
    if (is_array) {
      uint32_t len = 0;
      napi_get_array_length(env, argv[0], &len);
      for (uint32_t i = 0; i < len; i++) {
        napi_value obj;
        napi_get_element(env, argv[0], i, &obj);
        int32_t x = 0, y = 0, w = 0, h = 0;
        napi_value prop;
        if (napi_get_named_property(env, obj, "x", &prop) == napi_ok) napi_get_value_int32(env, prop, &x);
        if (napi_get_named_property(env, obj, "y", &prop) == napi_ok) napi_get_value_int32(env, prop, &y);
        if (napi_get_named_property(env, obj, "w", &prop) == napi_ok) napi_get_value_int32(env, prop, &w);
        if (napi_get_named_property(env, obj, "h", &prop) == napi_ok) napi_get_value_int32(env, prop, &h);
        fallback.push_back({x, y, w, h});
      }
    }
  }

  int w = 0, h = 0, stride = 0;
  const uint8_t* buf = nullptr;
  if (st.client) {
    vncclient_get_framebuffer(st.client, &w, &h, &stride, &buf);
  }

  std::vector<MonitorRect> rects;
  if (buf && w > 0 && h > 0) {
    // Copy to contiguous RGBA if stride != w * 4
    std::vector<uint8_t> rgba;
    if (stride == w * 4) {
      rects = MonitorSegmentation::detectMonitorRectsFromRgbaFrame(w, h, buf, fallback);
    } else {
      rgba.resize(w * h * 4);
      for (int y = 0; y < h; y++) {
        memcpy(rgba.data() + y * w * 4, buf + y * stride, w * 4);
      }
      rects = MonitorSegmentation::detectMonitorRectsFromRgbaFrame(w, h, rgba.data(), fallback);
    }
  }

  napi_value arr;
  napi_create_array_with_length(env, rects.size(), &arr);
  for (size_t i = 0; i < rects.size(); i++) {
    napi_value obj;
    napi_create_object(env, &obj);
    napi_value v;
    napi_create_int32(env, rects[i].x, &v);
    napi_set_named_property(env, obj, "x", v);
    napi_create_int32(env, rects[i].y, &v);
    napi_set_named_property(env, obj, "y", v);
    napi_create_int32(env, rects[i].w, &v);
    napi_set_named_property(env, obj, "w", v);
    napi_create_int32(env, rects[i].h, &v);
    napi_set_named_property(env, obj, "h", v);
    napi_set_element(env, arr, i, obj);
  }
  return arr;
}

static napi_value VncIsServerLikelyMac(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;

  std::lock_guard<std::mutex> clientLock(st_ptr->clientMu);
  if (!st_ptr->client) {
    napi_value out;
    napi_get_boolean(env, false, &out);
    return out;
  }

  int result = vncclient_is_server_likely_mac(st_ptr->client);
  napi_value out;
  napi_get_boolean(env, result != 0, &out);
  return out;
}

static napi_value VncClient_New(napi_env env, napi_callback_info info) {
  napi_value target;
  napi_get_new_target(env, info, &target);
  if (target != nullptr) {
    auto* st = new ClientState();
    napi_value jsthis = nullptr;
    napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
    napi_wrap(env, jsthis, st, [](napi_env env, void* nativeObject, void*) {
      auto* st = static_cast<ClientState*>(nativeObject);
      // The pump must be joined before the handle goes away, and it cannot be
      // joined while holding clientMu.
      StopPump(st);
      {
        std::lock_guard<std::mutex> clientLock(st->clientMu);
        if (st->client) {
          // Drops this state's reference. An in-flight connect keeps its own,
          // so the handle survives until that worker finishes.
          vncclient_handle* previous = st->client;
          st->client = nullptr;
          st->clientGeneration++;
          vncclient_destroy(previous);
        }
      }
      delete st;
    }, nullptr, nullptr);
    return jsthis;
  }
  return nullptr;
}

static napi_value Init(napi_env env, napi_value exports)
{
  napi_property_descriptor props[] = {
    { "connect", 0, VncConnect, 0, 0, 0, napi_default, 0 },
    { "setSshTunnel", 0, VncSetSshTunnel, 0, 0, 0, napi_default, 0 },
    { "clearSshTunnel", 0, VncClearSshTunnel, 0, 0, 0, napi_default, 0 },
    { "disconnect", 0, VncDisconnect, 0, 0, 0, napi_default, 0 },
    { "process", 0, VncProcess, 0, 0, 0, napi_default, 0 },
    { "refresh", 0, VncRefresh, 0, 0, 0, napi_default, 0 },
    { "requestUpdate", 0, VncRequestUpdate, 0, 0, 0, napi_default, 0 },
    { "setDesktopSize", 0, VncSetDesktopSize, 0, 0, 0, napi_default, 0 },
    { "takeDesktopResizeFailure", 0, VncTakeDesktopResizeFailure, 0, 0, 0, napi_default, 0 },
    { "computeDesktopSizeTarget", 0, VncComputeDesktopSizeTarget, 0, 0, 0, napi_default, 0 },
    { "consumeDamage", 0, VncConsumeDamage, 0, 0, 0, napi_default, 0 },
    { "getFramebufferInfo", 0, VncGetFramebufferInfo, 0, 0, 0, napi_default, 0 },
    { "copyFrameRGBA", 0, VncCopyFrameRGBA, 0, 0, 0, napi_default, 0 },
    { "copyRectRGBA", 0, VncCopyRectRGBA, 0, 0, 0, napi_default, 0 },
    { "setDebugOptions", 0, VncSetDebugOptions, 0, 0, 0, napi_default, 0 },
    { "getDebugInfo", 0, VncGetDebugInfo, 0, 0, 0, napi_default, 0 },
    { "getDebugLog", 0, VncGetDebugLog, 0, 0, 0, napi_default, 0 },
    { "sendPointer", 0, VncSendPointer, 0, 0, 0, napi_default, 0 },
    { "sendKey", 0, VncSendKey, 0, 0, 0, napi_default, 0 },
    { "setClipboardText", 0, VncSetClipboard, 0, 0, 0, napi_default, 0 },
    { "requestClipboard", 0, VncRequestClipboard, 0, 0, 0, napi_default, 0 },
    { "takeRemoteClipboardAnnounce", 0, VncTakeRemoteClipboardAnnounce, 0, 0, 0, napi_default, 0 },
    { "takeRemoteClipboardText", 0, VncTakeRemoteClipboard, 0, 0, 0, napi_default, 0 },
    { "hasRemoteClipboardText", 0, VncHasRemoteClipboard, 0, 0, 0, napi_default, 0 },
    { "getLastError", 0, VncGetLastError, 0, 0, 0, napi_default, 0 },
    { "isSecure", 0, VncIsSecure, 0, 0, 0, napi_default, 0 },
    { "getSecurityLevel", 0, VncGetSecurityLevel, 0, 0, 0, napi_default, 0 },
    { "hasReceivedFirstUpdate", 0, VncHasReceivedFirstUpdate, 0, 0, 0, napi_default, 0 },
    { "detectMonitors", 0, VncDetectMonitors, 0, 0, 0, napi_default, 0 },
    { "isServerLikelyMac", 0, VncIsServerLikelyMac, 0, 0, 0, napi_default, 0 }
  };
  
  napi_value cons;
  napi_define_class(env, "VncClient", NAPI_AUTO_LENGTH, VncClient_New, nullptr,
                    sizeof(props) / sizeof(props[0]), props, &cons);
  napi_set_named_property(env, exports, "VncClient", cons);
  return exports;
}

static napi_module g_module = {
  .nm_version = 1,
  .nm_flags = 0,
  .nm_filename = nullptr,
  .nm_register_func = Init,
  .nm_modname = "vncviewer",
  .nm_priv = nullptr,
  .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterModule()
{
  napi_module_register(&g_module);
}

}
