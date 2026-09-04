import Foundation

/// 针对底层 macOS 块设备及大型镜像文件设计的工业级错误处理机制
public enum BlockDeviceError: Error, LocalizedError {
    case invalidPath(String)
    case permissionDenied(String)
    case fileNotFound(String)
    case diskFull
    case alignmentViolation(offset: Int64, alignment: UInt32)
    case systemCallError(functionName: String, errnoValue: Int32, explanation: String)
    case readFailure(offset: Int64, bytesRequested: Int, bytesRead: Int)
    case writeFailure(offset: Int64, bytesRequested: Int, bytesWritten: Int)
    case fileClosed
    case deviceIoctlFailed(String)
    case invalidSectors(requested: Int, limit: Int)
    
    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "The specified path is invalid: \(path)"
        case .permissionDenied(let detail):
            return "Permission denied: \(detail)"
        case .fileNotFound(let path):
            return "Target image file or block device not found: \(path)"
        case .diskFull:
            return "Write operation failed: Host storage disk is full."
        case .alignmentViolation(let offset, let alignment):
            return "Disk alignment error: Offset \(offset) must be a multiple of sector size \(alignment)."
        case .systemCallError(let functionName, let errnoValue, let explanation):
            let errString = String(cString: strerror(errnoValue))
            return "Underlying system call failed in '\(functionName)' (Errno: \(errnoValue) - \(errString)). Context: \(explanation)"
        case .readFailure(let offset, let requested, let read):
            return "I/O Read Discrepancy: Attempted to read \(requested) bytes at offset \(offset), but only obtained \(read) bytes."
        case .writeFailure(let offset, let requested, let written):
            return "I/O Write Discrepancy: Attempted to write \(requested) bytes at offset \(offset), but successfully wrote only \(written) bytes."
        case .fileClosed:
            return "The raw file descriptor has been closed; no I/O operations are permitted."
        case .deviceIoctlFailed(let reason):
            return "macOS specific DKIOC Ioctl failed: \(reason)"
        case .invalidSectors(let requested, let limit):
            return "Sector out-of-bounds error: Requested sector \(requested), maximum logical block limit is \(limit)."
        }
    }
}

/// 块设备配置参数体系
public struct BlockDeviceConfig: Sendable {
    /// 标准存储扇区大小（Legacy: 512, Advanced Format: 4096）
    public let sectorSize: UInt32
    /// 强制执行直接 I/O，绕过系统的 Page Cache。
    /// 当目标是物理盘或 /dev/rdisk 设备时必须为 true，以防止 macOS 系统缓冲引发的写并发延迟不一致。
    public let useDirectIO: Bool
    /// 是否以只读方式打开块设备文件
    public let readOnly: Bool
    
    public init(sectorSize: UInt32 = 512, useDirectIO: Bool = true, readOnly: Bool = false) {
        self.sectorSize = sectorSize
        self.useDirectIO = useDirectIO
        self.readOnly = readOnly
    }
}

/// 工业级高并发块设备读写器
/// 使用原生 POSIX `pread` / `pwrite` 并在内核层支持无锁并行并发读取、串行同步写入设计。
public final class BlockDeviceReader: @unchecked Sendable {
    private var fileDescriptor: Int32 = -1
    private let filePath: String
    private let config: BlockDeviceConfig
    
    // 底层并行控制机制：多核无阻碍并发度，单一序列化写入，确保绝对的文件指针不漂移及状态一致性
    private var rwLock = pthread_rwlock_t()
    
    private var totalSectors: UInt64 = 0
    private var isClosed: Bool = false
    
    private let logger: AEMachLogger
    
    /// 初始化 BlockDeviceReader 实例并立即绑定底层 POSIX 资源。
    /// - Parameters:
    ///   - filePath: 镜像路径或 BSD 块设备路径（如：`/dev/rdisk5` 强烈建议使用含有 'r' 的 Raw 设备字符设备以大幅提高吞吐性能）
    ///   - config: 读写参数配置
    ///   - logger: 系统日志实例
    public init(filePath: String, config: BlockDeviceConfig = BlockDeviceConfig(), logger: AEMachLogger = .shared) throws {
        self.filePath = filePath
        self.config = config
        self.logger = logger
        
        var rc = pthread_rwlock_init(&rwLock, nil)
        if rc != 0 {
            throw BlockDeviceError.systemCallError(
                functionName: "pthread_rwlock_init",
                errnoValue: rc,
                explanation: "Could not allocate system resources for read-write barrier lock."
            )
        }
        
        try openDevice()
    }
    
    deinit {
        try? closeDevice()
        pthread_rwlock_destroy(&rwLock)
    }
    
    private func openDevice() throws {
        var flags = config.readOnly ? O_RDONLY : O_RDWR
        
        // 必须不带 O_CREAT，因为本模块专注于已有存储卷的高速块设备读写；创建职责应当属于磁盘管理器。
        // 若使用 O_CLOEXEC 规避子进程文件描述符泄漏
        flags |= O_CLOEXEC
        
        let fd = open(filePath, flags)
        if fd < 0 {
            let err = errno
            logger.error("Failed to open block device path: \(filePath). OS Error Code: \(err)", sys: "com.aemachboot.storage", cat: "DiskIO")
            switch err {
            case ENOENT:
                throw BlockDeviceError.fileNotFound(filePath)
            case EACCES, EPERM:
                throw BlockDeviceError.permissionDenied("Read/Write permission required for device '\(filePath)'. Check file POSIX attributes.")
            default:
                throw BlockDeviceError.systemCallError(functionName: "open", errnoValue: err, explanation: "Open failed on path: \(filePath)")
            }
        }
        
        self.fileDescriptor = fd
        
        // 控制是否绕过 macOS 虚拟内存层的缓存。
        // 这对 iSCSI 无盘启动极其关键：操作系统在网络启动时期望绝对的盘块落盘同步，
        // 绕过内核缓存避免数据在非预期时段暂存在系统 RAM 造成不一致。
        if config.useDirectIO {
            if fcntl(fd, F_NOCACHE, 1) == -1 {
                let err = errno
                logger.warn("Unable to apply F_NOCACHE to: \(filePath). Error code: \(err). Continuing without direct system-bypass cache mechanism.", sys: "com.aemachboot.storage", cat: "DiskIO")
            } else {
                logger.debug("Successfully configured F_NOCACHE (Direct I/O) on device: \(filePath)", sys: "com.aemachboot.storage", cat: "DiskIO")
            }
        }
        
        try calculateSectors()
    }
    
    private func calculateSectors() throws {
        var fileStats = stat()
        if fstat(fileDescriptor, &fileStats) != 0 {
            let err = errno
            throw BlockDeviceError.systemCallError(functionName: "fstat", errnoValue: err, explanation: "Failed to gather metrics for handle.")
        }
        
        let fileType = fileStats.st_mode & S_IFMT
        if fileType == S_IFCHR || fileType == S_IFBLK {
            var sectorCount: UInt64 = 0
            var sectorSize: UInt32 = 0
            
            // ✅ 修正 macOS 正确的 IOCTL 魔数 (_IOR('d', 24, uint32_t))
            let DKIOCGETBLOCKSIZE: UInt = 0x40046418
            if ioctl(fileDescriptor, DKIOCGETBLOCKSIZE, &sectorSize) == 0 && sectorSize > 0 {
                logger.info("macOS Device IOCTL reported Sector Size: \(sectorSize) bytes.", sys: "com.aemachboot.storage", cat: "DiskIO")
            } else {
                sectorSize = config.sectorSize
                logger.warn("macOS IOCTL DKIOCGETBLOCKSIZE failed. Defaulting target to default alignment: \(sectorSize)", sys: "com.aemachboot.storage", cat: "DiskIO")
            }
            
            // ✅ 修正 macOS 正确的 IOCTL 魔数 (_IOR('d', 25, uint64_t))
            let DKIOCGETBLOCKCOUNT: UInt = 0x40086419
            if ioctl(fileDescriptor, DKIOCGETBLOCKCOUNT, &sectorCount) == 0 && sectorCount > 0 {
                self.totalSectors = sectorCount
                logger.info("macOS Device IOCTL reported Total Sector Count: \(sectorCount) sectors (\((Double(sectorCount * UInt64(sectorSize)) / 1024.0 / 1024.0 / 1024.0)) GB).", sys: "com.aemachboot.storage", cat: "DiskIO")
            } else {
                // 兜底 1：尝试直接读取原镜像文件 (.img) 的 stat 文件大小
                var origStats = stat()
                if stat(filePath, &origStats) == 0 && origStats.st_size > 0 {
                    self.totalSectors = UInt64(origStats.st_size) / UInt64(sectorSize)
                    logger.info("Retrieved disk size from underlying image stat: \(origStats.st_size) bytes (\(totalSectors) sectors).", sys: "com.aemachboot.storage", cat: "DiskIO")
                } else {
                    // 兜底 2：尝试 lseek
                    let size = lseek(fileDescriptor, 0, SEEK_END)
                    if size > 0 {
                        self.totalSectors = UInt64(size) / UInt64(sectorSize)
                        _ = lseek(fileDescriptor, 0, SEEK_SET)
                    } else {
                        throw BlockDeviceError.deviceIoctlFailed("Cannot determine total block layout parameters via IOCTL or raw seek operations.")
                    }
                }
            }
        } else {
            let fileSizeBytes = UInt64(fileStats.st_size)
            self.totalSectors = fileSizeBytes / UInt64(config.sectorSize)
            logger.info("Target is virtual image file. Size: \(fileSizeBytes) bytes (\(totalSectors) sectors at \(config.sectorSize) bytes each).", sys: "com.aemachboot.storage", cat: "DiskIO")
        }
    }
    
    /// 关闭底层文件描述符并彻底释放系统占用资源
    public func closeDevice() throws {
        pthread_rwlock_wrlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        
        guard !isClosed else { return }
        
        if fileDescriptor >= 0 {
            // 写入缓冲区未落盘数据至持久化介质，保证数据完整性
            _ = fsync(fileDescriptor)
            
            if close(fileDescriptor) != 0 {
                let err = errno
                isClosed = true
                fileDescriptor = -1
                throw BlockDeviceError.systemCallError(functionName: "close", errnoValue: err, explanation: "Failed to release lock on file descriptor cleanly.")
            }
        }
        
        isClosed = true
        fileDescriptor = -1
        logger.info("Successfully closed and released lock for device: \(filePath)", sys: "com.aemachboot.storage", cat: "DiskIO")
    }
    
    /// 核心公共接口：并发读取块设备
    /// - Parameters:
    ///   - startSector: 起始逻辑扇区 (LBA)
    ///   - sectorCount: 欲读取的连续扇区数量
    /// - Returns: 返回完整的原始 Data 二进制流
    public func readSectors(at startSector: UInt64, count sectorCount: UInt32) throws -> Data {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        
        guard !isClosed else { throw BlockDeviceError.fileClosed }
        
        // 边界条件防御与越界检测
        if startSector + UInt64(sectorCount) > totalSectors {
            throw BlockDeviceError.invalidSectors(requested: Int(startSector + UInt64(sectorCount)), limit: Int(totalSectors))
        }
        
        let byteOffset = Int64(startSector * UInt64(config.sectorSize))
        let totalBytesToRead = Int(sectorCount * config.sectorSize)
        
        // 对齐合法性检测
        if byteOffset % Int64(config.sectorSize) != 0 {
            throw BlockDeviceError.alignmentViolation(offset: byteOffset, alignment: config.sectorSize)
        }
        
        // 分配对齐的底层 C 缓冲区指针 (对于 O_NOCACHE，macOS 内核有些场景要求缓冲区地址按 512 字节对齐)
        var buffer: UnsafeMutableRawPointer? = nil
        let alignment = Int(config.sectorSize)
        let posixAllocStatus = posix_memalign(&buffer, alignment, totalBytesToRead)
        
        guard posixAllocStatus == 0, let allocatedBuffer = buffer else {
            throw BlockDeviceError.systemCallError(
                functionName: "posix_memalign",
                errnoValue: posixAllocStatus,
                explanation: "Failed to allocate memory buffer with alignment constraint of \(alignment) bytes."
            )
        }
        
        defer { free(allocatedBuffer) }
        
        // 调用底层的原子定位读取 pread(2)，不改变文件偏移指针，从而提供安全的、无需额外加锁的多线程读取。
        let bytesRead = pread(fileDescriptor, allocatedBuffer, totalBytesToRead, byteOffset)
        
        if bytesRead < 0 {
            let err = errno
            logger.error("POSIX pread system call failed at offset: \(byteOffset). Size: \(totalBytesToRead) bytes. Errno: \(err)", sys: "com.aemachboot.storage", cat: "DiskIO")
            throw BlockDeviceError.systemCallError(functionName: "pread", errnoValue: err, explanation: "Failure on raw disk cluster read.")
        }
        
        if bytesRead != totalBytesToRead {
            logger.error("POSIX pread returned incomplete byte frame. Requested: \(totalBytesToRead), Read: \(bytesRead)", sys: "com.aemachboot.storage", cat: "DiskIO")
            throw BlockDeviceError.readFailure(offset: byteOffset, bytesRequested: totalBytesToRead, bytesRead: bytesRead)
        }
        
        // 将底层缓冲区包装为 Swift 的物理二进制实体 Data
        return Data(bytes: allocatedBuffer, count: totalBytesToRead)
    }
    
    /// 核心公共接口：同步串行安全写入块设备
    /// - Parameters:
    ///   - startSector: 起始逻辑扇区 (LBA)
    ///   - data: 待写入的二进制包。字节数必须为 `config.sectorSize` 的正整数倍。
    public func writeSectors(at startSector: UInt64, data: Data) throws {
        pthread_rwlock_wrlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        
        guard !isClosed else { throw BlockDeviceError.fileClosed }
        if config.readOnly {
            throw BlockDeviceError.permissionDenied("Block device was mounted as read-only. Write actions are blocked internally.")
        }
        
        let totalBytesToWrite = data.count
        guard totalBytesToWrite % Int(config.sectorSize) == 0 else {
            throw BlockDeviceError.alignmentViolation(offset: Int64(totalBytesToWrite), alignment: config.sectorSize)
        }
        
        let sectorDelta = UInt64(totalBytesToWrite) / UInt64(config.sectorSize)
        
        // 边界保护
        if startSector + sectorDelta > totalSectors {
            throw BlockDeviceError.invalidSectors(requested: Int(startSector + sectorDelta), limit: Int(totalSectors))
        }
        
        let byteOffset = Int64(startSector * UInt64(config.sectorSize))
        
        // 分配对齐的底层物理写入暂存区，拷贝 Swift 的 Data 原始内存。
        var buffer: UnsafeMutableRawPointer? = nil
        let alignment = Int(config.sectorSize)
        let posixAllocStatus = posix_memalign(&buffer, alignment, totalBytesToWrite)
        
        guard posixAllocStatus == 0, let allocatedBuffer = buffer else {
            throw BlockDeviceError.systemCallError(
                functionName: "posix_memalign",
                errnoValue: posixAllocStatus,
                explanation: "Failed to allocate page-aligned write block of size \(totalBytesToWrite) bytes."
            )
        }
        
        defer { free(allocatedBuffer) }
        
        // 将 Data 数据高速平铺拷贝到 C 指针区域
        data.copyBytes(to: allocatedBuffer.assumingMemoryBound(to: UInt8.self), count: totalBytesToWrite)
        
        // 调用系统的 pwrite 写入内核态
        let bytesWritten = pwrite(fileDescriptor, allocatedBuffer, totalBytesToWrite, byteOffset)
        
        if bytesWritten < 0 {
            let err = errno
            logger.error("POSIX pwrite system call failed at offset: \(byteOffset). Errno: \(err)", sys: "com.aemachboot.storage", cat: "DiskIO")
            if err == ENOSPC {
                throw BlockDeviceError.diskFull
            }
            throw BlockDeviceError.systemCallError(functionName: "pwrite", errnoValue: err, explanation: "Disk drive write operation system block.")
        }
        
        if bytesWritten != totalBytesToWrite {
            logger.error("POSIX pwrite returned incomplete frame. Requested: \(totalBytesToWrite), successfully written: \(bytesWritten)", sys: "com.aemachboot.storage", cat: "DiskIO")
            throw BlockDeviceError.writeFailure(offset: byteOffset, bytesRequested: totalBytesToWrite, bytesWritten: bytesWritten)
        }
    }
    
    /// 元数据获取：获取整个虚拟卷磁盘总大小 (Bytes)
    public var sizeInBytes: UInt64 {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        return totalSectors * UInt64(config.sectorSize)
    }
    
    /// 元数据获取：获取逻辑扇区总量
    public var sectorCount: UInt64 {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        return totalSectors
    }
    
    /// 元数据获取：单个扇区大小
    public var sectorSize: UInt32 {
        return config.sectorSize
    }

    /// 强行将内核写入缓冲区的数据同步落盘至物理介质（Synchronize Cache）
    public func flush() throws {
        pthread_rwlock_wrlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        
        guard !isClosed else { throw BlockDeviceError.fileClosed }
        
        if fileDescriptor >= 0 {
            if fsync(fileDescriptor) != 0 {
                let err = errno
                throw BlockDeviceError.systemCallError(
                    functionName: "fsync",
                    errnoValue: err,
                    explanation: "Failed to synchronize storage cache and force blocks to disk."
                )
            }
        }
    }
}
