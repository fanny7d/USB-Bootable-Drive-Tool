# USB 启动盘工具

[![macOS CI](https://github.com/fanny7d/USB-Bootable-Drive-Tool/actions/workflows/macos.yml/badge.svg)](https://github.com/fanny7d/USB-Bootable-Drive-Tool/actions/workflows/macos.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-AppKit-F05138?logo=swift&logoColor=white)

一个原生 macOS AppKit 工具，用于将 ISO/IMG 镜像写入可移动 U 盘。它提供严格的目标磁盘过滤、系统控制的权限边界，以及符合 macOS 风格的透明毛玻璃界面。

**[English](README.md)**

![应用截图](docs/app-screenshot.png)

新版响应式工作区把镜像与目标盘集中在“制作准备”卡片中，制作状态和实时输出使用独立的弹性区域；长文件名和设备名会被稳定省略，不再撑大窗口。

> [!CAUTION]
> 写入镜像会永久覆盖所选 U 盘。确认前请备份重要数据，并核对设备名称、容量和磁盘编号。

## 功能

- 原生 AppKit 与 macOS 系统毛玻璃材质。
- 可调整大小的工具窗口；长镜像名和设备名会稳定省略，增加的垂直空间优先用于制作日志。
- 支持选择 ISO 和 IMG 镜像。
- 自动发现外置 U 盘，支持插拔后自动刷新。
- 只显示外置、可移动、可写的物理整盘。
- 在破坏性操作前重新核验磁盘身份和精确字节容量。
- 使用 macOS 系统授权窗口，不再打开 Terminal；可用的密码、Touch ID 或 Apple Watch 验证方式由系统决定。
- 写入状态、`dd` 进度和错误全部显示在 App 的“制作日志”中。
- 完成结果页汇总镜像、目标盘、耗时和安全弹出状态。
- 使用 `/dev/rdiskN` 写入，随后执行 `sync` 并安全弹出。
- 完整 Dock/Finder 图标、标准菜单和无障碍标签。
- 可复现的命令行构建，运行时无第三方依赖。

## 系统要求

- macOS 13 Ventura 或更高版本。
- 下载 DMG 需要 Apple Silicon Mac（arm64）。
- Xcode Command Line Tools（`xcode-select --install`）。
- 一个可移动 U 盘。
- 与目标电脑兼容、支持原始 USB 写入的可启动 ISO/IMG。

## 安装

从 [GitHub Releases](https://github.com/fanny7d/USB-Bootable-Drive-Tool/releases/latest) 下载最新的 `macOS-arm64.dmg` 和对应 `.sha256` 文件，把两者放在同一目录后验证：

```bash
shasum -a 256 -c USB-Bootable-Drive-Tool-*-macOS-arm64.dmg.sha256
```

当前下载版本使用临时签名，尚未经过 Apple 公证；首次启动前请阅读[分发说明](#分发说明)。

## 构建运行

```bash
git clone https://github.com/fanny7d/USB-Bootable-Drive-Tool.git
cd USB-Bootable-Drive-Tool
./script/build_and_run.sh --verify
```

生成的应用位于仓库根目录：`USB启动盘工具.app`。也可以双击 `build.command`。

完整开发命令：

```bash
./script/build_and_run.sh --build-only
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --verify
```

生成与 Release 相同的 Apple Silicon DMG 和校验文件：

```bash
./script/package_dmg.sh
```

产物位于 `dist/`。脚本会拒绝非 arm64 二进制，并在完成前验证 App 签名和磁盘映像。

## 使用方法

1. 插入可移动 U 盘，程序会自动刷新。
2. 选择 `.iso` 或 `.img` 系统镜像。
3. 核对目标名称、容量、磁盘编号和连接协议。
4. 点击“制作启动盘”，再次检查破坏性确认信息。
5. 在 macOS 系统授权窗口中完成验证；App 不会读取或保存密码。
6. 等待写入、同步和安全弹出完成后再拔出 U 盘。

## 安全模型

程序保留两层独立校验：

- GUI 使用 `diskutil` plist 数据筛选候选磁盘。
- 系统授权后的特权任务在卸载和写入前再次读取并核验目标磁盘与镜像大小。

App 不读取或保存管理员密码，所有任务输出都通过受控管道回传到 App。完整安全边界参见[架构说明](docs/ARCHITECTURE.md)。

## 测试

运行全部非破坏性检查：

```bash
./script/test.sh
```

构建、启动、磁盘识别和签名通过，并不等于实际写盘或启动验证通过。需要进行破坏性验收时，请严格按照[测试说明](docs/TESTING.md)，只使用可丢弃的物理 U 盘。

## 参与贡献与安全问题

欢迎贡献。提交 PR 前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。可能影响磁盘选择、权限边界或原始写入的安全问题，请按照 [SECURITY.md](SECURITY.md) 私下报告。

## 分发说明

本地构建和当前下载版本均使用临时签名。由于项目尚未配置 Apple Developer ID 证书，安装包没有经过 Apple 公证，macOS Gatekeeper 可能要求用户显式批准。自行从源码构建不需要付费开发者账号。

## 许可证

本项目使用 [MIT License](LICENSE)。
