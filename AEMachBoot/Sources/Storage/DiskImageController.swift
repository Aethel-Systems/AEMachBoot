import Foundation

/// 磁盘镜像控制错误类型
public enum DiskImageError: Error, LocalizedError {
    case creationFailed(String)
    case attachmentFailed(String)
    case detachmentFailed(String)
    case executionTimeout(String)
    case plistParsingFailed(String)
    case invalidResponse(String)
    case subprocessError(exitCode: Int32, stderr: String)
    
    public var errorDescription: String? {
        switch self {
        case .creationFailed(let reason):
            return "Failed to create disk image: \(reason)"
        case .attachmentFailed(let reason):
            return "Failed to attach disk image: \(reason)"
        case .detachmentFailed(let reason):
            return "Failed to detach disk image: \(reason)"
        case .executionTimeout(let command):
            return "Command execution timed out: \(command)"
        case .plistParsingFailed(let detail):
            return "Failed to parse XML Plist response from hdiutil: \(detail)"
        case .invalidResponse(let info):
            return "hdiutil returned unexpected or empty output: \(info)"
        case .subprocessError(let exitCode, let stderr):
            return "Subprocess terminated with non-zero exit code (\(exitCode)). Stderr: \(stderr)"
        }
    }
}

/// 挂载信息映射结构，用于解析 hdiutil attach -plist 输出
public struct HDIUtilAttachResult: Codable, Sendable {
    public struct SystemEntity: Codable, Sendable {
        public let contentHint: String?
        public let devEntry: String
        public let potentiallyMountable: Bool?
        public let volumeKind: String?
        
        enum CodingKeys: String, CodingKey {
            case contentHint = "content-hint"
            case devEntry = "dev-entry"
            case potentiallyMountable = "potentially-mountable"
            case volumeKind = "volume-kind"
        }
    }
    
    public let systemEntities: [SystemEntity]
    
    enum CodingKeys: String, CodingKey {
        case systemEntities = "system-entities"
    }
}

/// 工业级 macOS 磁盘镜像管理器
public final class DiskImageController: @unchecked Sendable {
    private let lock = NSLock()
    private let logger: AEMachLogger
    private let helperToolPath = "/usr/bin/hdiutil"
    
    public init(logger: AEMachLogger = .shared) {
        self.logger = logger
    }
    
    private func executeSubprocess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 60.0
    ) throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        try process.run()
        
        let writeGroup = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        
        writeGroup.enter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                writeGroup.leave()
            } else {
                stdoutData.append(d)
            }
        }
        
        writeGroup.enter()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                writeGroup.leave()
            } else {
                stderrData.append(d)
            }
        }
        
        let timeoutResult = writeGroup.wait(timeout: .now() + timeout)
        if timeoutResult == .timedOut {
            process.terminate()
            throw DiskImageError.executionTimeout("\(executable) \(arguments.joined(separator: " "))")
        }
        
        process.waitUntilExit()
        let exitCode = process.terminationStatus
        let stderrString = String(data: stderrData, encoding: .utf8) ?? "Unreadable error stream"
        
        return (stdout: stdoutData, stderr: stderrString, exitCode: exitCode)
    }
    
    /// 1. 创建全新的空白 RAW 磁盘镜像
    public func createBlankDiskImage(
        atPath path: String,
        sizeInBytes: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        
        logger.info("Creating blank raw disk image at \(path) (Size: \(sizeInBytes) bytes)", sys: "com.aemachboot.storage", cat: "DiskImage")
        
        let parentDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
        
        let sizeArgument = "\(sizeInBytes)b"
        let args = [
            "create",
            "-size", sizeArgument,
            "-ov",
            "-layout", "NONE",
            "-type", "RAW", // 修正：创建空白盘使用 -type RAW 替代 -format UDTO
            path
        ]
        
        let result = try executeSubprocess(executable: helperToolPath, arguments: args, timeout: 60.0)
        guard result.exitCode == 0 else {
            logger.error("Failed to create blank disk. Error: \(result.stderr)", sys: "com.aemachboot.storage", cat: "DiskImage")
            throw DiskImageError.subprocessError(exitCode: result.exitCode, stderr: result.stderr)
        }
    }
    
    /// 2. 从已有系统文件夹创建 RAW 引导系统盘
    public func createDiskImageFromFolder(
        atPath path: String,
        srcFolderPath: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        
        logger.info("Creating raw bootable disk image from source folder: \(srcFolderPath)", sys: "com.aemachboot.storage", cat: "DiskImage")
        
        let parentDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
        
        // hdiutil 生成 UDTO (DVD/CD Master) 格式时，会自动追加 .cdr 后缀，所以我们要生成临时文件并重命名
        let tempCdrPath = path + ".cdr"
        let args = [
            "create",
            "-srcfolder", srcFolderPath,
            "-ov",
            "-format", "UDTO", // DVD/CD Master 格式本质就是标准 RAW 扇区镜像
            tempCdrPath
        ]
        
        let result = try executeSubprocess(executable: helperToolPath, arguments: args, timeout: 180.0)
        guard result.exitCode == 0 else {
            logger.error("Failed to create disk from folder. Error: \(result.stderr)", sys: "com.aemachboot.storage", cat: "DiskImage")
            throw DiskImageError.subprocessError(exitCode: result.exitCode, stderr: result.stderr)
        }
        
        // 重命名 .cdr 文件为 .img 引导镜像
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        try fileManager.moveItem(atPath: tempCdrPath, toPath: path)
        logger.info("Successfully packed and converted bootable system disk to RAW format: \(path)", sys: "com.aemachboot.storage", cat: "DiskImage")
    }
    
    /// 3. 将镜像挂载附加（Attach）
    public func attachDiskImage(atPath path: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        
        logger.info("Attaching disk image: \(path)", sys: "com.aemachboot.storage", cat: "DiskImage")
        
        let args = [
            "attach",
            "-nomount",
            "-noverify",
            "-plist",
            path
        ]
        
        let result = try executeSubprocess(executable: helperToolPath, arguments: args, timeout: 30.0)
        guard result.exitCode == 0 else {
            logger.error("Failed to attach disk image. Stderr: \(result.stderr)", sys: "com.aemachboot.storage", cat: "DiskImage")
            throw DiskImageError.subprocessError(exitCode: result.exitCode, stderr: result.stderr)
        }
        
        do {
            let decoder = PropertyListDecoder()
            let parsed = try decoder.decode(HDIUtilAttachResult.self, from: result.stdout)
            
            guard let primaryEntity = parsed.systemEntities.first(where: { $0.devEntry.contains("/dev/disk") }) else {
                throw DiskImageError.invalidResponse("No active BSD partition or dev-entry found in hdiutil output structure.")
            }
            
            let standardDeviceNode = primaryEntity.devEntry

            // 核心安全过滤：剥离可能产生的分区尾缀（例如 /dev/disk14s1 -> /dev/disk14）
            var baseDeviceNode = standardDeviceNode
            let prefixCount = "/dev/disk".count
            if standardDeviceNode.count > prefixCount {
                let suffixRangeStart = standardDeviceNode.index(standardDeviceNode.startIndex, offsetBy: prefixCount)
                if let sIndex = standardDeviceNode[suffixRangeStart...].firstIndex(of: "s") {
                    baseDeviceNode = String(standardDeviceNode[..<sIndex])
                }
            }

            // 转为高性能字符原始块设备路径，如 /dev/disk14 -> /dev/rdisk14
            let rawDeviceNode = baseDeviceNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
            return rawDeviceNode
        } catch {
            logger.error("Failed to parse plist: \(error.localizedDescription)", sys: "com.aemachboot.storage", cat: "DiskImage")
            throw DiskImageError.plistParsingFailed(error.localizedDescription)
        }
    }
    
    /// 4. 卸载磁盘
    public func detachDiskImage(deviceNode: String) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let formattedNode = deviceNode.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
        let args = [
            "detach",
            "-force",
            formattedNode
        ]
        
        let result = try executeSubprocess(executable: helperToolPath, arguments: args, timeout: 15.0)
        guard result.exitCode == 0 else {
            logger.error("Failed to detach disk: \(formattedNode). Error: \(result.stderr)", sys: "com.aemachboot.storage", cat: "DiskImage")
            throw DiskImageError.subprocessError(exitCode: result.exitCode, stderr: result.stderr)
        }
    }
}
