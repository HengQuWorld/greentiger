#ifndef __SHARED_SSH_TUNNEL_H__
#define __SHARED_SSH_TUNNEL_H__

#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace shared {

enum class SshTunnelAuthType {
  kNone = 0,
  kPassword = 1,
  kPublicKey = 2,
};

struct SshTunnelConfig {
  bool enabled = false;
  std::string sshHost;
  int sshPort = 22;
  std::string sshUser;
  SshTunnelAuthType authType = SshTunnelAuthType::kPassword;
  std::string sshPassword;
  std::string privateKeyPath;
  std::string publicKeyPath;
  std::string privateKeyPassphrase;
  std::string knownHostsPath;
  bool strictHostKeyCheck = false;
  std::string remoteHost;
  int remotePort = 0;

  bool IsEnabled() const;
  bool Validate(std::string* error) const;
};

class SshTunnel final {
public:
  static std::unique_ptr<SshTunnel> Open(const SshTunnelConfig& config,
                                         std::string* error);

  ~SshTunnel();

  int localPort() const { return localPort_; }
  bool WaitUntilReady(int timeoutMs, std::string* error);
  void Shutdown();

private:
  explicit SshTunnel(SshTunnelConfig config);

  SshTunnel(const SshTunnel&) = delete;
  SshTunnel& operator=(const SshTunnel&) = delete;

  bool ConnectSession(std::string* error);
  bool CreateListener(std::string* error);
  void WorkerMain();
  bool OpenForwardChannel(std::string* error);
  bool Pump(std::string* error);

  void SetReady();
  void SetFailed(const std::string& error);
  void CloseClientSocket();
  void CloseListenerSocket();
  void CloseChannel();
  void CloseSession();

  SshTunnelConfig config_;
  int sshSocket_ = -1;
  int listenSocket_ = -1;
  int clientSocket_ = -1;
  int localPort_ = 0;
  void* session_ = nullptr;
  void* channel_ = nullptr;
  mutable std::mutex mutex_;
  std::condition_variable stateCv_;
  bool ready_ = false;
  bool failed_ = false;
  bool stopRequested_ = false;
  std::string lastError_;
  std::thread workerThread_;
};

bool EnsureSshLibraryReady(std::string* error);
SshTunnelConfig NormalizeSshTunnelConfig(const SshTunnelConfig& config,
                                         const std::string& defaultRemoteHost,
                                         int defaultRemotePort);

}  // namespace shared

#endif
