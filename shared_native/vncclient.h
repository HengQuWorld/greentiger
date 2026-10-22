#ifndef __SHARED_VNCCLIENT_H__
#define __SHARED_VNCCLIENT_H__

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vncclient_handle vncclient_handle;

typedef struct vncclient_callbacks {
  void* user;

  int (*get_user_passwd)(void* user, int secure,
                         char* user_buf, size_t user_len,
                         char* pass_buf, size_t pass_len);
  int (*show_msg_box)(void* user, int flags,
                      const char* title, const char* text);

  void (*on_framebuffer_resize)(void* user, int width, int height);
  void (*on_framebuffer_update)(void* user, int x, int y, int w, int h);

  void (*on_clipboard_announce)(void* user, int available);
  void (*on_clipboard_data)(void* user, const char* utf8);

  void (*on_cursor)(void* user, int width, int height,
                    int hotspot_x, int hotspot_y,
                    const uint8_t* rgba, int rgba_len);
} vncclient_callbacks;

// Result of vncclient_set_desktop_size(). Positive values are not failures.
typedef enum vncclient_desktop_resize_result {
  VNCCLIENT_DESKTOP_RESIZE_OK = 0,
  // The server already reports the requested size; nothing was sent.
  VNCCLIENT_DESKTOP_RESIZE_UNCHANGED = 1,
  VNCCLIENT_DESKTOP_RESIZE_NOT_CONNECTED = -1,
  VNCCLIENT_DESKTOP_RESIZE_INVALID_SIZE = -2,
  // The server never advertised ExtendedDesktopSize support.
  VNCCLIENT_DESKTOP_RESIZE_UNSUPPORTED = -3,
  // The server reports more than one screen; the layout is left untouched.
  VNCCLIENT_DESKTOP_RESIZE_MULTI_SCREEN = -4,
} vncclient_desktop_resize_result;

typedef enum vncclient_ssh_auth_type {
  VNCCLIENT_SSH_AUTH_NONE = 0,
  VNCCLIENT_SSH_AUTH_PASSWORD = 1,
  VNCCLIENT_SSH_AUTH_PUBLIC_KEY = 2,
} vncclient_ssh_auth_type;

typedef struct vncclient_ssh_config {
  int enabled;
  const char* ssh_host;
  int ssh_port;
  const char* ssh_user;
  int auth_type;
  const char* ssh_password;
  const char* private_key_path;
  const char* public_key_path;
  const char* private_key_passphrase;
  const char* known_hosts_path;
  int strict_host_key_check;
  const char* remote_host;
  int remote_port;
} vncclient_ssh_config;

vncclient_handle* vncclient_create(const vncclient_callbacks* callbacks);

// Drops the reference taken by vncclient_create. The handle is torn down and
// freed by whichever release brings the count to zero, so an in-flight
// asynchronous connect holds the handle alive until it finishes.
void vncclient_destroy(vncclient_handle* client);

// Takes an additional reference. Every caller that keeps a handle across a
// thread hop must acquire one and release it when done; this is what makes it
// safe to disconnect or drop the owning object while work is still running.
void vncclient_acquire(vncclient_handle* client);

// Drops a reference previously taken with vncclient_acquire.
void vncclient_release(vncclient_handle* client);

void vncclient_set_storage_root(const char* root_path);
int vncclient_set_ssh_tunnel(vncclient_handle* client, const vncclient_ssh_config* config);
void vncclient_clear_ssh_tunnel(vncclient_handle* client);

int vncclient_connect(vncclient_handle* client, const char* host_port, int base_port);
int vncclient_disconnect(vncclient_handle* client);
int vncclient_is_connected(vncclient_handle* client);
int vncclient_get_fd(vncclient_handle* client);
int vncclient_get_state(vncclient_handle* client);
int vncclient_is_secure(vncclient_handle* client);
int vncclient_get_security_level(vncclient_handle* client);
int vncclient_has_received_first_update(vncclient_handle* client);
const char* vncclient_get_name(vncclient_handle* client);

int vncclient_process(vncclient_handle* client);
int vncclient_refresh(vncclient_handle* client);
int vncclient_request_update(vncclient_handle* client, int incremental);

// Asks the server to resize the remote desktop (RFB SetDesktopSize) so the
// picture can match the local viewport instead of being letterboxed. Only
// single-screen desktops are resized; see vncclient_desktop_resize_result for
// the returned codes. The request is asynchronous: the new size arrives as a
// regular framebuffer resize on a later vncclient_process().
int vncclient_set_desktop_size(vncclient_handle* client, int width, int height);

// Reports once whether a client-requested resize was refused by the server.
// Returns 1 the first call after a refusal, 0 otherwise.
int vncclient_take_desktop_resize_failure(vncclient_handle* client);

int vncclient_get_framebuffer(vncclient_handle* client,
                              int* width, int* height,
                              int* stride_bytes,
                              const uint8_t** rgba);
int vncclient_consume_damage(vncclient_handle* client,
                             int* x, int* y, int* w, int* h);

int vncclient_send_pointer(vncclient_handle* client,
                           int x, int y, uint16_t button_mask);

int vncclient_send_key_press(vncclient_handle* client,
                             int system_key_code,
                             uint32_t key_code, uint32_t key_sym);
int vncclient_send_key_release(vncclient_handle* client,
                               int system_key_code);
int vncclient_release_all_keys(vncclient_handle* client);

int vncclient_request_clipboard(vncclient_handle* client);
int vncclient_announce_clipboard(vncclient_handle* client, int available);
int vncclient_send_clipboard(vncclient_handle* client, const char* utf8);

int vncclient_is_server_likely_mac(vncclient_handle* client);

const char* vncclient_last_error(vncclient_handle* client);

#ifdef __cplusplus
}
#endif

#endif
