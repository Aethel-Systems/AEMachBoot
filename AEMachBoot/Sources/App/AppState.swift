import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
public final class AppState: ObservableObject {
    
    public let coordinator: ServiceCoordinator
    private let interfaceManager: NetworkInterfaceManager
    private var cancellables = Set<AnyCancellable>()
    
    @Published public var globalState: ServiceCoordinatorState = .stopped
    @Published public var dhcpState: ServiceCoordinatorState = .stopped
    @Published public var tftpState: ServiceCoordinatorState = .stopped
    @Published public var httpState: ServiceCoordinatorState = .stopped
    @Published public var iscsiState: ServiceCoordinatorState = .stopped
    
    @Published public var availableInterfaces: [NetworkInterfaceInfo] = []
    @Published public var selectedInterfaceID: String = ""
    @Published public var isProxyDHCP: Bool = true
    @Published public var selectedImagePath: String = ""
    @Published public var availableImages: [URL] = []
    
    @Published public var logConsoleLines: [String] = []
    @Published var logSearchQuery: String = ""
    @Published var selectedLogLevelFilter: AELogLevel = .trace
    
    // 创建虚拟磁盘镜像的表单状态
    @Published public var newImageName: String = "diskless_windows_11"
    @Published public var newImageSizeGB: Int = 64
    @Published public var isCreatingDisk: Bool = false
    @Published public var diskCreationError: String? = nil
    
    // 新增：可选的系统源文件夹，打包为引导系统盘使用
    @Published public var selectedSourceFolderPath: String = ""
    
    public init(coordinator: ServiceCoordinator = ServiceCoordinator()) {
        self.coordinator = coordinator
        self.interfaceManager = NetworkInterfaceManager()
        
        setupStateBindings()
        refreshInterfaces()
        scanForImages()
        setupLogCapture()
    }
    
    private func setupStateBindings() {
        coordinator.$globalState
            .receive(on: RunLoop.main)
            .assign(to: \.globalState, on: self)
            .store(in: &cancellables)
            
        coordinator.$dhcpState
            .receive(on: RunLoop.main)
            .assign(to: \.dhcpState, on: self)
            .store(in: &cancellables)
            
        coordinator.$tftpState
            .receive(on: RunLoop.main)
            .assign(to: \.tftpState, on: self)
            .store(in: &cancellables)
            
        coordinator.$httpState
            .receive(on: RunLoop.main)
            .assign(to: \.httpState, on: self)
            .store(in: &cancellables)
            
        coordinator.$iscsiState
            .receive(on: RunLoop.main)
            .assign(to: \.iscsiState, on: self)
            .store(in: &cancellables)
    }
    
    private func setupLogCapture() {
        let uiDestination = BlockLogDestination { [weak self] event in
            guard let self = self else { return }
            let fileName = event.file.components(separatedBy: "/").last ?? "Unknown"
            let formattedLine = "[\(event.level.description)] [\(fileName):\(event.line)] \(event.message)"
            
            DispatchQueue.main.async {
                self.logConsoleLines.append(formattedLine)
                if self.logConsoleLines.count > 1000 {
                    self.logConsoleLines.removeFirst()
                }
            }
        }
        uiDestination.minimumLevel = .trace
        AEMachLogger.shared.addDestination(uiDestination)
    }
    
    // MARK: - 业务接口
    
    public func refreshInterfaces() {
        self.availableInterfaces = interfaceManager.retrieveActiveInterfaces()
        if let first = availableInterfaces.first(where: { $0.isUp && !$0.isLoopback }) {
            self.selectedInterfaceID = first.id
        }
    }
    
    public func scanForImages() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let imageDirectory = appSupport.appendingPathComponent("AEMachBoot/DiskImages")
        
        // 确保目录存在
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true, attributes: nil)
        
        // 扫描系统目录
        if let urls = try? FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil) {
            var newSet = Set(self.availableImages) // 保持当前已有的（包括手动导入的）
            let found = urls.filter { $0.pathExtension == "img" }
            newSet.formUnion(found)
            self.availableImages = Array(newSet)
        }
    }
    
    /// 新增：浏览并选择本地系统/安装源文件夹
    public func selectSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Source Folder"
        
        if panel.runModal() == .OK, let url = panel.url {
            self.selectedSourceFolderPath = url.path
        }
    }
    
    /// 新增：打开并选择外部任意位置的 .img 系统镜像文件（支持打开）
    public func importImageViaFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        
        // 修正：动态通过扩展名生成 UTType，确保 100% 编译通过并精准过滤 .img 文件
        let imgType = UTType(filenameExtension: "img") ?? .data
        panel.allowedContentTypes = [imgType, .data]
        panel.prompt = "Open System Image"
        
        if panel.runModal() == .OK, let url = panel.url {
            if !availableImages.contains(url) {
                self.availableImages.append(url)
            }
            self.selectedImagePath = url.path
            AEMachLogger.shared.info("Opened external system image: \(url.path)", sys: "com.aemachboot.ui", cat: "Actions")
        }
    }
    
    public func toggleServices() {
        if globalState == .running {
            coordinator.stopAllServices()
        } else {
            guard let interface = availableInterfaces.first(where: { $0.id == selectedInterfaceID }) else {
                AEMachLogger.shared.error("Ignition failed: No active physical network interface selected.", sys: "com.aemachboot.ui", cat: "Actions")
                return
            }
            guard !selectedImagePath.isEmpty else {
                AEMachLogger.shared.error("Ignition failed: No virtual disk image (.img) selected.", sys: "com.aemachboot.ui", cat: "Actions")
                return
            }
            coordinator.startAllServices(interface: interface, imagePath: selectedImagePath, enableProxyDHCP: isProxyDHCP)
        }
    }
    
    /// 重构：支持“空白创建”和“文件夹打包创建”两种模式
    public func createDiskImage() {
        guard !newImageName.isEmpty else { return }
        isCreatingDisk = true
        diskCreationError = nil
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let imageDirectory = appSupport.appendingPathComponent("AEMachBoot/DiskImages")
        let targetURL = imageDirectory.appendingPathComponent("\(newImageName).img")
        
        let sizeInBytes = UInt64(newImageSizeGB) * 1024 * 1024 * 1024
        let srcFolder = selectedSourceFolderPath
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let diskController = DiskImageController()
            
            do {
                if !srcFolder.isEmpty {
                    // 1. 如果指定了文件夹，直接转换为引导系统盘
                    try diskController.createDiskImageFromFolder(atPath: targetURL.path, srcFolderPath: srcFolder)
                } else {
                    // 2. 如果文件夹为空，则直接创建指定容量大小的空白盘
                    try diskController.createBlankDiskImage(atPath: targetURL.path, sizeInBytes: sizeInBytes)
                }
                
                DispatchQueue.main.async {
                    self.isCreatingDisk = false
                    self.selectedSourceFolderPath = ""
                    self.scanForImages()
                    self.selectedImagePath = targetURL.path
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCreatingDisk = false
                    self.diskCreationError = error.localizedDescription
                }
            }
        }
    }
    
    public func clearLogs() {
        self.logConsoleLines.removeAll()
    }
}

private final class BlockLogDestination: LogDestination, @unchecked Sendable {
    var minimumLevel: AELogLevel = .trace
    let onLog: @Sendable (LogEvent) -> Void
    
    init(onLog: @escaping @Sendable (LogEvent) -> Void) {
        self.onLog = onLog
    }
    
    func write(event: LogEvent) {
        guard event.level >= minimumLevel else { return }
        onLog(event)
    }
}
