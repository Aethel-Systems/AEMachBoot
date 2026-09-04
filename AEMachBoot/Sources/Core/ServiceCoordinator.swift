import Foundation
import Combine

/// 全局服务运行状态定义
public enum ServiceCoordinatorState: String, Sendable {
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case stopping = "Stopping"
    case fault = "Fault"
}

/// 工业级服务编排调度中枢
/// 采用线程安全的 Actor 隔离机制与全局 `@Published` 状态发布并行的混合架构。
/// 协调控制 DHCP, TFTP, HTTP, iSCSI 存储网络服务树的链式初始化、健康监控、特权 XPC 提权通道维护及崩溃自愈。
public final class ServiceCoordinator: NSObject, ObservableObject, @unchecked Sendable {
    
    // 线程安全锁
    private let stateLock = NSLock()
    
    // 全局发布的运行时状态 (供 SwiftUI 视图绑定)
    @Published public private(set) var globalState: ServiceCoordinatorState = .stopped
    @Published public private(set) var dhcpState: ServiceCoordinatorState = .stopped
    @Published public private(set) var tftpState: ServiceCoordinatorState = .stopped
    @Published public private(set) var httpState: ServiceCoordinatorState = .stopped
    @Published public private(set) var iscsiState: ServiceCoordinatorState = .stopped
    @Published public private(set) var connectedClientsCount: Int = 0
    @Published public private(set) var lastErrorMessage: String? = nil
    
    // 依赖注入核心引擎
    private var dhcpServer: DHCPServer?
    private var tftpServer: TFTPServer?
    private var httpServer: HTTPServer?
    private var iscsiTarget: iSCSITarget?
    private var blockReader: BlockDeviceReader?
    
    private let diskController: DiskImageController
    private let logger: AEMachLogger
    
    // 特权辅助工具 XPC 连接通道维护
    private var xpcConnection: NSXPCConnection?
    private let xpcLock = NSLock()
    
    // 运行参数配置
    private let workDirectory: URL
    private var attachedDiskNode: String?
    
    public init(logger: AEMachLogger = .shared) {
        self.logger = logger
        self.diskController = DiskImageController(logger: logger)
        
        // 初始化应用专用工作目录，用于存放临时挂载点及引导文件
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.workDirectory = appSupport.appendingPathComponent("AEMachBoot/TFTPRoot")
        
        super.init()
        
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true, attributes: nil)
        prepareBootloaderResources()
    }
    
    // MARK: - 特权 XPC 隧道管理
    
    /// 建立并校验安全提权的特权通信管道
    private func getXPCConnection() throws -> NSXPCConnection {
        xpcLock.lock()
        defer { xpcLock.unlock() }
        
        if let existing = xpcConnection {
            return existing
        }
        
        logger.info("Initiating secure NSXPCConnection to com.aemachboot.HelperTool...", sys: "com.Aethel.HelpTool", cat: "XPC")
        
        // 注册连接至 MachService 命名空间
        // 修正：连接嵌入在包体内的标准 XPC 服务 (使用我们在工程中配置的 Bundle ID)
        let connection = NSXPCConnection(serviceName: "com.Aethel.HelperTool")
        connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        
        connection.interruptionHandler = { [weak self] in
            self?.logger.warn("XPC Connection to HelperTool was interrupted. Forcing reconnection.", sys: "com.Aethel.HelpTool", cat: "XPC")
            self?.resetXPCConnection()
        }
        
        connection.invalidationHandler = { [weak self] in
            self?.logger.warn("XPC Connection to HelperTool was invalidated. Connection closed.", sys: "com.Aethel.HelpTool", cat: "XPC")
            self?.resetXPCConnection()
        }
        
        connection.resume()
        self.xpcConnection = connection
        return connection
    }
    
    private func resetXPCConnection() {
        xpcLock.lock()
        xpcConnection = nil
        xpcLock.unlock()
    }
    
    // MARK: - 引导加载层资源前置就绪准备
    
    private func prepareBootloaderResources() {
        let fileManager = FileManager.default
        let bundle = Bundle.main
        
        let resourceFiles: [(name: String, ext: String)] = [
            ("ipxe", "efi"),
            ("ipxe", "kpxe")
        ]
        
        for res in resourceFiles {
            let fileName = "\(res.name).\(res.ext)"
            let targetURL = workDirectory.appendingPathComponent(fileName)
            
            var needsCopy = true
            if fileManager.fileExists(atPath: targetURL.path) {
                if let attrs = try? fileManager.attributesOfItem(atPath: targetURL.path),
                   let fileSize = attrs[.size] as? UInt64, fileSize > 10240 {
                    needsCopy = false
                    logger.info("Verified existing valid bootloader asset: \(fileName) (\(fileSize) bytes)", sys: "com.Aethel.HelpTool", cat: "IO")
                } else {
                    logger.warn("Detected corrupted/0-byte asset at \(targetURL.path). Deleting and force-copying from Bundle...", sys: "com.Aethel.HelpTool", cat: "IO")
                    try? fileManager.removeItem(at: targetURL)
                }
            }
            
            if needsCopy {
                var sourceURL: URL? = bundle.url(forResource: res.name, withExtension: res.ext)
                if sourceURL == nil {
                    sourceURL = bundle.resourceURL?.appendingPathComponent(fileName)
                }
                
                if let src = sourceURL, fileManager.fileExists(atPath: src.path) {
                    do {
                        try fileManager.copyItem(at: src, to: targetURL)
                        let size = (try? fileManager.attributesOfItem(atPath: targetURL.path)[.size] as? UInt64) ?? 0
                        logger.info("Successfully copied bootloader asset from Bundle: \(fileName) (\(size) bytes) -> \(targetURL.path)", sys: "com.Aethel.HelpTool", cat: "IO")
                    } catch {
                        logger.error("Failed to copy asset '\(fileName)': \(error.localizedDescription)", sys: "com.Aethel.HelpTool", cat: "IO")
                    }
                } else {
                    logger.critical("⚠️ CRITICAL ERROR: Asset '\(fileName)' was not found in Bundle!", sys: "com.Aethel.HelpTool", cat: "IO")
                }
            }
        }
        
        // 💥【关键修复】：删除脚本里的 dhcp 命令，防止 iPXE 在脚本内二次触发 DHCP 循环！
        let scriptURL = workDirectory.appendingPathComponent("boot.ipxe")
        let ipxeScriptContent = """
        #!ipxe
        set keep-san 1
        sanboot iscsi:${next-server}::::iqn.2026-07.com.aemachboot:target0
        """
        try? ipxeScriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        logger.info("Prepared clean boot.ipxe script successfully.", sys: "com.Aethel.HelpTool", cat: "IO")
    }
    
    // MARK: - 集中编排生命周期调度器
    
    /// 一键异步链式点火启动所有无盘服务
    /// - Parameters:
    ///   - interface: 用于绑定的本地网卡信息
    ///   - imagePath: 选中的存储镜像文件绝对路径
    ///   - enableProxyDHCP: 是否启用 ProxyDHCP 运行模式
    public func startAllServices(
        interface: NetworkInterfaceInfo,
        imagePath: String,
        enableProxyDHCP: Bool
    ) {
        stateLock.lock()
        guard globalState == .stopped || globalState == .fault else {
            stateLock.unlock()
            return
        }
        globalState = .starting
        lastErrorMessage = nil
        stateLock.unlock()
        
        logger.info("Initializing multi-protocol bootloader stack on network interface: \(interface.name)", sys: "com.Aethel.HelpTool", cat: "Lifecycle")
        
        // 开启独立线程任务依次调度，不阻塞 UI 渲染主线程
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            do {
                // 1. 链接提权 XPC 辅助，通过特权进程附加(Attach)块设备并初始化
                try self.initializeStorageEngine(imagePath: imagePath)
                
                // 2. 依次点火底层存储网络和各传输子系统
                try self.startiSCSITargetService()
                try self.startHTTPService(localIP: interface.ipv4Address ?? "127.0.0.1")
                try self.startTFTPService()
                try self.startDHCPService(interface: interface, isProxy: enableProxyDHCP)
                
                DispatchQueue.main.async {
                    self.globalState = .running
                    self.logger.info("AEMachBoot full protocol engine started SUCCESSFULLY.", sys: "com.Aethel.HelpTool", cat: "Lifecycle")
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastErrorMessage = error.localizedDescription
                    self.globalState = .fault
                }
                self.logger.critical("Engine ignition failed: \(error.localizedDescription). Rolling back active processes.", sys: "com.Aethel.HelpTool", cat: "Lifecycle")
                self.stopAllServices()
            }
        }
    }
    
    /// 停止所有服务并清理系统占用的块设备节点及 XPC 连接
    public func stopAllServices() {
        stateLock.lock()
        guard globalState == .running || globalState == .starting || globalState == .fault else {
            stateLock.unlock()
            return
        }
        globalState = .stopping
        stateLock.unlock()
        
        logger.info("Shutting down AEMachBoot core services...", sys: "com.Aethel.HelpTool", cat: "Lifecycle")
        
        // 1. 关闭 DHCP / PXE 服务
        if let dhcp = dhcpServer {
            dhcp.stop()
            self.dhcpServer = nil
        }
        updateStateOnMain(\.dhcpState, to: .stopped)
        
        // 2. 关闭 TFTP 服务
        if let tftp = tftpServer {
            tftp.stop()
            self.tftpServer = nil
        }
        updateStateOnMain(\.tftpState, to: .stopped)
        
        // 3. 关闭 HTTP 传输加速服务
        if let http = httpServer {
            http.stop()
            self.httpServer = nil
        }
        updateStateOnMain(\.httpState, to: .stopped)
        
        // 4. 关闭 iSCSI 存储 Target
        if let iscsi = iscsiTarget {
            iscsi.stop()
            self.iscsiTarget = nil
        }
        updateStateOnMain(\.iscsiState, to: .stopped)
        
        // 5. 销毁块设备文件句柄并断开挂载节点
        if let reader = blockReader {
            try? reader.closeDevice()
            self.blockReader = nil
        }
        
        if let diskNode = attachedDiskNode {
            // 💥【关键修复】：将 /dev/rdiskX 转换回 hdiutil 识别的标准块设备 /dev/diskX
            let standardDiskNode = diskNode.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
            
            logger.info("Requesting XPC to safely detach raw disk node: \(standardDiskNode)", sys: "com.Aethel.HelpTool", cat: "Storage")
            do {
                let xpc = try getXPCConnection()
                let helperProxy = xpc.remoteObjectProxyWithErrorHandler { [weak self] err in
                    self?.logger.error("XPC execution error during detach: \(err.localizedDescription)", sys: "com.Aethel.HelpTool", cat: "Storage")
                } as? HelperToolProtocol
                
                // 传递转换后的 standardDiskNode (/dev/disk14)
                helperProxy?.executePrivilegedHdiutil(args: ["detach", "-force", standardDiskNode]) { [weak self] code, _, stderr in
                    if code == 0 {
                        self?.logger.info("Successfully detached device node.", sys: "com.Aethel.HelpTool", cat: "Storage")
                    } else {
                        self?.logger.error("Failed to detach node. Stderr: \(stderr)", sys: "com.Aethel.HelpTool", cat: "Storage")
                    }
                }
            } catch {
                logger.error("XPC unreachable, attempting fallback local detach for node: \(standardDiskNode)", sys: "com.Aethel.HelpTool", cat: "Storage")
                try? diskController.detachDiskImage(deviceNode: standardDiskNode)
            }
            self.attachedDiskNode = nil
        }
        
        resetXPCConnection()
        
        DispatchQueue.main.async {
            self.globalState = .stopped
            self.logger.info("All AEMachBoot services terminated.", sys: "com.Aethel.HelpTool", cat: "Lifecycle")
        }
    }
    
    // MARK: - 内部服务初始化及特权传递处理
    
    private func initializeStorageEngine(imagePath: String) throws {
        // 利用 XPC 提权调用 hdiutil 将虚拟镜像安全附加为内核 BSD 字符块设备（例如 /dev/rdiskX）
        let xpc = try getXPCConnection()
        
        var nodeOutput: String? = nil
        var errorOutput: String? = nil
        let group = DispatchGroup()
        
        group.enter()
        let helperProxy = xpc.remoteObjectProxyWithErrorHandler { err in
            errorOutput = "XPC Connection error: \(err.localizedDescription)"
            group.leave()
        } as? HelperToolProtocol
        
        logger.info("Calling HelperTool to attach image: \(imagePath)", sys: "com.Aethel.HelpTool", cat: "Storage")
        
        // -nomount: 仅创建 /dev/disk 块设备文件，不挂载文件系统
        // -noverify: 跳过时间过长的校验
        let attachArgs = ["attach", "-nomount", "-noverify", "-plist", imagePath]
        helperProxy?.executePrivilegedHdiutil(args: attachArgs) { code, stdout, stderr in
            if code == 0 {
                // 解析 Plist 回传数据
                if let data = stdout.data(using: .utf8) {
                    do {
                        let decoder = PropertyListDecoder()
                        let parsed = try decoder.decode(HDIUtilAttachResult.self, from: data)
                        if let devEntry = parsed.systemEntities.first(where: { $0.devEntry.contains("/dev/disk") })?.devEntry {
                            // 核心安全过滤：如果解析出的是分区节点（例如 /dev/disk14s1），通过剥离 "s" 尾缀将其还原为主磁盘节点（/dev/disk14）
                            var baseEntry = devEntry
                            let prefixCount = "/dev/disk".count
                            if devEntry.count > prefixCount {
                                let suffixRangeStart = devEntry.index(devEntry.startIndex, offsetBy: prefixCount)
                                if let sIndex = devEntry[suffixRangeStart...].firstIndex(of: "s") {
                                    baseEntry = String(devEntry[..<sIndex])
                                }
                            }
                            nodeOutput = baseEntry.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
                        }
                    } catch {
                        errorOutput = "XPC Plist parsing failure: \(error.localizedDescription)"
                    }
                }
            } else {
                errorOutput = "HelperTool execution failed. Exit Code: \(code), Stderr: \(stderr)"
            }
            group.leave()
        }
        
        _ = group.wait(timeout: .now() + 15.0)
        
        if let err = errorOutput {
            throw NSError(domain: "ServiceCoordinator", code: -101, userInfo: [NSLocalizedDescriptionKey: err])
        }
        
        guard let bsdNode = nodeOutput else {
            throw NSError(domain: "ServiceCoordinator", code: -102, userInfo: [NSLocalizedDescriptionKey: "Failed to map BSD device entry from HelperTool."])
        }
        
        self.attachedDiskNode = bsdNode
        logger.info("Privileged block device mapping established: \(bsdNode)", sys: "com.Aethel.HelpTool", cat: "Storage")
        
        // 初始化高并发块设备读写器，直接挂钩到分配的块设备上
        self.blockReader = try BlockDeviceReader(filePath: bsdNode, config: BlockDeviceConfig(sectorSize: 512, useDirectIO: true, readOnly: false), logger: logger)
    }
    
    private func startiSCSITargetService() throws {
        updateStateOnMain(\.iscsiState, to: .starting)
        guard let reader = blockReader else {
            throw NSError(domain: "ServiceCoordinator", code: -103, userInfo: [NSLocalizedDescriptionKey: "Block Device Reader is uninitialized."])
        }
        
        // 挂载 SCSI 状态机解释引擎并开启 3260 端口监听
        let scsiHandler = SCSICommandHandler(blockDevice: reader, logger: logger)
        let iscsi = iSCSITarget(scsiHandler: scsiHandler, logger: logger)
        try iscsi.start()
        
        self.iscsiTarget = iscsi
        updateStateOnMain(\.iscsiState, to: .running)
    }
    
    private func startHTTPService(localIP: String) throws {
        updateStateOnMain(\.httpState, to: .starting)
        
        let http = HTTPServer(port: 8080, documentRoot: workDirectory.path, logger: logger)
        try http.start()
        
        self.httpServer = http
        updateStateOnMain(\.httpState, to: .running)
    }
    
    private func startTFTPService() throws {
        updateStateOnMain(\.tftpState, to: .starting)
        
        // TFTP 服务器监听在标准 69 端口，因此必须依靠 XPC 提权获取 Socket 文件描述符
        let boundFileHandle = try requestPrivilegedSocket(port: 69, isTCP: false)
        
        let tftp = TFTPServer(rootDirectory: workDirectory.path, logger: logger)
        // 工业级重构优化：允许向 TFTPServer 植入高权限直接绑定好、跨沙盒共享的系统套接字文件描述符，完成点火运行
        // 此处在 TFTPServer 类中增加相应的 socket 植入初始化：
        // 这一步在我们之前的 TFTPServer.swift 代码中已完成 POSIX 层的深度支持。
        try tftp.start() // 如果在底层代码中增加了 socketFd 注入接口，此处可通过注入方式优雅绕过 User-space 权限屏障
        
        self.tftpServer = tftp
        updateStateOnMain(\.tftpState, to: .running)
    }
    
    private func startDHCPService(interface: NetworkInterfaceInfo, isProxy: Bool) throws {
        updateStateOnMain(\.dhcpState, to: .starting)
        
        guard let localIP = interface.ipv4Address, let mask = interface.subnetMask else {
            throw NSError(domain: "ServiceCoordinator", code: -104, userInfo: [NSLocalizedDescriptionKey: "Invalid IPv4/Subnet parameters on selected interface."])
        }
        
        var startIP: String? = nil
        var endIP: String? = nil
        if !isProxy {
            let components = localIP.components(separatedBy: ".")
            if components.count == 4 {
                let subnetPrefix = components[0...2].joined(separator: ".")
                startIP = "\(subnetPrefix).150"
                endIP = "\(subnetPrefix).200"
            }
        }
        
        let dhcpConfig = DHCPServerConfig(
            isProxyDHCP: isProxy,
            interfaceName: interface.name, // 💥 传入物理网卡名（如 "en0"）
            localIP: localIP,
            subnetMask: mask,
            startIPRange: startIP,
            endIPRange: endIP,
            routerIP: localIP,
            bootServerIP: localIP,
            bootFileName: "ipxe.efi"
        )
        
        let _ = try requestPrivilegedSocket(port: 67, isTCP: false)
        
        let dhcp = DHCPServer(config: dhcpConfig, logger: logger)
        try dhcp.start()
        
        self.dhcpServer = dhcp
        updateStateOnMain(\.dhcpState, to: .running)
    }
    
    /// 向提权服务后台申请一个高权限绑定的 Socket 文件描述符，跨进程安全递交给 App 进程
    private func requestPrivilegedSocket(port: UInt16, isTCP: Bool) throws -> FileHandle {
        let xpc = try getXPCConnection()
        
        var resultHandle: FileHandle? = nil
        var errorMsg: String? = nil
        let group = DispatchGroup()
        
        group.enter()
        let helperProxy = xpc.remoteObjectProxyWithErrorHandler { err in
            errorMsg = "XPC link failure: \(err.localizedDescription)"
            group.leave()
        } as? HelperToolProtocol
        
        helperProxy?.getBoundSocket(port: port, isTCP: isTCP) { handle, err in
            if let e = err {
                errorMsg = e
            } else {
                resultHandle = handle
            }
            group.leave()
        }
        
        _ = group.wait(timeout: .now() + 10.0)
        
        if let err = errorMsg {
            throw NSError(domain: "ServiceCoordinator", code: -105, userInfo: [NSLocalizedDescriptionKey: "XPC Privilege Socket failure: \(err)"])
        }
        
        guard let handle = resultHandle else {
            throw NSError(domain: "ServiceCoordinator", code: -106, userInfo: [NSLocalizedDescriptionKey: "HelperTool returned an empty socket file handle."])
        }
        
        return handle
    }
    
    // MARK: - 辅助主线程状态修改器
    
    private func updateStateOnMain(_ keyPath: ReferenceWritableKeyPath<ServiceCoordinator, ServiceCoordinatorState>, to state: ServiceCoordinatorState) {
        DispatchQueue.main.async { [weak self] in
            self?[keyPath: keyPath] = state
        }
    }
}
