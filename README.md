# AEMachBoot

> *(AEMachBoot is the first native PXE + iSCSI bare-metal/diskless boot server designed for macOS & Apple Silicon. Equipped with a modern GUI and zero external dependencies (no Docker or virtual machines required), it enables your Mac to directly host RAW disk images `.img` and boot network clients effortlessly.)*


## 🌟 Background & Features

Ever since Apple deprecated macOS Server and its native NetBoot infrastructure, Mac users seeking to build a diskless network boot environment on a local network have generally had to rely on running virtual machines (VMware/Parallels) or heavy Linux Docker containers.

**AEMachBoot completely changes this landscape.** Written in **pure Swift**, it rewrites the entire server-side stack—from low-level network protocols (DHCP, TFTP, HTTP) to the storage block device interpreter (iSCSI Target)—delivering a lightweight, natively optimized experience on macOS (specifically Apple Silicon M-series chips).

### Core Features at a Glance
* ⚡ **Zero Dependencies**: No Docker, no Linux VMs, no external C dynamic libraries. Double-click to run.
* 🖥️ **Modern SwiftUI GUI**: Features dashboard status cards, a storage image manager, a network interface binding console, and a real-time Hex Dump log analyzer.
* 🌐 **Full Native Boot Protocol Stack**:
  * **DHCP / ProxyDHCP (UDP 67 & 4011)**: Supports ProxyDHCP bypass mode (injects PXE boot options without interfering with your main router's DHCP server).
  * **TFTP Server (UDP 69)**: Supports RFC 2347/2348/2349 advanced negotiation for block size (`blksize`) and file size (`tsize`).
  * **HTTP Bootstrap Server (TCP 8080)**: Delivers secondary accelerated file downloads for iPXE.
  * **iSCSI Target (TCP 3260)**: A fully implemented ANSI SPC-4 / SBC-3 SCSI command set driver.
* 🛠️ **RAW Storage Image Manager**: Easily create blank `.img` virtual disks, import external system disks, or package operating system folders into standard RAW boot images in a single click.
* 🔒 **Privileged Security Elevation (XPC Architecture)**: Adopts Apple's recommended `NSXPCConnection` architecture. A secure, standalone Helper Tool daemon handles low-port binding (`<1024`) and BSD raw block device mounting.

---

## 📐 System Architecture

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

## 🛠️ Key Technical Highlights

### 1. Custom High-Performance iSCSI Target & SCSI State Machine
Instead of relying on simple file mappings, AEMachBoot implements a full SCSI SPC-4 (Primary Commands) and SBC-3 (Block Commands) standard driver, supporting:
- **ANSI Standard Commands**: `INQUIRY`, `READ CAPACITY (10/16)`, `READ (6/10/16)`, `WRITE (6/10/16)`, `MODE SENSE (6/10)`, `REPORT LUNS`, `ALUA`, etc.
- **Windows / Linux Bare-Metal Compatibility**: Specifically tailored for Windows 10/11 diskless booting requirements by accurately responding to VPD Pages `0x80` (Serial Number), `0x83` (Device ID), and `0xB0` (Block Limits Page).

### 2. POSIX Direct I/O Engine (`BlockDeviceReader`)
To avoid cache latency and write-barrier inconsistencies caused by the macOS Virtual Memory Page Cache, the storage layer relies directly on POSIX standards and kernel system calls:
- Enforces `F_NOCACHE` via `fcntl` to bypass kernel caching.
- Uses `posix_memalign` to enforce strict memory sector boundary alignment (512B / 4096B).
- Supports direct binding to kernel-level BSD raw character block device nodes (`/dev/rdiskX`) for maximum throughput.

---

## 💻 System Requirements

* **Operating System**: macOS 13.0 (Ventura) or later.
* **Architecture**: Apple Silicon (M1/M2/M3/M4 series chips).
* **Development Environment**: Xcode 15.0+ (required if building from source).
* **Network Environment**: A wired Ethernet connection (e.g., Gigabit/10GbE USB-C network adapters) is highly recommended. Wi-Fi latency is not suitable for bare-metal network booting.

---

## 🚀 Quick Start Guide

### 📦 Using Pre-compiled Releases

If you do not need to modify the source code, you can download the pre-compiled application directly:

1. **Download**: Go to the GitHub Releases page and download the latest `.dmg` installer.
2. **Install**: Open the DMG file and drag `AEMachBoot.app` into your system's **`/Applications`** folder.
3. **Remove Gatekeeper Quarantine Attribute**:
   Because the pre-compiled version is not signed with an Apple Developer certificate, run the following command in Terminal before launching it for the first time to clear macOS download quarantine flags:

   ```bash
   xattr -cr /Applications/AEMachBoot.app
   ```

### 1. Build and Install from Source

```bash
# 1. Clone the repository
git clone https://github.com/Aethel-Systems/AEMachBoot.git
cd AEMachBoot

# 2. Open project in Xcode
open AEMachBoot.xcodeproj
```
*In Xcode, select the `AEMachBoot` scheme and press `Cmd + R` to build and run.*

💡 **Developer Note**: Because this project uses an XPC Privileged Helper Tool (`NSXPCConnection`), make sure to set the **Development Team** under **Signing & Capabilities** for both the App and Helper Tool targets to `None` or your own Apple Developer Account prior to compiling in Xcode. Ensure their Bundle Identifiers maintain a proper parent-child relationship.

### 2. Configure and Launch Services

1. **Bind Network Interface**: Go to the **Network Settings** screen in the sidebar and select the physical Ethernet adapter connected to your diskless client (e.g., `en0`).
2. **Select DHCP Mode**:
   * **ProxyDHCP Mode**: No need to disable your router's DHCP server. AEMachBoot will operate in bypass mode, injecting only PXE boot options.
   * **Standard DHCP Mode**: If there is no active router on the local network, AEMachBoot will act as the primary DHCP server and assign IP addresses automatically.
3. **Prepare Storage Image**:
   * Open the **Image Manager** screen.
   * Click **Create Blank RAW Image** to generate a blank `.img` file (e.g., a 64GB drive for OS installation);
   * Or click **Open External .img...** to import an existing diskless boot image.
4. **Ignition**: Return to the bottom of the sidebar and click the **Power On Engine** button to start all network services.

### 3. Bare-Metal Client Boot Configuration

Connect your bare-metal client computer to the same local network:
1. Enter client BIOS settings and enable **Network Boot (PXE)**.
2. Set the boot order priority to **UEFI Network Boot**.
3. Save and restart. The client will automatically fetch the bundled `ipxe.efi` bootloader from AEMachBoot, mount the iSCSI SAN volume, and boot into the operating system.

---

## ⚙️ Network Boot Workflow

AEMachBoot utilizes an efficient **Two-Stage iPXE Boot Chain Design** to avoid traditional PXE deadlocks caused by infinite DHCP loops:

1. **Stage 1 (Native PXE Boot)**: The bare-metal firmware sends a DHCP Discover packet. AEMachBoot responds with PXE Options 60/66/67, instructing the client to download the bundled `ipxe.efi` (or `ipxe.kpxe` for Legacy BIOS).
2. **Stage 2 (iPXE Boot Engine)**: Once `ipxe.efi` initializes, it sends a second network request. AEMachBoot identifies the iPXE feature headers and automatically delivers the `boot.ipxe` script URL.
3. **Stage 3 (iSCSI SANBoot)**: iPXE executes `sanboot iscsi:${next-server}::::iqn.2026-07.com.aemachboot:target0`, directly attaching the iSCSI Target block device and booting the host OS over the network.

---

## 🛡️ Advanced Architecture (XPC & POSIX Direct I/O)

Due to macOS App Sandbox restrictions and System Integrity Protection (SIP), standard unprivileged applications cannot bind to privileged ports below 1024 (such as UDP 67/69) or directly attach BSD raw block devices.

AEMachBoot adopts Apple's industrial-grade XPC privilege elevation architecture:

```
AEMachBoot.app (User Space)
      │
      ├── SecCode Audit Token Check (Security Audit Verification)
      ▼
HelperTool.xpc (Privileged Helper Service)
      │
      ├── getBoundSocket() ──► Privileged binding to ports 67/69 & returns File Descriptor to main app
      └── executePrivilegedHdiutil() ──► Safely mounts /dev/rdisk raw block nodes
```

---

## 📄 License & Attributions

### Open Source License
This project is open-sourced under the **GNU General Public License v3.0 (GPL-3.0)**. Please refer to the [LICENSE](LICENSE) file for full license text.

### Third-Party Components & Notice
This project bundles/includes the following third-party open-source component:

* **[iPXE](https://ipxe.org/)** (`ipxe.efi` / `ipxe.kpxe`)
  * **License**: GNU General Public License v2 (GPLv2)
  * **Description**: AEMachBoot bundles and redistributes compiled iPXE bootloader binaries within its application bundle to facilitate client network booting. The iPXE source code and copyrights belong to the iPXE open-source community.

> **GPL Compliance Statement**: Pursuant to the terms of the GPL, any derivative works or redistributions based on this project must remain open-source and be distributed under GPLv3 (or a compatible license).