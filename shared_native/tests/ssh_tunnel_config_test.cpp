// Tests for the SSH tunnel configuration rules. These decide whether the app
// accepts a tunnel setup before any socket is opened, so a wrong answer either
// blocks a valid connection or lets an impossible one through.

#include "ssh_tunnel.h"

#include <string>

#include "test_support.h"

namespace {

shared::SshTunnelConfig ValidConfig()
{
  shared::SshTunnelConfig c;
  c.enabled = true;
  c.sshHost = "bastion.example.com";
  c.sshPort = 22;
  c.sshUser = "alice";
  c.authType = shared::SshTunnelAuthType::kPassword;
  c.sshPassword = "secret";
  c.remoteHost = "10.0.0.5";
  c.remotePort = 5900;
  return c;
}

void CaseDisabledConfigSkipsValidation()
{
  testing::BeginCase("a disabled tunnel needs no fields");

  shared::SshTunnelConfig c;
  std::string error;
  CHECK(c.Validate(&error));
  CHECK(error.empty());
  CHECK(!c.IsEnabled());
}

void CaseValidConfigAccepted()
{
  testing::BeginCase("a complete password tunnel is accepted");

  std::string error;
  CHECK(ValidConfig().Validate(&error));
  CHECK(error.empty());
}

void CaseRequiredFieldsRejected()
{
  testing::BeginCase("each required field is enforced");

  struct Case {
    const char* label;
    void (*mutate)(shared::SshTunnelConfig&);
  };

  const Case cases[] = {
    {"ssh host", [](shared::SshTunnelConfig& c) { c.sshHost.clear(); }},
    {"ssh port low", [](shared::SshTunnelConfig& c) { c.sshPort = 0; }},
    {"ssh port high", [](shared::SshTunnelConfig& c) { c.sshPort = 65536; }},
    {"ssh user", [](shared::SshTunnelConfig& c) { c.sshUser.clear(); }},
    {"remote host", [](shared::SshTunnelConfig& c) { c.remoteHost.clear(); }},
    {"remote port low", [](shared::SshTunnelConfig& c) { c.remotePort = 0; }},
    {"remote port high", [](shared::SshTunnelConfig& c) { c.remotePort = 70000; }},
    {"password", [](shared::SshTunnelConfig& c) { c.sshPassword.clear(); }},
    {"private key", [](shared::SshTunnelConfig& c) {
       c.authType = shared::SshTunnelAuthType::kPublicKey;
       c.privateKeyPath.clear();
     }},
    {"invalid auth type", [](shared::SshTunnelConfig& c) {
       c.authType = static_cast<shared::SshTunnelAuthType>(99);
     }},
  };

  for (const auto& tc : cases) {
    shared::SshTunnelConfig c = ValidConfig();
    tc.mutate(c);
    std::string error;
    if (c.Validate(&error)) {
      testing::ReportFailure(__FILE__, __LINE__, std::string("accepted config with bad ") + tc.label);
      continue;
    }
    if (error.empty()) {
      testing::ReportFailure(__FILE__, __LINE__, std::string("no error text for bad ") + tc.label);
    }
  }
}

void CasePublicKeyAndNoneAuth()
{
  testing::BeginCase("public key and password-less auth rules");

  shared::SshTunnelConfig pk = ValidConfig();
  pk.authType = shared::SshTunnelAuthType::kPublicKey;
  pk.privateKeyPath = "/data/storage/el2/base/files/id_ed25519";
  pk.sshPassword.clear();
  std::string error;
  CHECK(pk.Validate(&error));

  shared::SshTunnelConfig none = ValidConfig();
  none.authType = shared::SshTunnelAuthType::kNone;
  none.sshPassword.clear();
  CHECK(none.Validate(&error));
}

void CaseNormalizeFillsDefaults()
{
  testing::BeginCase("normalize fills remote host, remote port and ssh port");

  shared::SshTunnelConfig c = ValidConfig();
  c.remoteHost.clear();
  c.remotePort = 0;
  c.sshPort = 0;

  const shared::SshTunnelConfig out =
    shared::NormalizeSshTunnelConfig(c, "192.168.1.10", 5900);

  CHECK_STR_EQ(out.remoteHost, "192.168.1.10");
  CHECK_EQ(out.remotePort, 5900);
  CHECK_EQ(out.sshPort, 22);
  // Normalizing must not invent a validated config: it still has to pass.
  std::string error;
  CHECK(out.Validate(&error));
}

void CaseNormalizeKeepsExplicitValues()
{
  testing::BeginCase("normalize leaves explicit values untouched");

  shared::SshTunnelConfig c = ValidConfig();
  c.remotePort = 5910;
  c.sshPort = 2222;

  const shared::SshTunnelConfig out = shared::NormalizeSshTunnelConfig(c, "ignored", 5999);
  CHECK_STR_EQ(out.remoteHost, "10.0.0.5");
  CHECK_EQ(out.remotePort, 5910);
  CHECK_EQ(out.sshPort, 2222);
}

void CaseNormalizeLeavesDisabledConfigAlone()
{
  testing::BeginCase("a disabled tunnel is not rewritten");

  shared::SshTunnelConfig c;
  c.enabled = false;
  c.sshPort = 0;

  const shared::SshTunnelConfig out = shared::NormalizeSshTunnelConfig(c, "192.168.1.10", 5900);
  CHECK_EQ(out.sshPort, 0);
  CHECK_STR_EQ(out.remoteHost, "");
}

void CasePortBoundaries()
{
  testing::BeginCase("port boundaries are inclusive");

  for (int port : {1, 65535}) {
    shared::SshTunnelConfig c = ValidConfig();
    c.sshPort = port;
    c.remotePort = port;
    std::string error;
    CHECK(c.Validate(&error));
  }
}

}  // namespace

int main()
{
  CaseDisabledConfigSkipsValidation();
  CaseValidConfigAccepted();
  CaseRequiredFieldsRejected();
  CasePublicKeyAndNoneAuth();
  CaseNormalizeFillsDefaults();
  CaseNormalizeKeepsExplicitValues();
  CaseNormalizeLeavesDisabledConfigAlone();
  CasePortBoundaries();
  return testing::Finish("ssh_tunnel_config");
}
