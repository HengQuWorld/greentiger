#include <algorithm>
#include <cstdarg>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>

#include <napi/native_api.h>

#include "vncclient.h"
#include "monitor_segmentation.h"
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
  vncclient_handle* client = nullptr;

  std::mutex mu;
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

    for (int y = 0; y < copyRect.h; y++) {
      const size_t srcY = static_cast<size_t>(copyRect.y + y) * srcStride;
      const size_t srcX = static_cast<size_t>(copyRect.x) * 4u;
      const uint8_t* srcRow = rgba + srcY + srcX;
      uint8_t* dstRow = dst + static_cast<size_t>(y) * dstStride;

      for (int x = 0; x < copyRect.w; x++) {
        const uint8_t* sp = srcRow + static_cast<size_t>(x) * 4u;
        uint8_t* dp = dstRow + static_cast<size_t>(x) * 4u;

        uint8_t r;
        uint8_t g;
        uint8_t b;
        if (byteOrder == 0) {
          r = sp[0];
          g = sp[1];
          b = sp[2];
        } else if (byteOrder == 1) {
          b = sp[0];
          g = sp[1];
          r = sp[2];
        } else if (byteOrder == 2) {
          r = sp[1];
          g = sp[2];
          b = sp[3];
        } else {
          b = sp[1];
          g = sp[2];
          r = sp[3];
        }

        if (!wantBGRA) {
          dp[0] = r;
          dp[1] = g;
          dp[2] = b;
          dp[3] = 255;
        } else {
          dp[0] = b;
          dp[1] = g;
          dp[2] = r;
          dp[3] = 255;
        }
      }
    }
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

  if (st.client) {
    vncclient_disconnect(st.client);
    vncclient_destroy(st.client);
    st.client = nullptr;
  }

  vncclient_callbacks cbs{};
  cbs.user = &st;
  cbs.get_user_passwd = cb_get_user_passwd;
  cbs.show_msg_box = cb_show_msg_box;
  cbs.on_framebuffer_update = cb_on_framebuffer_update;
  cbs.on_clipboard_announce = cb_on_clipboard_announce;
  cbs.on_clipboard_data = cb_on_clipboard_data;

  st.client = vncclient_create(&cbs);
  if (!st.client) {
    napi_throw_error(env, nullptr, "failed to create client");
    return nullptr;
  }

  {
    std::lock_guard<std::mutex> lock(st.mu);
    st.user = std::move(user);
    st.password = std::move(pass);
    st.damage.reset();
    st.remoteClipboardAnnounce = -1;
    st.remoteClipboardDirty = false;
    st.remoteClipboardUtf8.clear();
  }

  if (st.pendingSshConfig.has_value()) {
    int sshRc = ApplySshTunnelConfig(st.client, *st.pendingSshConfig);
    if (sshRc != 0) {
      napi_value out;
      napi_create_int32(env, sshRc, &out);
      return out;
    }
  }

  int rc = vncclient_connect(st.client, addr.c_str(), basePort);
  if (rc == 0 && st.client) {
    vncclient_announce_clipboard(st.client, 1);
    std::lock_guard<std::mutex> lock(st.mu);
    if (st.debugEnabled && st.debugLevel >= 1) {
      AppendDebugLogLocked(st, "clipboard initialized announce=1");
    }
  }
  napi_value out;
  napi_create_int32(env, rc, &out);
  return out;
}

static napi_value VncDisconnect(napi_env env, napi_callback_info info)
{
  napi_value jsthis = nullptr;
  napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
  ClientState* st_ptr = nullptr;
  napi_unwrap(env, jsthis, reinterpret_cast<void**>(&st_ptr));
  if (!st_ptr) return nullptr;
  auto& st = *st_ptr;
  if (st.client) {
    vncclient_disconnect(st.client);
    vncclient_destroy(st.client);
    st.client = nullptr;
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
  if (st_ptr->client)
    rc = ApplySshTunnelConfig(st_ptr->client, config);
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
  int level = st.client ? vncclient_get_security_level(st.client) : 0;
  napi_value out;
  napi_create_int32(env, level, &out);
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

static napi_value VncClient_New(napi_env env, napi_callback_info info) {
  napi_value target;
  napi_get_new_target(env, info, &target);
  if (target != nullptr) {
    auto* st = new ClientState();
    napi_value jsthis = nullptr;
    napi_get_cb_info(env, info, nullptr, nullptr, &jsthis, nullptr);
    napi_wrap(env, jsthis, st, [](napi_env env, void* nativeObject, void*) {
      auto* st = static_cast<ClientState*>(nativeObject);
      if (st->client) {
        vncclient_destroy(st->client);
        st->client = nullptr;
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
    { "detectMonitors", 0, VncDetectMonitors, 0, 0, 0, napi_default, 0 }
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
