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
void vncclient_destroy(vncclient_handle* client);

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
const char* vncclient_get_name(vncclient_handle* client);

int vncclient_process(vncclient_handle* client);
int vncclient_refresh(vncclient_handle* client);
int vncclient_request_update(vncclient_handle* client, int incremental);

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

const char* vncclient_last_error(vncclient_handle* client);

#ifdef __cplusplus
}
#endif

#endif
