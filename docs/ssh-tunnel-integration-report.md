# SSH 隧道集成技术报告

## 1. 文档目的

本文档说明当前仓库中 SSH 隧道能力的集成范围、代码结构、平台接入方式、默认交互策略、构建方式与已完成验证，用于提交前评审、后续维护和跨端协作。

## 2. 集成目标

- 在共享原生层引入统一的 SSH 隧道实现，避免 Android 与 HarmonyOS 分别维护两套隧道逻辑。
- 支持密码登录与公钥登录两类 SSH 认证方式。
- 支持可选的 `known_hosts` 主机指纹严格校验。
- 在 UI 层将 SSH 隧道作为“按需开启”的高级能力，而不是基础连接必填项。
- 在用户首次开启 SSH 时，基于基础连接信息自动预填 SSH 参数，降低输入成本。
- 默认将隧道转发目标设为远端 `127.0.0.1`，避免默认暴露到远端非回环地址。

## 3. 代码分层

### 3.1 共享原生层

- `shared_native/ssh_tunnel.h`
- `shared_native/ssh_tunnel.cpp`
- `shared_native/vncclient.h`
- `shared_native/vncclient.cpp`
- `shared_native/CMakeLists.txt`

职责：

- 通过 `libssh2` 建立 SSH 会话。
- 在本地打开监听端口，将本地连接转发到远端目标主机与端口。
- 在 VNC 建连前接管目标地址，将原始 VNC 目标替换为本地回环监听端口。
- 统一完成 SSH 参数校验、默认值归一化、主机指纹校验和连接生命周期管理。

### 3.2 Android 接入层

- `android_app/app/src/main/java/com/hengqutiandi/vncviewer/model/ConnectionItem.kt`
- `android_app/app/src/main/java/com/hengqutiandi/vncviewer/SshConfigAdapters.kt`
- `android_app/app/src/main/java/com/hengqutiandi/vncviewer/native/VncNative.kt`
- `android_app/app/src/main/cpp/vnc_jni.cpp`
- `android_app/app/src/main/java/com/hengqutiandi/vncviewer/MainActivity.kt`

职责：

- 保存 SSH 配置的数据模型与序列化字段。
- 将 Kotlin 侧 `SshConnectionConfig` 转换为 JNI 可消费的 `SshTunnelConfig`。
- 在连接前调用 `setSshTunnel()` 下发 SSH 配置。
- 在连接编辑界面中提供 SSH 开关、认证方式、复用桌面账号密码和转发目标配置能力。

### 3.3 HarmonyOS 接入层

- `ohos_app/entry/src/main/ets/utils/ConnectionUtils.ets`
- `ohos_app/entry/src/main/cpp/napi_vnc.cpp`
- `ohos_app/entry/src/main/ets/pages/Index.ets`
- `ohos_app/entry/src/main/ets/pages/Viewer.ets`

职责：

- 定义 ArkTS 侧连接与 SSH 隧道配置结构。
- 通过 NAPI 将 ArkTS 配置转换为原生 `vncclient_ssh_config`。
- 在首页编辑弹层中提供 SSH 隧道配置入口，并与基础连接页协同工作。
- 保证新增连接默认清空内容，避免沿用上一条连接的地址和凭据。

## 4. 数据模型与字段对齐

两端都保持与共享原生层一致的核心字段：

- `enabled`
- `sshHost`
- `sshPort`
- `sshUser`
- `authType`
- `sshPassword`
- `privateKeyPath`
- `publicKeyPath`
- `privateKeyPassphrase`
- `knownHostsPath`
- `strictHostKeyCheck`
- `remoteHost`
- `remotePort`

其中：

- `authType = 1` 表示密码认证。
- `authType = 2` 表示公钥认证。
- `remoteHost` / `remotePort` 表示 SSH 服务器视角下的转发目标，不是本机直连地址。

## 5. 运行时流程

### 5.1 配置下发

1. UI 层采集基础连接信息与 SSH 高级配置。
2. 平台层将配置转换为 JNI / NAPI 对应的结构体或参数对象。
3. 平台桥接层调用共享接口 `vncclient_set_ssh_tunnel()` 保存待生效 SSH 配置。

### 5.2 建立连接

1. `vncclient_connect()` 解析原始 VNC 地址。
2. 调用 `NormalizeSshTunnelConfig()` 补齐远端目标默认值。
3. 若 SSH 已开启，则调用 `SshTunnel::Open()` 建立隧道。
4. 隧道就绪后，将 VNC 连接目标切换为本地 `127.0.0.1:<localPort>`。
5. VNC 客户端随后仅连接本地监听口，由 SSH 隧道负责继续转发到远端目标。

### 5.3 断开连接

- 平台层或共享层触发 `vncclient_disconnect()` 时，会关闭 VNC socket、释放连接对象，并销毁隧道实例。

## 6. 默认 UX 策略

本次提交采用以下默认交互策略：

- 新增连接时清空地址、账号与密码，不继承上一次输入。
- SSH 默认关闭。
- 用户在基础页填写地址、用户名和密码后，首次开启 SSH 时自动补全：
  - SSH 服务器默认取基础地址中的主机。
  - SSH 用户名默认重用桌面用户名。
  - SSH 密码默认重用桌面密码。
  - SSH 端口默认 `22`。
  - 转发目标主机默认远端 `127.0.0.1`。
  - 转发目标端口默认取基础地址中的端口，缺省为 `5900`。
- 只有在需要跳板机、堡垒机、内网转发时才开启 SSH。
- Android 与 HarmonyOS 的高级页均明确展示“转发目标”语义，避免误解为本机地址覆盖。

## 7. 安全策略

- 默认转发到远端 `127.0.0.1`，降低误连远端非回环地址的概率。
- 支持 `known_hosts` 严格校验，避免未知主机指纹被静默接受。
- 公钥登录要求提供私钥路径；密码登录要求提供 SSH 密码。
- SSH 配置在进入共享原生层前后都会进行参数归一化和基础校验。

## 8. 第三方依赖与构建集成

### 8.1 依赖

- `third_party/libssh2`
- `third_party/mbedtls-3.6.6`

其中：

- `third_party/libssh2` 已切换为 `gaord/libssh2` fork，用于承载 `FindMbedTLS.cmake` 的 in-tree mbedTLS target 兼容补丁。
- `third_party/mbedtls-3.6.6` 固定为当前已验证兼容 `libssh2` 的 mbedTLS 版本。

### 8.2 CMake 集成

`shared_native/CMakeLists.txt` 负责：

- 选择 `mbedTLS` 作为 `libssh2` 后端。
- 将 `libssh2` 与共享 VNC 客户端静态链接。
- 在 HarmonyOS 环境下，如缺少 GnuTLS 预编译产物，则自动执行 `build_tools/gnutls/ohos/build.sh`。

## 9. 一键构建入口

为保证“从代码到集成构建”无需手工切目录和判断平台差异，仓库根目录新增：

- `scripts/build_all.sh`

脚本行为：

- 自动初始化所需 Git 子模块：
  - `third_party/tigervnc`
  - `third_party/libssh2`
  - `third_party/mbedtls-3.6.6`
- 固定按顺序执行 Android `assembleDebug` 与 HarmonyOS `assembleApp`。
- 自动检测以下路径是否存在未提交的原生或 CMake 改动：
  - `shared_native`
  - `android_app/app/src/main/cpp`
  - `ohos_app/entry/src/main/cpp`
- 检测到原生改动时，先自动执行 `hvigorw clean`，再执行 HarmonyOS 构建，符合当前仓库构建规则。

使用方式：

```bash
./scripts/build_all.sh
```

## 10. 本次提交流水线验证

本次改动已完成以下验证：

- Android：`./gradlew assembleDebug`
- HarmonyOS：`hvigorw assembleApp`
- Android 关键文件诊断：通过
- HarmonyOS 关键文件诊断：通过

## 11. 本次补充修正

除 SSH 能力本身外，本次还完成以下提交流水线收口：

- 修正 HarmonyOS 首页高级页未实际接入 SSH 自动预填逻辑的问题。
- 修正 HarmonyOS 新增连接仍带出上次地址与凭据的问题。
- 删除 HarmonyOS `Index.ets` 中未被引用的旧 SSH 编辑 Builder，避免后续继续误改错误路径。
- 将低价值的“更多选项”“先完成基础连接”类文案替换为更具体的交互语义，降低理解成本。
- 为 Android SSH 编辑区补回必要说明，明确“SSH 服务器”和“转发目标”的区别。

## 12. 当前已知边界

- `Viewer.ets` 中仍保留轻量级编辑弹层，不承担完整的 SSH 高级配置编辑职责；完整 SSH 编辑主路径位于 `Index.ets` 首页连接管理弹层。
- HarmonyOS 构建阶段仍会出现一条与剪贴板权限相关的既有告警，该告警不影响本次 SSH 隧道集成构建成功。
- 共享原生层当前固定依赖 `mbedtls-3.6.6` 子模块，未继续保留另一份通用 `mbedtls` 目录。

## 13. 结论

当前 SSH 隧道能力已经形成“共享原生实现 + Android/HarmonyOS 双端桥接 + 高级页配置 + 一键构建验证”的完整闭环，满足提交前的代码收口、跨端对齐和自动化构建要求。
