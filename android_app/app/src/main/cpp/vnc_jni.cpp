#include <algorithm>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include <android/bitmap.h>
#include <jni.h>
#include <android/log.h>

#include <vncclient.h>
#include "monitor_segmentation.h"

#define LOG_TAG "VNC_JNI"

namespace {

struct DamageRect {
  int x;
  int y;
  int w;
  int h;
};

struct ClientState {
  vncclient_handle* client = nullptr;
  std::mutex mu;
  std::mutex clientMu;
  std::optional<DamageRect> damage;
  std::string user;
  std::string password;
  std::string remoteClipboardUtf8;
  bool remoteClipboardDirty = false;

  struct KeyEvent { int keysym; bool down; };
  struct PointerEvent { int x; int y; int mask; };
  struct ClipboardEvent { std::string text; bool isRequest; };

  std::vector<KeyEvent> keyQueue;
  std::vector<PointerEvent> pointerQueue;
  std::vector<ClipboardEvent> clipboardQueue;
};

static std::string JStringToUtf8(JNIEnv* env, jstring value)
{
  if (!env || !value)
    return "";

  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (!chars)
    return "";

  std::string out(chars);
  env->ReleaseStringUTFChars(value, chars);
  return out;
}

static jstring Utf8ToJString(JNIEnv* env, const std::string& value)
{
  return env->NewStringUTF(value.c_str());
}

static ClientState* HandleToState(jlong handle)
{
  return reinterpret_cast<ClientState*>(static_cast<intptr_t>(handle));
}

static jlong StateToHandle(ClientState* state)
{
  return static_cast<jlong>(reinterpret_cast<intptr_t>(state));
}

static bool NormalizeCopyRect(int fbWidth, int fbHeight, int x, int y, int w, int h, DamageRect* out)
{
  if (!out || fbWidth <= 0 || fbHeight <= 0)
    return false;

  int nx = std::max(0, x);
  int ny = std::max(0, y);
  int rx = std::max(0, x + w);
  int by = std::max(0, y + h);

  nx = std::min(nx, fbWidth);
  ny = std::min(ny, fbHeight);
  rx = std::min(rx, fbWidth);
  by = std::min(by, fbHeight);

  int nw = rx - nx;
  int nh = by - ny;
  if (nw <= 0 || nh <= 0)
    return false;

  *out = DamageRect{nx, ny, nw, nh};
  return true;
}

static jbyteArray CopyFramebuffer(JNIEnv* env, ClientState* state, std::optional<DamageRect> rect)
{
  if (!state || !state->client)
    return nullptr;

  int width = 0;
  int height = 0;
  int stride = 0;
  const uint8_t* rgba = nullptr;
  if (vncclient_get_framebuffer(state->client, &width, &height, &stride, &rgba) != 0)
    return nullptr;
  if (width <= 0 || height <= 0 || !rgba || stride < width * 4)
    return nullptr;

  DamageRect copyRect{0, 0, width, height};
  if (rect.has_value() && !NormalizeCopyRect(width, height, rect->x, rect->y, rect->w, rect->h, &copyRect))
    return nullptr;

  const size_t size = static_cast<size_t>(copyRect.w) * static_cast<size_t>(copyRect.h) * 4u;
  std::vector<uint8_t> out(size);
  for (int row = 0; row < copyRect.h; row++) {
    const uint32_t* srcRow = reinterpret_cast<const uint32_t*>(rgba +
      static_cast<size_t>(copyRect.y + row) * static_cast<size_t>(stride) +
      static_cast<size_t>(copyRect.x) * 4u);
    uint32_t* dstRow = reinterpret_cast<uint32_t*>(out.data() + 
      static_cast<size_t>(row) * static_cast<size_t>(copyRect.w) * 4u);
    for (int col = 0; col < copyRect.w; col++) {
      dstRow[col] = srcRow[col] | 0xFF000000u;
    }
  }

  jbyteArray result = env->NewByteArray(static_cast<jsize>(out.size()));
  if (!result)
    return nullptr;
  env->SetByteArrayRegion(result, 0, static_cast<jsize>(out.size()), reinterpret_cast<const jbyte*>(out.data()));
  return result;
}

static jint BlitFramebufferToBitmap(
  JNIEnv* env, ClientState* state, jobject bitmap, std::optional<DamageRect> rect)
{
  if (!env || !state || !state->client || !bitmap)
    return -1;

  int width = 0;
  int height = 0;
  int stride = 0;
  const uint8_t* rgba = nullptr;
  if (vncclient_get_framebuffer(state->client, &width, &height, &stride, &rgba) != 0)
    return -1;
  if (width <= 0 || height <= 0 || !rgba || stride < width * 4)
    return -1;

  AndroidBitmapInfo info{};
  if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS)
    return -1;
  if (info.format != ANDROID_BITMAP_FORMAT_RGBA_8888)
    return -1;
  if (static_cast<int>(info.width) != width || static_cast<int>(info.height) != height)
    return -1;
  if (info.stride < info.width * 4u)
    return -1;

  DamageRect copyRect{0, 0, width, height};
  if (rect.has_value() && !NormalizeCopyRect(width, height, rect->x, rect->y, rect->w, rect->h, &copyRect))
    return -1;

  void* pixels = nullptr;
  if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS || !pixels)
    return -1;

  for (int row = 0; row < copyRect.h; row++) {
    const uint32_t* srcRow = reinterpret_cast<const uint32_t*>(rgba +
      static_cast<size_t>(copyRect.y + row) * static_cast<size_t>(stride) +
      static_cast<size_t>(copyRect.x) * 4u);
    uint32_t* dstRow = reinterpret_cast<uint32_t*>(static_cast<uint8_t*>(pixels) +
      static_cast<size_t>(copyRect.y + row) * static_cast<size_t>(info.stride) +
      static_cast<size_t>(copyRect.x) * 4u);
    for (int col = 0; col < copyRect.w; col++) {
      dstRow[col] = srcRow[col] | 0xFF000000u;
    }
  }

  AndroidBitmap_unlockPixels(env, bitmap);
  return 0;
}

static int cb_get_user_passwd(void* user, int, char* user_buf, size_t user_len, char* pass_buf, size_t pass_len)
{
  auto* state = static_cast<ClientState*>(user);
  if (!state)
    return 0;

  std::lock_guard<std::mutex> lock(state->mu);
  if (user_buf && user_len > 0) {
    std::strncpy(user_buf, state->user.c_str(), user_len - 1);
    user_buf[user_len - 1] = '\0';
  }
  if (!pass_buf || pass_len == 0 || state->password.empty())
    return 0;

  std::strncpy(pass_buf, state->password.c_str(), pass_len - 1);
  pass_buf[pass_len - 1] = '\0';
  return 1;
}

static int cb_show_msg_box(void*, int, const char*, const char*)
{
  return 1;
}

static void cb_on_framebuffer_resize(void*, int, int)
{
}

static void cb_on_framebuffer_update(void*, int, int, int, int)
{
}

static void cb_on_clipboard_announce(void* user, int available)
{
  auto* state = static_cast<ClientState*>(user);
  if (!state)
    return;

  std::lock_guard<std::mutex> lock(state->mu);
  if (available == 0) {
    state->remoteClipboardDirty = false;
    state->remoteClipboardUtf8.clear();
  }
}

static void cb_on_clipboard_data(void* user, const char* utf8)
{
  auto* state = static_cast<ClientState*>(user);
  if (!state)
    return;

  std::lock_guard<std::mutex> lock(state->mu);
  state->remoteClipboardUtf8 = utf8 ? utf8 : "";
  state->remoteClipboardDirty = true;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeCreate(JNIEnv*, jclass)
{
  auto* state = new ClientState();
  vncclient_callbacks callbacks{};
  callbacks.user = state;
  callbacks.get_user_passwd = cb_get_user_passwd;
  callbacks.show_msg_box = cb_show_msg_box;
  callbacks.on_framebuffer_resize = cb_on_framebuffer_resize;
  callbacks.on_framebuffer_update = cb_on_framebuffer_update;
  callbacks.on_clipboard_announce = cb_on_clipboard_announce;
  callbacks.on_clipboard_data = cb_on_clipboard_data;

  state->client = vncclient_create(&callbacks);
  return StateToHandle(state);
}

extern "C" JNIEXPORT void JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeSetStorageRoot(
  JNIEnv* env, jclass, jstring rootPath)
{
  const std::string rootValue = JStringToUtf8(env, rootPath);
  vncclient_set_storage_root(rootValue.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeDestroy(JNIEnv*, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state)
    return;

  {
    std::lock_guard<std::mutex> clientLock(state->clientMu);
    if (state->client) {
      vncclient_destroy(state->client);
      state->client = nullptr;
    }
  }
  delete state;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeConnect(
  JNIEnv* env, jclass, jlong handle, jstring host, jint port, jstring user, jstring password)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return -1;

  {
    std::lock_guard<std::mutex> lock(state->mu);
    state->user = JStringToUtf8(env, user);
    state->password = JStringToUtf8(env, password);
  }

  const std::string hostValue = JStringToUtf8(env, host);
  return static_cast<jint>(vncclient_connect(state->client, hostValue.c_str(), static_cast<int>(port)));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeSetSshTunnel(
  JNIEnv* env, jclass, jlong handle,
  jboolean enabled, jstring sshHost, jint sshPort, jstring sshUser, jint authType,
  jstring sshPassword, jstring privateKeyPath, jstring publicKeyPath,
  jstring privateKeyPassphrase, jstring knownHostsPath,
  jboolean strictHostKeyCheck, jstring remoteHost, jint remotePort)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return -1;

  const std::string sshHostValue = JStringToUtf8(env, sshHost);
  const std::string sshUserValue = JStringToUtf8(env, sshUser);
  const std::string sshPasswordValue = JStringToUtf8(env, sshPassword);
  const std::string privateKeyPathValue = JStringToUtf8(env, privateKeyPath);
  const std::string publicKeyPathValue = JStringToUtf8(env, publicKeyPath);
  const std::string privateKeyPassphraseValue = JStringToUtf8(env, privateKeyPassphrase);
  const std::string knownHostsPathValue = JStringToUtf8(env, knownHostsPath);
  const std::string remoteHostValue = JStringToUtf8(env, remoteHost);

  vncclient_ssh_config config{};
  config.enabled = enabled == JNI_TRUE ? 1 : 0;
  config.ssh_host = sshHostValue.c_str();
  config.ssh_port = static_cast<int>(sshPort);
  config.ssh_user = sshUserValue.c_str();
  config.auth_type = static_cast<int>(authType);
  config.ssh_password = sshPasswordValue.c_str();
  config.private_key_path = privateKeyPathValue.c_str();
  config.public_key_path = publicKeyPathValue.c_str();
  config.private_key_passphrase = privateKeyPassphraseValue.c_str();
  config.known_hosts_path = knownHostsPathValue.c_str();
  config.strict_host_key_check = strictHostKeyCheck == JNI_TRUE ? 1 : 0;
  config.remote_host = remoteHostValue.c_str();
  config.remote_port = static_cast<int>(remotePort);
  return static_cast<jint>(vncclient_set_ssh_tunnel(state->client, &config));
}

extern "C" JNIEXPORT void JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeClearSshTunnel(
  JNIEnv*, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (state && state->client)
    vncclient_clear_ssh_tunnel(state->client);
}

extern "C" JNIEXPORT void JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeDisconnect(JNIEnv*, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (state && state->client) {
    std::lock_guard<std::mutex> clientLock(state->clientMu);
    vncclient_disconnect(state->client);
    std::lock_guard<std::mutex> lock(state->mu);
    state->keyQueue.clear();
    state->pointerQueue.clear();
    state->clipboardQueue.clear();
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeProcess(JNIEnv*, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return -1;

  std::vector<ClientState::KeyEvent> keys;
  std::vector<ClientState::PointerEvent> pointers;
  std::vector<ClientState::ClipboardEvent> clipboards;

  {
    std::lock_guard<std::mutex> lock(state->mu);
    std::swap(keys, state->keyQueue);
    std::swap(pointers, state->pointerQueue);
    std::swap(clipboards, state->clipboardQueue);
  }

  {
    std::lock_guard<std::mutex> clientLock(state->clientMu);
    if (!state->client) return -1;

    for (const auto& ev : clipboards) {
      if (ev.isRequest) {
        vncclient_request_clipboard(state->client);
      } else {
        vncclient_announce_clipboard(state->client, 1);
        vncclient_send_clipboard(state->client, ev.text.c_str());
      }
    }

    for (const auto& ev : keys) {
      if (ev.down)
        vncclient_send_key_press(state->client, ev.keysym, 0, static_cast<uint32_t>(ev.keysym));
      else
        vncclient_send_key_release(state->client, ev.keysym);
    }

    for (const auto& ev : pointers) {
      vncclient_send_pointer(state->client, ev.x, ev.y, static_cast<uint16_t>(ev.mask));
    }
  }

  return static_cast<jint>(vncclient_process(state->client));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeRefresh(JNIEnv*, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return -1;

  return static_cast<jint>(vncclient_refresh(state->client));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeRequestUpdate(
  JNIEnv*, jclass, jlong handle, jboolean incremental)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return -1;

  return static_cast<jint>(vncclient_request_update(
    state->client,
    incremental == JNI_TRUE ? 1 : 0));
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeGetServerName(JNIEnv* env, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  const char* name = "";
  if (state && state->client) {
    name = vncclient_get_name(state->client);
  }
  return Utf8ToJString(env, name ? std::string(name) : std::string());
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeGetFramebufferInfo(JNIEnv* env, jclass, jlong handle)
{
  jint values[4] = {0, 0, 0, -1};
  auto* state = HandleToState(handle);

  if (state && state->client) {
    int width = 0;
    int height = 0;
    int stride = 0;
    const uint8_t* rgba = nullptr;
    if (vncclient_get_framebuffer(state->client, &width, &height, &stride, &rgba) == 0) {
      values[0] = width;
      values[1] = height;
      values[2] = stride;
      values[3] = vncclient_get_state(state->client);
    }
  }

  jintArray result = env->NewIntArray(4);
  env->SetIntArrayRegion(result, 0, 4, values);
  return result;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeCopyFrameRgba(JNIEnv* env, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  return CopyFramebuffer(env, state, std::nullopt);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeCopyRectRgba(
  JNIEnv* env, jclass, jlong handle, jint x, jint y, jint width, jint height)
{
  auto* state = HandleToState(handle);
  return CopyFramebuffer(
    env,
    state,
    DamageRect{
      static_cast<int>(x),
      static_cast<int>(y),
      static_cast<int>(width),
      static_cast<int>(height)
    }
  );
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeBlitFrameToBitmap(
  JNIEnv* env, jclass, jlong handle, jobject bitmap)
{
  auto* state = HandleToState(handle);
  return BlitFramebufferToBitmap(env, state, bitmap, std::nullopt);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeBlitRectToBitmap(
  JNIEnv* env, jclass, jlong handle, jint x, jint y, jint width, jint height, jobject bitmap)
{
  auto* state = HandleToState(handle);
  return BlitFramebufferToBitmap(
    env,
    state,
    bitmap,
    DamageRect{
      static_cast<int>(x),
      static_cast<int>(y),
      static_cast<int>(width),
      static_cast<int>(height)
    }
  );
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeConsumeDamage(JNIEnv* env, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return nullptr;

  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  if (vncclient_consume_damage(state->client, &x, &y, &width, &height) != 0 || width <= 0 || height <= 0)
    return nullptr;

  const jint values[4] = {
    static_cast<jint>(x),
    static_cast<jint>(y),
    static_cast<jint>(width),
    static_cast<jint>(height)
  };
  jintArray result = env->NewIntArray(4);
  if (!result)
    return nullptr;
  env->SetIntArrayRegion(result, 0, 4, values);
  return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeSendPointer(
  JNIEnv*, jclass, jlong handle, jint x, jint y, jint mask)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return;

  std::lock_guard<std::mutex> lock(state->mu);
  state->pointerQueue.push_back({static_cast<int>(x), static_cast<int>(y), static_cast<int>(mask)});
}

extern "C" JNIEXPORT void JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeSendKey(
  JNIEnv*, jclass, jlong handle, jint keysym, jboolean down)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return;

  std::lock_guard<std::mutex> lock(state->mu);
  state->keyQueue.push_back({static_cast<int>(keysym), down != 0});
}

extern "C" JNIEXPORT void JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeSetClipboardText(
  JNIEnv* env, jclass, jlong handle, jstring text)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return;

  const std::string value = JStringToUtf8(env, text);
  std::lock_guard<std::mutex> lock(state->mu);
  state->clipboardQueue.push_back({value, false});
}

extern "C" JNIEXPORT void JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeRequestClipboard(JNIEnv*, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return;

  std::lock_guard<std::mutex> lock(state->mu);
  state->clipboardQueue.push_back({"", true});
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeTakeRemoteClipboardText(JNIEnv* env, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state)
    return Utf8ToJString(env, "");

  std::string value;
  {
    std::lock_guard<std::mutex> lock(state->mu);
    value = state->remoteClipboardUtf8;
    state->remoteClipboardUtf8.clear();
    state->remoteClipboardDirty = false;
  }
  return Utf8ToJString(env, value);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeHasRemoteClipboardText(JNIEnv*, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state)
    return JNI_FALSE;

  std::lock_guard<std::mutex> lock(state->mu);
  return state->remoteClipboardDirty ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeGetLastError(JNIEnv* env, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return Utf8ToJString(env, "native client unavailable");
  return Utf8ToJString(env, vncclient_last_error(state->client));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeIsSecure(JNIEnv*, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return JNI_FALSE;
  return vncclient_is_secure(state->client) != 0 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeGetSecurityLevel(JNIEnv*, jclass, jlong handle)
{
  auto* state = HandleToState(handle);
  if (!state || !state->client)
    return 0;
  return static_cast<jint>(vncclient_get_security_level(state->client));
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_hengqutiandi_vncviewer_native_VncClient_nativeDetectMonitors(JNIEnv* env, jclass, jlong handle, jobjectArray fallbackArray) {
    auto* state = HandleToState(handle);
    if (!state) return nullptr;

    std::vector<MonitorRect> fallback;
    if (fallbackArray) {
        jsize len = env->GetArrayLength(fallbackArray);
        jclass rectClass = env->FindClass("android/graphics/Rect");
        jfieldID leftField = env->GetFieldID(rectClass, "left", "I");
        jfieldID topField = env->GetFieldID(rectClass, "top", "I");
        jfieldID rightField = env->GetFieldID(rectClass, "right", "I");
        jfieldID bottomField = env->GetFieldID(rectClass, "bottom", "I");
        
        for (jsize i = 0; i < len; i++) {
            jobject rectObj = env->GetObjectArrayElement(fallbackArray, i);
            if (rectObj) {
                int left = env->GetIntField(rectObj, leftField);
                int top = env->GetIntField(rectObj, topField);
                int right = env->GetIntField(rectObj, rightField);
                int bottom = env->GetIntField(rectObj, bottomField);
                fallback.push_back({left, top, right - left, bottom - top});
                env->DeleteLocalRef(rectObj);
            }
        }
        env->DeleteLocalRef(rectClass);
    }

    int w = 0, h = 0, stride = 0;
    const uint8_t* buf = nullptr;
    if (state->client) {
        vncclient_get_framebuffer(state->client, &w, &h, &stride, &buf);
    }

    std::vector<MonitorRect> rects;
    if (buf && w > 0 && h > 0) {
        std::vector<uint8_t> rgba;
        if (stride == w * 4) {
            rects = MonitorSegmentation::detectMonitorRectsFromRgbaFrame(w, h, buf, fallback);
        } else {
            rgba.resize(w * h * 4);
            for (int y = 0; y < h; y++) {
                std::memcpy(rgba.data() + y * w * 4, buf + y * stride, w * 4);
            }
            rects = MonitorSegmentation::detectMonitorRectsFromRgbaFrame(w, h, rgba.data(), fallback);
        }
    }

    jclass rectClass = env->FindClass("android/graphics/Rect");
    jmethodID rectInit = env->GetMethodID(rectClass, "<init>", "(IIII)V");
    jobjectArray array = env->NewObjectArray(rects.size(), rectClass, nullptr);
    for (size_t i = 0; i < rects.size(); i++) {
        jobject rectObj = env->NewObject(rectClass, rectInit, 
            rects[i].x, rects[i].y, rects[i].x + rects[i].w, rects[i].y + rects[i].h);
        env->SetObjectArrayElement(array, i, rectObj);
        env->DeleteLocalRef(rectObj);
    }
    env->DeleteLocalRef(rectClass);
    return array;
}

} 
