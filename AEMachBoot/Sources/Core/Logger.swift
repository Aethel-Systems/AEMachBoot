import Foundation
import os.log

/// 表示 AEMachBoot 系统的日志级别
public enum AELogLevel: Int, Comparable, Sendable, CustomStringConvertible {
    case trace = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case critical = 5
    
    public var description: String {
        switch self {
        case .trace:    return "TRACE"
        case .debug:    return "DEBUG"
        case .info:     return "INFO"
        case .warning:  return "WARN"
        case .error:    return "ERROR"
        case .critical: return "FATAL"
        }
    }
    
    public var osLogType: OSLogType {
        switch self {
        case .trace, .debug: return .debug
        case .info:          return .info
        case .warning:       return .default
        case .error:         return .error
        case .critical:      return .fault
        }
    }
    
    public static func < (lhs: AELogLevel, rhs: AELogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// 封装单条日志元数据的结构体
public struct LogEvent: @unchecked Sendable {
    public let timestamp: Date
    public let level: AELogLevel
    public let message: String
    public let file: String
    public let function: String
    public let line: Int
    public let threadId: UInt64
    public let subsystem: String
    public let category: String
    
    public init(
        level: AELogLevel,
        message: String,
        file: String,
        function: String,
        line: Int,
        subsystem: String,
        category: String
    ) {
        self.timestamp = Date()
        self.level = level
        self.message = message
        self.file = file
        self.function = function
        self.line = line
        self.subsystem = subsystem
        self.category = category
        
        var tid: __uint64_t = 0
        pthread_threadid_np(nil, &tid)
        self.threadId = tid
    }
}

/// 日志输出目的地接口
public protocol LogDestination: Sendable {
    var minimumLevel: AELogLevel { get set }
    func write(event: LogEvent)
}

/// 目的地 1: Apple 原生统一日志系统 (OSLog)
public final class OSLogDestination: LogDestination, @unchecked Sendable {
    public var minimumLevel: AELogLevel
    private let lock = NSLock()
    private var loggers: [String: os.Logger] = [:]
    
    public init(minimumLevel: AELogLevel = .info) {
        self.minimumLevel = minimumLevel
    }
    
    public func write(event: LogEvent) {
        guard event.level >= minimumLevel else { return }
        
        let loggerKey = "\(event.subsystem).\(event.category)"
        
        lock.lock()
        let logger: os.Logger
        if let existing = loggers[loggerKey] {
            logger = existing
        } else {
            let newLogger = os.Logger(subsystem: event.subsystem, category: event.category)
            loggers[loggerKey] = newLogger
            logger = newLogger
        }
        lock.unlock()
        
        let formattedMessage = "[\(event.threadId)] [\(event.file.components(separatedBy: "/").last ?? "Unknown"):\(event.line)] \(event.function) -> \(event.message)"
        
        switch event.level {
        case .trace:
            logger.debug("\(formattedMessage, privacy: .public)")
        case .debug:
            logger.debug("\(formattedMessage, privacy: .public)")
        case .info:
            logger.info("\(formattedMessage, privacy: .public)")
        case .warning:
            logger.warning("\(formattedMessage, privacy: .public)")
        case .error:
            logger.error("\(formattedMessage, privacy: .public)")
        case .critical:
            logger.fault("\(formattedMessage, privacy: .public)")
        }
    }
}

/// 目的地 2: 工业级滚动持久化文件日志系统
public final class FileLogDestination: LogDestination, @unchecked Sendable {
    public var minimumLevel: AELogLevel
    private let logDirectory: URL
    private let baseFileName: String
    private let maxFileSize: UInt64
    private let maxBackupFiles: Int
    
    private let fileWriteQueue: DispatchQueue
    private var currentFileHandle: FileHandle?
    private var currentFilePath: URL?
    private var currentSize: UInt64 = 0
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    
    public init(
        logDirectory: URL,
        baseFileName: String = "aemachboot.log",
        minimumLevel: AELogLevel = .debug,
        maxFileSize: UInt64 = 10 * 1024 * 1024, // 10 MB
        maxBackupFiles: Int = 5
    ) {
        self.logDirectory = logDirectory
        self.baseFileName = baseFileName
        self.minimumLevel = minimumLevel
        self.maxFileSize = maxFileSize
        self.maxBackupFiles = maxBackupFiles
        self.fileWriteQueue = DispatchQueue(label: "com.aemachboot.logger.file_write_queue", qos: .utility)
        
        initializeLogDirectory()
    }
    
    deinit {
        let handle = self.currentFileHandle
        self.currentFileHandle = nil
        try? handle?.close()
    }
    
    private func initializeLogDirectory() {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: nil)
    }
    
    private func getActiveFileHandle() throws -> FileHandle {
        if let handle = currentFileHandle {
            return handle
        }
        
        let fileURL = logDirectory.appendingPathComponent(baseFileName)
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        }
        
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0
        
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        
        self.currentFilePath = fileURL
        self.currentFileHandle = handle
        self.currentSize = fileSize
        
        return handle
    }
    
    public func write(event: LogEvent) {
        guard event.level >= minimumLevel else { return }
        
        fileWriteQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let timestampStr = self.dateFormatter.string(from: event.timestamp)
                let fileName = event.file.components(separatedBy: "/").last ?? "Unknown"
                let logLine = "[\(timestampStr)] [\(event.level.description)] [T:\(event.threadId)] [\(fileName):\(event.line)] \(event.function) : \(event.message)\n"
                
                guard let data = logLine.data(using: .utf8) else { return }
                
                let handle = try self.getActiveFileHandle()
                try handle.write(contentsOf: data)
                self.currentSize += UInt64(data.count)
                
                if self.currentSize >= self.maxFileSize {
                    self.rotateLogFiles()
                }
            } catch {
                os_log("Failed to write to file log: %{public}@", type: .error, error.localizedDescription)
            }
        }
    }
    
    private func rotateLogFiles() {
        guard let currentPath = currentFilePath else { return }
        
        try? currentFileHandle?.synchronize()
        try? currentFileHandle?.close()
        currentFileHandle = nil
        
        let fileManager = FileManager.default
        
        // 循环移除最旧的日志，并将现有日志递增重命名
        for i in (1...maxBackupFiles).reversed() {
            let sourceURL = logDirectory.appendingPathComponent("\(baseFileName).\(i)")
            let targetURL = logDirectory.appendingPathComponent("\(baseFileName).\(i + 1)")
            
            if fileManager.fileExists(atPath: sourceURL.path) {
                if i == maxBackupFiles {
                    try? fileManager.removeItem(at: sourceURL)
                } else {
                    try? fileManager.moveItem(at: sourceURL, to: targetURL)
                }
            }
        }
        
        let rotatedFirstURL = logDirectory.appendingPathComponent("\(baseFileName).1")
        try? fileManager.moveItem(at: currentPath, to: rotatedFirstURL)
        
        // 重置句柄
        _ = try? getActiveFileHandle()
    }
}

/// 集中式多路分发日志引擎
public final class AEMachLogger: @unchecked Sendable {
    public static let shared: AEMachLogger = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = appSupport.appendingPathComponent("AEMachBoot/Logs")
        
        let logger = AEMachLogger()
        logger.addDestination(OSLogDestination(minimumLevel: .debug))
        logger.addDestination(FileLogDestination(logDirectory: logDir, minimumLevel: .debug))
        return logger
    }()
    
    private let lock = NSLock()
    private var destinations: [LogDestination] = []
    
    public init() {}
    
    public func addDestination(_ destination: LogDestination) {
        lock.lock()
        destinations.append(destination)
        lock.unlock()
    }
    
    public func clearDestinations() {
        lock.lock()
        destinations.removeAll()
        lock.unlock()
    }
    
    public func log(
        level: AELogLevel,
        message: @autoclosure () -> String,
        subsystem: String = "com.aemachboot",
        category: String = "Default",
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        // 避免不必要的字符串求值，先获取目的地副本
        lock.lock()
        let activeDestinations = destinations
        lock.unlock()
        
        guard !activeDestinations.isEmpty else { return }
        
        let hasInterestedDestination = activeDestinations.contains { level >= $0.minimumLevel }
        guard hasInterestedDestination else { return }
        
        let evaluatedMessage = message()
        let event = LogEvent(
            level: level,
            message: evaluatedMessage,
            file: file,
            function: function,
            line: line,
            subsystem: subsystem,
            category: category
        )
        
        for destination in activeDestinations {
            destination.write(event: event)
        }
    }
    
    // 快速便捷打印接口
    public func trace(_ msg: @autoclosure () -> String, sys: String = "com.aemachboot", cat: String = "Default", file: String = #file, fn: String = #function, ln: Int = #line) {
        log(level: .trace, message: msg(), subsystem: sys, category: cat, file: file, function: fn, line: ln)
    }
    
    public func debug(_ msg: @autoclosure () -> String, sys: String = "com.aemachboot", cat: String = "Default", file: String = #file, fn: String = #function, ln: Int = #line) {
        log(level: .debug, message: msg(), subsystem: sys, category: cat, file: file, function: fn, line: ln)
    }
    
    public func info(_ msg: @autoclosure () -> String, sys: String = "com.aemachboot", cat: String = "Default", file: String = #file, fn: String = #function, ln: Int = #line) {
        log(level: .info, message: msg(), subsystem: sys, category: cat, file: file, function: fn, line: ln)
    }
    
    public func warn(_ msg: @autoclosure () -> String, sys: String = "com.aemachboot", cat: String = "Default", file: String = #file, fn: String = #function, ln: Int = #line) {
        log(level: .warning, message: msg(), subsystem: sys, category: cat, file: file, function: fn, line: ln)
    }
    
    public func error(_ msg: @autoclosure () -> String, sys: String = "com.aemachboot", cat: String = "Default", file: String = #file, fn: String = #function, ln: Int = #line) {
        log(level: .error, message: msg(), subsystem: sys, category: cat, file: file, function: fn, line: ln)
    }
    
    public func critical(_ msg: @autoclosure () -> String, sys: String = "com.aemachboot", cat: String = "Default", file: String = #file, fn: String = #function, ln: Int = #line) {
        log(level: .critical, message: msg(), subsystem: sys, category: cat, file: file, function: fn, line: ln)
    }
    
    /// 针对 iSCSI 协议专用的高级十六进制转储 (Hex Dump) 日志组件
    public func hexDump(
        level: AELogLevel = .trace,
        data: Data,
        label: String,
        subsystem: String = "com.aemachboot",
        category: String = "iSCSI-PDU",
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: level, message: {
            var result = "--- HEX DUMP [\(label)] (Size: \(data.count) bytes) ---\n"
            let bytes = [UInt8](data)
            let length = bytes.count
            
            for i in stride(from: 0, to: length, by: 16) {
                let offset = String(format: "%08X", i)
                var hexString = ""
                var asciiString = ""
                
                for j in 0..<16 {
                    if i + j < length {
                        let byte = bytes[i + j]
                        hexString += String(format: "%02X ", byte)
                        
                        let char = Character(UnicodeScalar(byte))
                        if byte >= 32 && byte <= 126 {
                            asciiString.append(char)
                        } else {
                            asciiString.append(".")
                        }
                    } else {
                        hexString += "   "
                        asciiString.append(" ")
                    }
                    if j == 7 {
                        hexString += " " // 第8和第9个字节间增加额外空格，提高可读性
                    }
                }
                result += "\(offset)  \(hexString) |\(asciiString)|\n"
            }
            result += "----------------------------------------------------"
            return result
        }(), subsystem: subsystem, category: category, file: file, function: function, line: line)
    }
}