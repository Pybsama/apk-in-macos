# APK in macOS

**简体中文** | [English](README_EN.md)

面向 **Apple Silicon (ARM64) Mac** 的极简暖白安卓运行书架：**零弹窗、拖进去就能用**。把 `.apk` / `.xapk` / `.apkm` 直接拖入书架窗口，原位自动解析图标与名称、安装到严格隔离的 Android 15 ARM64 环境、在 `~/Applications/APK in macOS/` 生成独立可双击的 Mac `.app` 快捷方式，并以原生级独立的 Retina 缩放窗口运行。

> 同时提供同源共用界面的可选 Windows 兼容拓展 [**EXE in macOS**](#附带拓展exe-in-macos可选-windows-兼容拓展)（独立打包仅 ~1.5 MB），专用于运行独立 / 同人 RPG、视觉小说（Galgame）与轻量 Windows 工具；纯安卓用户无需下载或承载任何 Windows 运行时体积。

![APK in macOS](docs/images/apk-shelf.png)

---

## 核心特性

- **拖入即用，零弹窗**：将 `.apk` / `.xapk` / `.apkm` 直接拖入书架，自动提取真实图标与应用名称、自动拉起隔离的 Android 15 ARM64 环境，并自动生成独立的 Mac `.app` 快捷方式（也可直接双击快捷方式或通过 `apkinmacos://open?pkg=` 唤起）。
- **独立多窗口 + Retina 自适应缩放**：每个 Android 应用运行在独立的 `VirtualDisplay` 与硬件加速 H.264 显示流中，支持多开、自由缩放窗口、触控板滚轮、键盘输入与 `⌘V` 粘贴。
- **支持 `.xapk` / `.apkm` 分包与 `.obb` 数据包**：自动解包并过滤 `arm64-v8a` 兼容分包，通过 `adb install-multiple` 安装并自动推送配套 `.obb` 至 `/sdcard/Android/obb/`。
- **直接拖文件进安卓窗口**：将图片、PDF、压缩包等文件拖入任意运行中的安卓窗口，自动推送到 `/sdcard/Download/` 并触发媒体库扫描。
- **轻量省资源**：默认分配 `3 GB` 内存，自动停用非必要谷歌预装后台（保留 Play 服务、输入法与 WebView）；无窗口满 30 秒自动降为低优先级，空闲满 5 分钟自动保存快照并休眠回收内存（可在 `⋯ → 性能与资源` 随时调整或手动唤醒）。
- **环境严格隔离 + 新手引导**：专用 AVD `APKInMacOS_Shelf35`（端口 `5576`）保存在 `~/Library/Application Support/APKInMacOS/`，绝不触碰 `~/.android/avd` 中已有模拟器环境；若本机尚未安装 Android SDK，空书架会展示极简的一键复制 `brew` / `sdkmanager` 安装指引。
- **欧洲古卷暖白界面 + 翻页双语切换**：微暖纸张底色（`#F6F3EB`）与统一 `820×540` 舒展布局；点击右上角斜切折痕的 `中 / EN` 翻页开关即可实时切换中文 / 英文（菜单栏 `Language / 语言` 亦可切换）。

---

## 附带拓展：EXE in macOS（可选 Windows 兼容拓展）

作为同仓库的可选伴侣拓展，`EXE in macOS`（`dist/EXEInMacOS.app`，**实验性**）复用 `ShelfKit` 书架交互与暖白界面，独立打包为仅约 `1.5 MB` 的轻量应用，快捷方式存放在 `~/Applications/EXE in macOS/`，让不想折腾 Wine 的安卓用户保持零冗余。

![EXE in macOS](docs/images/exe-shelf.png)

- **最适合的场景**：独立 / 同人 RPG（RPG Maker MV / MZ / XP / VX / VXAce）、视觉小说 / Galgame（TyranoBuilder、Ren'Py、Wolf RPG、吉里吉里等）、Unity 独立游戏，以及免安装绿色轻量 Windows 工具。
- **智能双引擎（专治 RPG 卡顿与键盘失效）**：
  - **NW.js / RPG Maker MV·MZ / TyranoBuilder / Construct 游戏**：自动识别真实标题与封面图标，默认路由至 **Apple Silicon 原生 ARM64 NW.js 引擎**（Metal 硬件加速 60 帧、静止 CPU `<1%`、原生中文与键盘响应）；右键菜单亦可随时切换回 Wine。
  - **Unity / RPG Maker XP·VX·VXAce / Ren'Py / 常规 Win32**：通过 Wine Stable 11.0 + **DXVK-macOS**（DirectX 10/11 → Metal 3 + 异步着色器 + `esync`）运行；Unity 自动注入 `-force-d3d11`，经典 RPG Maker 自动解析 `Game.ini` 标题。
- **免转区、防乱码与便捷排错**：
  - 支持直接拖入 `.exe` / `.msi` / `.zip` 压缩包或整个游戏目录；`.zip` 自动按 UTF-8 → Shift-JIS (CP932) → GB18030 智能解码解压，避免日文路径乱码，并自动跳过卸载程序/崩溃汇报器锁定主 `.exe`。
  - 自动识别日系 RPG 并匹配 `ja_JP.UTF-8`（Shift-JIS），也可在任意程序右键「**运行区域 (Locale)**」中手动切换简体中文 / 日文 / 繁体中文 / 英文；初始化时自动注册 `ArialUnicode.ttf` 与中日韩字体替换表。
  - 8 秒内异常闪退会给出针对性诊断（缺失 VC++ 运行库、RPG Maker RTP 等）；`⋯ → 性能与兼容` 支持一键按需安装 **VC++ 运行库 (x64)**，右键支持查看日志与重命名（同步更新快捷方式）；所有程序关闭满 2 分钟自动退出 `wineserver`。
- **兼容边界（坦诚说明）**：不适合微信/QQ/钉钉等带反作弊或驱动保护的国产桌面客户端、重度商业套件（Adobe / Office / CAD），以及带内核级反作弊或强依赖闭源 D3D12（苹果 D3DMetal 不可随开源项目分发）的 3A 大作。

---

## 安装与首次运行

1. 从 [GitHub Releases](../../releases) 按需下载对应压缩包（两者完全独立）：
   - `APKInMacOS-arm64.zip`：主力 **APK in macOS**（~1.8 MB）
   - `EXEInMacOS-arm64.zip`：可选拓展 **EXE in macOS**（~1.5 MB）
2. 解压后将 `.app` 拖入 `/Applications`（应用程序）文件夹。
3. **首次打开提示（重要）**：开源发布的二进制采用本地 ad-hoc 签名，未经过 Apple 公证。若 macOS 提示「已损坏」或「无法验证开发者」，在终端运行以下命令清除隔离属性后即可正常打开：

```bash
xattr -cr /Applications/APKInMacOS.app
# 如同时使用 Windows 拓展：
xattr -cr /Applications/EXEInMacOS.app
```

### 运行环境要求
- **系统与芯片**：Apple Silicon（M1 / M2 / M3 / M4）Mac，macOS 14.0 或更高版本。
- **安卓运行依赖**：需要本机已安装 Android SDK / Emulator（`APKInMacOS.app` 首次未检测到 SDK 时会在空书架给出 Homebrew 一键安装命令）。

---

## 目录结构

```text
Sources/
├─ ShelfKit/       共用暖白古卷主题、中/EN 翻页开关、Mac .app 快捷方式生成、多语言与工具
├─ APKRuntime/     Android SDK 发现、APK/XAPK/APKM 解析、多屏 H.264 显示桥接与 AVD 生命周期
├─ WineRuntime/    纯 Swift PE (.exe) 解析、智能编码 ZIP/目录解析、Wine/NW.js/DXVK 按需管理
├─ APKShelfApp/    APK in macOS 主程序
└─ EXEShelfApp/    EXE in macOS 可选 Windows 拓展（实验性）
```

---

## 快速构建与打包

```bash
# 运行全部单元测试
swift test

# 仅打包主程序 APK in macOS (dist/APKInMacOS.app)
BUILD_CONFIG=release ./script/package_app.sh

# 同时打包主程序与可选 Windows 拓展 (dist/APKInMacOS.app + dist/EXEInMacOS.app)
BUILD_CONFIG=release ./script/package_all.sh

# 若本机没有安装 Android SDK，可复用仓库已构建的 display-bridge.jar：
BUILD_CONFIG=release SKIP_BRIDGE_BUILD=1 ./script/package_all.sh
```

---

## 开源许可与第三方运行时声明

- 本仓库源码采用 [MIT License](LICENSE) 开源。
- 仓库与打包产物**不包含** Wine、NW.js 或 DXVK 二进制文件；本机未安装时仅在首次运行对应 Windows 程序时按需从官方/社区发布源拉取并校验 `SHA-256`：
  - **Wine Stable**（LGPL-2.1+，macOS 包源自 WineHQ 维护者 [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds)）
  - **DXVK-macOS**（zlib/libpng License，源自 [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS)）
  - **NW.js macOS ARM64**（MIT License，源自 [nwjs.io](https://nwjs.io/)）
