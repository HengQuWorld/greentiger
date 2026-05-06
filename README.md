# 翠虎远程桌面

翠虎远程桌面是一款跨平台 VNC 远程桌面客户端，支持 HarmonyOS 和 Android 平台，提供稳定、安全的远程桌面连接体验。

## 功能特性

- **VNC 远程桌面**：通过标准 VNC 协议连接并控制远程计算机，支持画面查看、鼠标、触控与键盘输入。
- **SSH 隧道**：支持可选的 SSH 加密隧道，提供密码认证和公钥认证两种方式，支持 `known_hosts` 主机指纹严格校验，保障连接安全。
- **剪贴板同步**：支持本地与远程之间的文本剪贴板双向同步。
- **多显示器支持**：自动识别多显示器布局，支持屏幕切换、查看模式切换与分屏显示。
- **Mac 模式**：连接 Mac 时自动将 Ctrl 映射为 ⌘ 键，修复剪贴板快捷键等操作习惯差异。
- **连接管理**：支持创建、保存、编辑、删除和搜索远程连接配置，密码可选择本地加密保存。
- **截图保存**：会话过程中支持截图并保存到本地。
- **多窗口模式**（鸿蒙端）：支持将不同显示器内容拆分到独立窗口中查看。
- **画中画模式**（安卓端）：支持画中画悬浮窗，方便多任务场景。

## 平台支持

| 平台 | UI 框架 | 原生桥接 | 构建工具 |
|------|---------|----------|----------|
| HarmonyOS | ArkTS / ArkUI | NAPI | hvigor |
| Android | Jetpack Compose | JNI | Gradle |

## 项目结构

```
greentiger-open/
├── shared_native/           # 双平台共享 C++ 原生层（VNC 客户端、SSH 隧道、多屏检测）
├── ohos_app/                # 鸿蒙端应用（Stage 模型）
│   └── entry/src/main/
│       ├── cpp/             # NAPI 原生桥接
│       ├── ets/
│       │   ├── pages/       # 页面：连接管理、远程会话、分屏显示
│       │   └── utils/       # 工具：按键映射、连接工具、多窗口管理
│       └── module.json5
├── android_app/             # 安卓端应用
│   └── app/src/main/
│       ├── cpp/             # JNI 原生桥接
│       └── AndroidManifest.xml
├── build_tools/gnutls/      # GnuTLS 双平台构建脚本
├── scripts/                 # 构建与辅助脚本
├── third_party/
│   ├── tigervnc/            # TigerVNC 源码（VNC 协议实现）
│   ├── libssh2/             # libssh2 源码（SSH 隧道）
│   └── mbedtls-3.6.6/       # Mbed TLS 源码（加密库）
└── docs/                    # 设计文档与协议
```

## 构建

### 前置条件

- 鸿蒙端：DevEco Studio / hvigor 构建环境、HarmonyOS SDK
- 安卓端：Android SDK、JDK 17+
- 确保已初始化 Git 子模块

### 初始化

```bash
git submodule update --init --recursive
```

### 一键构建

```bash
./scripts/build_all.sh          # Debug 模式
./scripts/build_all.sh release  # Release 模式
```

### 分端构建

**鸿蒙端：**

```bash
cd ohos_app
hvigorw assembleApp                          # Debug 模式
hvigorw assembleApp -p buildMode=release     # Release 模式
```

修改了原生 C++ 代码或 CMakeLists.txt 时需要先 clean：

```bash
hvigorw clean
hvigorw assembleApp
```

**安卓端：**

```bash
cd android_app
./gradlew assembleDebug      # Debug 模式
./gradlew assembleRelease    # Release 模式
```

### 构建产出

- 鸿蒙端：`.hap` / `.app` 包，位于 `ohos_app/build/outputs/`
- 安卓端：`.apk` 包，位于 `android_app/app/build/outputs/apk/`

## 架构说明

应用采用"共享原生 + 平台 UI"的分层架构：

1. **shared_native**：平台中立的 C++ 层，封装 VNC 连接、SSH 隧道、多显示器分割等核心逻辑。
2. **平台桥接层**：通过 NAPI（鸿蒙）/ JNI（安卓）将 C++ 能力暴露给上层 UI。
3. **平台 UI 层**：鸿蒙端使用 ArkTS/ArkUI，安卓端使用 Jetpack Compose，各自实现用户体验。

`shared_native` 的代码改动必须同时验证双平台构建通过。

## 第三方许可

本项目使用以下开源组件：

- [TigerVNC](https://github.com/TigerVNC/tigervnc) — GPL-2.0
- [libssh2](https://github.com/libssh2/libssh2) — BSD-3-Clause
- [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) — Apache-2.0 / GPL-2.0

本项目本身采用 GPL-2.0 许可证，详见 [LICENCE.TXT](LICENCE.TXT)。

## 相关文档

- [用户协议](https://www.hengqu.world/agreements/user-agreement)
- [隐私政策](https://www.hengqu.world/agreements/privacy-policy)
- [SSH 隧道集成报告](docs/ssh-tunnel-integration-report.md)
- [连接管理 UX 设计规格](docs/connection-management-ux-guidelines.md)

## 法律声明

本仓库历史上曾包含用户协议和隐私政策的副本。这些副本已被移除。
翠虎远程桌面的用户协议与隐私政策以官方网站发布的版本为唯一正式版本：
- [用户协议](https://www.hengqu.world/agreements/user-agreement)
- [隐私政策](https://www.hengqu.world/agreements/privacy-policy)

本仓库中的任何历史副本均不构成横渠天地（北京）科技有限公司对用户的承诺或协议。
构建时，应用通过 `scripts/sync_agreements.py` 从官方网站自动下载协议全文并打包进应用。
