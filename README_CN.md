# AEMachBoot

> *(AEMachBoot 是首款面向 macOS & Apple Silicon 的原生 PXE + iSCSI 裸机/无盘启动服务端，配备现代化 GUI，无需任何 Docker、虚拟机或外部依赖，即可让 Mac 直接托管 RAW 磁盘镜像 `.img` 并通过网络引导客户端。)*


## 🌟 背景与特性

自 Apple 废弃 macOS Server 及其原生的 NetBoot 基础设施以来，Mac 用户若想在局域网内搭建无盘网络引导（Diskless Boot）环境，通常只能依赖开虚拟机（VMware/Parallels）或运行庞大的 Linux Docker 容器。

**AEMachBoot 彻底改变了这一现状。** 它使用 **纯 Swift 语言** 重构了从底层网络协议（DHCP, TFTP, HTTP）到存储块设备解释器（SCSI Target）的全套服务端栈，以极其轻量的资源占用原生运行在 macOS（特别是 Apple Silicon M 系列芯片）上。

### 核心功能一览
* ⚡ **零外部依赖 (Zero Dependencies)**：无需 Docker、无需 Linux 虚拟机、无外部 C 动态库，双击即用。
* 🖥️ **现代 SwiftUI 图形化界面**：集成了仪表盘状态卡片、存储镜像管理器、网卡绑定控制台与实时 Hex Dump 日志分析器。
* 🌐 **全套原生引导协议栈**：
  * **DHCP / ProxyDHCP (UDP 67 & 4011)**：支持 ProxyDHCP 旁路模式（仅注入 PXE 参数，不干扰现有主路由器 DHCP）。
  * **TFTP Server (UDP 69)**：支持 RFC 2347/2348/2349 高级块大小 (blksize) 与文件大小 (tsize) 协商。
  * **HTTP Bootstrap Server (TCP 8080)**：为 iPXE 提供二次加速下载。
  * **iSCSI Target (TCP 3260)**：完整实现的 ANSI SPC-4 / SBC-3 SCSI 指令集驱动。
* 🛠️ **RAW 存储镜像管理器**：支持快速创建空白 `.img` 虚拟盘、导入外部系统盘，或将操作系统文件夹直接一键打包为标准的 RAW 引导镜像。
* 🔒 **特权安全提权 (XPC Architecture)**：采用 Apple 官方推荐的 `NSXPCConnection` 架构，安全的独立 Helper Tool 机制支持低端口绑定与 BSD 原始块设备挂载。

---

## 📐 系统架构图

```
                ┌────────────────────────────────────────────────────────┐
                │                     AEMachBoot App                     │
                │        (SwiftUI / ServiceCoordinator / AppState)       │
                └───────────────────────────┬────────────────────────────┘
                                            │ NSXPCConnection
                                            ▼
                                ┌──────────────────────┐
                                │ HelperTool Daemon    │ (Privileged Helper)
                                └───────────┬──────────┘
                                            │ Bind Ports <1024 & Raw Disk Attach
                                            ▼
 ┌──────────────────────────────────────────────────────────────────────────────────────┐
 │                              AEMachBoot Protocol Core                                │
 │                                                                                      │
 │  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐    ┌────────────┐ │
 │  │   DHCPServer    │    │   TFTPServer    │    │   HTTPServer    │    │iSCSITarget │ │
 │  │(UDP 67 / 4011)  │    │    (UDP 69)     │    │   (TCP 8080)    │    │ (TCP 3260) │ │
 │  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘    └─────┬──────┘ │
 └───────────┼──────────────────────┼──────────────────────┼───────────────────┼────────┘
             │                      │                      │                   │
             │                      │                      │                   │
             ▼                      ▼                      ▼                   ▼
┌───────────────────────────────────────────────────────────────────────────────────────┐
│                               Bare-Metal Network Client                               │
│                                                                                       │
│ 1. DHCP Discover ──────► Receive ProxyDHCP Offer (Boot file: ipxe.efi)                │
│ 2. TFTP Download  ──────► Load iPXE Core into RAM                                     │
│ 3. iPXE Boot      ──────► Fetch boot.ipxe via HTTP & Trigger iSCSI SANBoot            │
│ 4. iSCSI SANBoot  ──────► Mount IQN Target & Boot OS directly over Network            │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🛠️ 核心技术亮点

### 1. 自研高性能 iSCSI Target & SCSI 状态机
AEMachBoot 并没有使用简单的文件映射，而是完整实现了 SCSI SPC-4 (Primary Commands) 和 SBC-3 (Block Commands) 标准，支持：
- **ANSI 标准指令处理**：`INQUIRY`, `READ CAPACITY (10/16)`, `READ (6/10/16)`, `WRITE (6/10/16)`, `MODE SENSE (6/10)`, `REPORT LUNS`, `ALUA` 等。
- **Windows / Linux 裸机兼容性**：针对 Windows 10/11 的无盘引导要求，实现了 VPD Page `0x80` (Serial Number), `0x83` (Device ID) 和 `0xB0` (Block Limits Page) 的精确回应。

### 2. POSIX Direct I/O 引擎 (`BlockDeviceReader`)
为了避免 macOS 虚拟内存层的 Page Cache 带来写屏障不一致与延迟问题，存储层直接基于 POSIX 标准与系统调用：
- 强制使用 `F_NOCACHE` 绕过内核缓存。
- 使用 `posix_memalign` 实现内存扇区边界严格对齐（512B / 4096B）。
- 支持直接绑定内核态 BSD 原始字符块设备节点（`/dev/rdiskX`），发挥极致吞吐性能。

---

## 💻 环境要求

* **操作系统**：macOS 13.0 (Ventura) 或更高版本。
* **架构**：Apple Silicon (M1/M2/M3/M4 系列芯片)。
* **开发环境**：Xcode 15.0+ (用于编译源码)。
* **网络环境**：建议使用物理以太网线连接网卡（如千兆/万兆 USB-C 网卡），WiFi 延时较高不建议用于裸机启动。

---

## 🚀 快速上手指南

### 📦 使用预编译 Release 版本

如果您无需修改源码，可以直接下载编译好的二进制程序：

1. **下载应用**：前往仓库 Releases 页面，下载最新的dmg安装包。
2. **移动位置**：打开dmg并将 `AEMachBoot.app` 拖入系统的 **`/Applications` (应用程序)** 目录。
3. **解除 Gatekeeper 隔离属性**：
   由于预编译版本未进行 Apple 开发者证书签名，首次运行前需打开终端（Terminal）执行以下命令，移除 macOS 的网络下载隔离标记：

   ```bash
   xattr -cr /Applications/AEMachBoot.app

### 1. 源码编译与安装

```bash
# 1. 克隆代码库
git clone https://github.com/Aethel-Systems/AEMachBoot.git
cd AEMachBoot

# 2. 使用 Xcode 打开项目
open AEMachBoot.xcodeproj
```
*在 Xcode 中选择 `AEMachBoot` Scheme，按 `Cmd + R` 编译并运行。*

💡 开发者提示：由于本项目使用了 XPC 提权 Helper Tool（NSXPCConnection），在本地 Xcode 编译前，请确保在 Target 的 Signing & Capabilities 中将 App 与 Helper Tool 的 Development Team 统一修改为 `None` 或者您自己的 Apple 开发者账号，并确保两者的 Bundle Identifier 保持继承关系。

### 2. 配置与启动服务

1. **绑定网卡**：进入应用侧边栏的 **Network Settings** 界面，选择你用于连接无盘裸机的物理以太网卡（如 `en0`）。
2. **选择 DHCP 模式**：
   * **ProxyDHCP 模式**：无需关闭你局域网内的路由器 DHCP，AEMachBoot 只会旁路注入 PXE 启动参数。
   * **Standard DHCP 模式**：若局域网无路由器，AEMachBoot 将充当主 DHCP 服务端并自动分配 IP。
3. **准备系统磁盘镜像**：
   * 进入 **Image Manager** 界面。
   * 点击 **Create Blank RAW Image** 创建空白 `.img` 镜像（例如 64GB 盘用于后续安装系统）；
   * 或点击 **Open External .img...** 导入已制作好的 `.img` 无盘系统镜像。
4. **一键点火**：回到侧边栏底部，点击 **Power On Engine** 按钮启动全部服务。

### 3. 裸机客户端引导配置

把需要启动的客户端电脑网络线连接到同一局域网：
1. 进入裸机 BIOS 设置，开启 **Network Boot (PXE)**。
2. 设置启动项优先顺序为 **UEFI Network Boot**。
3. 保存并开机，裸机将自动拉取 AEMachBoot 提供的 `ipxe.efi` Bootloader，并挂载 iSCSI SAN 卷进入系统。

---

## ⚙️ 网络引导工作流原理

AEMachBoot 采用了高效的 **Two-Stage iPXE 引导链设计**，有效避免了传统 PXE 在无限 DHCP 循环中的死锁问题：

1. **Stage 1 (Native PXE Boot)**：裸机通过固件发送 DHCP Discover，AEMachBoot 回复 PXE Option 60/66/67，告知其下载 Bundle 内置的 `ipxe.efi`（或针对 Legacy BIOS 的 `ipxe.kpxe`）。
2. **Stage 2 (iPXE Boot Engine)**：`ipxe.efi` 启动后发起第二次网络请求，AEMachBoot 识别到 iPXE 特性标头，自动递交 `boot.ipxe` 脚本路径。
3. **Stage 3 (iSCSI SANBoot)**：iPXE 执行 `sanboot iscsi:${next-server}::::iqn.2026-07.com.aemachboot:target0` 命令，直接接管 iSCSI Target 块设备并启动主系统。

---

## 🛡️ 高级架构设计 (XPC & POSIX Direct I/O)

由于 macOS 沙箱与系统安全机制（SIP）限制，普通 App 无法直接绑定 `<1024` 低端口（如 UDP 67/69），也无法直接进行 `hdiutil` 的原始块设备挂载。

AEMachBoot 采用了标准的 Apple 工业级 XPC 提权架构：

```
AEMachBoot.app (User Space)
      │
      ├── SecCode Audit Token Check (安全性审计校验)
      ▼
HelperTool.xpc (Privileged Helper Service)
      │
      ├── getBoundSocket() ──► 提权绑定 67/69 端口并把 File Descriptor 回传主进程
      └── executePrivilegedHdiutil() ──► 安全挂载 /dev/rdisk 磁盘节点
```

---

## 📄 开源协议

### 本项目开源协议
本项目基于 **GNU General Public License v3.0 (GPL-3.0)** 协议开源。完整协议内容请参阅 [LICENSE](LICENSE) 文件。

### 第三方组件与许可证说明
本项目内置/打包了以下第三方开源组件：

* **[iPXE](https://ipxe.org/)** (`ipxe.efi` / `ipxe.kpxe`)
  * **许可证**：GNU General Public License v2 (GPLv2) 
  * **说明**：AEMachBoot 在二进制 Bundle 中打包并分发了 iPXE 编译好的 Bootloader 镜像文件，用于客户端网络引导阶段。iPXE 源码及其版权归属于 iPXE 开发者社区。

> **开源合规声明**：根据 GPL 协议要求，若您基于本项目进行二次修改或重新分发，必须保持开源并同样采用 GPLv3 (或兼容协议) 发布。