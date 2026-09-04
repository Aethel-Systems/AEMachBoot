import Foundation

/// TFTP 协议操作码 (RFC 1350, RFC 2347)
public enum TFTPOpcode: UInt16, Sendable {
    case rrq   = 1  // Read Request (下载文件)
    case wrq   = 2  // Write Request (上传文件)
    case data  = 3  // Data Packet (数据包)
    case ack   = 4  // Acknowledgment (确认包)
    case error = 5  // Error Packet (错误包)
    case oack  = 6  // Option Acknowledgment (选项协商确认包，RFC 2347)
}

/// TFTP 错误代码
public enum TFTPErrorCode: UInt16, Sendable {
    case notDefined        = 0 // 未定义错误
    case fileNotFound      = 1 // 文件未找到
    case accessViolation   = 2 // 访问冲突 (权限不足)
    case diskFull          = 3 // 磁盘满或分配超出
    case illegalOperation  = 4 // 非法 TFTP 操作
    case unknownTransferID = 5 // 传输 ID 未知 (端口错误)
    case fileAlreadyExists = 6 // 文件已存在
    case noSuchUser        = 7 // 无此用户
    case badOption         = 8 // 选项协商失败 (RFC 2347)
}

/// 工业级 TFTP 传输会话
/// 由于 TFTP 在 UDP 69 接收到 RRQ 后，必须在全新随机的临时端口（Ephemeral Port）上建立单独会话与客户端通信，
/// 本类完全封装了该“端口重映射会话”状态机、块大小协商、传输滑动窗口及数据包重传控制机制。
public final class TFTPTransferSession: @unchecked Sendable {
    private var socketFd: Int32 = -1
    private let clientAddr: sockaddr_in
    private let filePath: String
    private let logger: AEMachLogger
    private let queue: DispatchQueue
    
    // 协商选项参数 (RFC 2348, RFC 2349)
    private var blockSize: Int = 512       // 默认标准块大小为 512 字节
    private var expectedTSize: Bool = false // 客户端是否请求了 tsize 选项
    private var fileData = Data()
    
    private var currentBlock: UInt16 = 0
    private var isCompleted: Bool = false
    private var retryCount: Int = 0
    private let maxRetries: Int = 5
    private let timeoutInterval: TimeInterval = 2.0 // 重传超时 2.0s
    
    private var lastSentPacket = Data()
    private var timerSource: DispatchSourceTimer? = nil
    private var readSource: DispatchSourceRead? = nil
    
    private let onCompleted: (String) -> Void
    private let sessionID: String
    
    public init(
        sessionID: String,
        clientAddr: sockaddr_in,
        filePath: String,
        options: [String: String],
        logger: AEMachLogger,
        onCompleted: @escaping (String) -> Void
    ) throws {
        self.sessionID = sessionID
        self.clientAddr = clientAddr
        self.filePath = filePath
        self.logger = logger
        self.onCompleted = onCompleted
        self.queue = DispatchQueue(label: "com.aemachboot.tftp.session.\(sessionID)", qos: .userInitiated)
        
        try parseOptions(options)
        try loadFile()
        try initSessionSocket()
    }
    
    deinit {
        cleanup()
    }
    
    private func parseOptions(_ options: [String: String]) throws {
        // 协商 blksize 选项 (RFC 2348)
        if let blksizeStr = options["blksize"], let val = Int(blksizeStr) {
            // 限制 blksize 在合理安全范围内 (8 至 65464)
            self.blockSize = max(8, min(65464, val))
            logger.debug("Negotiating TFTP block size: \(self.blockSize) bytes (Requested: \(val))", sys: "com.aemachboot.network", cat: "TFTP")
        }
        
        // 协商 tsize 选项 (RFC 2349)
        if options["tsize"] != nil {
            self.expectedTSize = true
        }
    }
    
    private func loadFile() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath) else {
            logger.error("TFTP requested file not found: \(filePath)", sys: "com.aemachboot.network", cat: "TFTP")
            throw NSError(domain: "TFTP", code: Int(TFTPErrorCode.fileNotFound.rawValue), userInfo: [NSLocalizedDescriptionKey: "File not found"])
        }
        
        // 检查文件是否可读
        guard fileManager.isReadableFile(atPath: filePath) else {
            logger.error("TFTP requested file permission denied: \(filePath)", sys: "com.aemachboot.network", cat: "TFTP")
            throw NSError(domain: "TFTP", code: Int(TFTPErrorCode.accessViolation.rawValue), userInfo: [NSLocalizedDescriptionKey: "Access violation"])
        }
        
        self.fileData = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
        logger.info("TFTP transfer target loaded. Size: \(fileData.count) bytes.", sys: "com.aemachboot.network", cat: "TFTP")
    }
    
    private func initSessionSocket() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            let err = errno
            throw NSError(domain: "TFTP", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create ephemeral TFTP socket"])
        }
        
        // 绑定到临时端口 (Port = 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian // 0 让操作系统自动分配未被占用的端口
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        
        let bindStatus = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        
        guard bindStatus == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: "TFTP", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Ephemeral port bind failed (errno: \(err))"])
        }
        
        self.socketFd = fd
    }
    
    /// 开始执行传输事务状态机
    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // 建立 GCD 套接字监控
            let source = DispatchSource.makeReadSource(fileDescriptor: self.socketFd, queue: self.queue)
            source.setEventHandler { [weak self] in
                self?.handleIncomingPacket()
            }
            source.resume()
            self.readSource = source
            
            // 如果存在协商选项，发送 OACK 报文；否则直接发送第一块 DATA 报文
            if self.blockSize != 512 || self.expectedTSize {
                self.sendOptionAck()
            } else {
                self.sendDataPacket(block: 1)
            }
        }
    }
    
    private func handleIncomingPacket() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var fromAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let readBytes = withUnsafeMutablePointer(to: &fromAddr) { addrPtr -> Int in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                recvfrom(socketFd, &buffer, buffer.count, 0, sockaddrPtr, &addrLen)
            }
        }
        
        guard readBytes >= 4 else { return }
        
        let opcodeRaw = UInt16(buffer[0]) << 8 | UInt16(buffer[1])
        guard let opcode = TFTPOpcode(rawValue: opcodeRaw) else { return }
        
        switch opcode {
        case .ack:
            let acknowledgedBlock = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
            processAck(block: acknowledgedBlock)
            
        case .error:
            let errorCode = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
            let errMsg = String(cString: Array(buffer[4..<readBytes]))
            logger.error("TFTP Client reported error code \(errorCode): \(errMsg)", sys: "com.aemachboot.network", cat: "TFTP")
            terminateSession()
            
        default:
            logger.warn("TFTP Session received unexpected opcode: \(opcodeRaw)", sys: "com.aemachboot.network", cat: "TFTP")
        }
    }
    
    private func processAck(block: UInt16) {
        // 取消现有的重传定时器
        stopRetransmitTimer()
        retryCount = 0
        
        // 当收到 OACK 的 ACK 时，block 为 0
        if block == 0 && currentBlock == 0 {
            logger.debug("OACK acknowledged by client. Moving to send Block 1.", sys: "com.aemachboot.network", cat: "TFTP")
            sendDataPacket(block: 1)
            return
        }
        
        guard block == currentBlock else {
            // 收到了不符合预期的旧 ACK，重置定时器，忽略旧确认，等待客户端追赶
            startRetransmitTimer()
            return
        }
        
        // 检查上一个发送的包是否少于协商的块大小。如果是，意味着上一个包是尾包，传输完成。
        let lastOffset = Int(currentBlock - 1) * blockSize
        let remainingBytes = fileData.count - lastOffset
        
        if remainingBytes < blockSize {
            logger.info("TFTP session \(sessionID) completed file transfer.", sys: "com.aemachboot.network", cat: "TFTP")
            isCompleted = true
            terminateSession()
        } else {
            sendDataPacket(block: currentBlock + 1)
        }
    }
    
    private func sendOptionAck() {
        var oack = Data()
        oack.append(UInt8((TFTPOpcode.oack.rawValue >> 8) & 0xFF))
        oack.append(UInt8(TFTPOpcode.oack.rawValue & 0xFF))
        
        if blockSize != 512 {
            oack.append("blksize\0".data(using: .ascii)!)
            oack.append("\(blockSize)\0".data(using: .ascii)!)
        }
        
        if expectedTSize {
            oack.append("tsize\0".data(using: .ascii)!)
            oack.append("\(fileData.count)\0".data(using: .ascii)!)
        }
        
        currentBlock = 0
        lastSentPacket = oack
        
        sendPacketRaw(oack)
        startRetransmitTimer()
    }
    
    private func sendDataPacket(block: UInt16) {
        let offset = Int(block - 1) * blockSize
        guard offset < fileData.count else { return }
        
        let size = min(blockSize, fileData.count - offset)
        let chunk = fileData.subdata(in: offset..<(offset + size))
        
        var packet = Data(capacity: size + 4)
        packet.append(UInt8((TFTPOpcode.data.rawValue >> 8) & 0xFF))
        packet.append(UInt8(TFTPOpcode.data.rawValue & 0xFF))
        packet.append(UInt8((block >> 8) & 0xFF))
        packet.append(UInt8(block & 0xFF))
        packet.append(chunk)
        
        currentBlock = block
        lastSentPacket = packet
        
        sendPacketRaw(packet)
        startRetransmitTimer()
    }
    
    private func sendPacketRaw(_ packet: Data) {
        var target = clientAddr
        packet.withUnsafeBytes { rawBuffer in
            _ = withUnsafePointer(to: &target) { socketAddrPtr in
                socketAddrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { destAddr in
                    sendto(socketFd, rawBuffer.baseAddress, packet.count, 0, destAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    
    /// 触发重传定时器
    private func startRetransmitTimer() {
        stopRetransmitTimer()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeoutInterval, repeating: timeoutInterval)
        timer.setEventHandler { [weak self] in
            self?.handleRetransmitTimeout()
        }
        timer.resume()
        self.timerSource = timer
    }
    
    private func stopRetransmitTimer() {
        if let timer = timerSource {
            timer.cancel()
            self.timerSource = nil
        }
    }
    
    private func handleRetransmitTimeout() {
        retryCount += 1
        if retryCount > maxRetries {
            logger.error("TFTP retransmission limit reached. Aborting transfer session.", sys: "com.aemachboot.network", cat: "TFTP")
            terminateSession()
            return
        }
        
        logger.warn("TFTP packet ACK timeout for block \(currentBlock). Retrying (\(retryCount)/\(maxRetries))...", sys: "com.aemachboot.network", cat: "TFTP")
        sendPacketRaw(lastSentPacket)
    }
    
    private func sendErrorPacket(code: TFTPErrorCode, message: String) {
        var packet = Data()
        packet.append(UInt8((TFTPOpcode.error.rawValue >> 8) & 0xFF))
        packet.append(UInt8(TFTPOpcode.error.rawValue & 0xFF))
        packet.append(UInt8((code.rawValue >> 8) & 0xFF))
        packet.append(UInt8(code.rawValue & 0xFF))
        packet.append((message + "\0").data(using: .ascii)!)
        
        sendPacketRaw(packet)
    }
    
    private func terminateSession() {
        cleanup()
        onCompleted(sessionID)
    }
    
    private func cleanup() {
        stopRetransmitTimer()
        if let source = readSource {
            source.cancel()
            readSource = nil
        }
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
    }
}

/// 工业级 TFTP 服务器主调度引擎
/// 负责在 UDP 69 端口接收读写请求 (RRQ/WRQ)，解析客户端意图，并动态分流分发、生命周期托管传输子会话。
public final class TFTPServer: @unchecked Sendable {
    private var mainSocketFd: Int32 = -1
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead? = nil
    private var isRunning: Bool = false
    private let lock = NSLock()
    
    private let rootDirectory: String
    private let logger: AEMachLogger
    
    // 线程安全管理所有的活动会话
    private var activeSessions = [String: TFTPTransferSession]()
    private let sessionLock = NSLock()
    
    public init(rootDirectory: String, logger: AEMachLogger = .shared) {
        self.rootDirectory = rootDirectory
        self.logger = logger
        self.queue = DispatchQueue(label: "com.aemachboot.network.tftp_listener", qos: .userInteractive)
    }
    
    deinit {
        stop()
    }
    
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isRunning else { return }
        
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            let err = errno
            throw NSError(domain: "TFTPServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create socket (errno: \(err))"])
        }
        
        var optVal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optVal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &optVal, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(69).bigEndian // TFTP 协议公共监听端口为 69
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        
        let bindStatus = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        
        guard bindStatus == 0 else {
            let err = errno
            close(fd)
            logger.error("TFTP Port 69 binding failed. (Errno: \(err) - check if Apple's native tftpd service is active).", sys: "com.aemachboot.network", cat: "TFTP")
            throw NSError(domain: "TFTPServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Port 69 bind failure. Root required."])
        }
        
        self.mainSocketFd = fd
        self.isRunning = true
        
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleIncomingRRQ()
        }
        source.resume()
        self.readSource = source
        
        logger.info("TFTP Server listening on port 69, serving directory: \(rootDirectory)", sys: "com.aemachboot.network", cat: "TFTP")
    }
    
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        guard isRunning else { return }
        
        if let source = readSource {
            source.cancel()
            readSource = nil
        }
        
        if mainSocketFd >= 0 {
            close(mainSocketFd)
            mainSocketFd = -1
        }
        
        // 清理所有子传输会话
        sessionLock.lock()
        activeSessions.removeAll()
        sessionLock.unlock()
        
        isRunning = false
        logger.info("TFTP Server stopped.", sys: "com.aemachboot.network", cat: "TFTP")
    }
    
    private func handleIncomingRRQ() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let readBytes = withUnsafeMutablePointer(to: &clientAddr) { addrPtr -> Int in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                recvfrom(mainSocketFd, &buffer, buffer.count, 0, sockaddrPtr, &addrLen)
            }
        }
        
        guard readBytes >= 4 else { return }
        
        let opcodeRaw = UInt16(buffer[0]) << 8 | UInt16(buffer[1])
        guard let opcode = TFTPOpcode(rawValue: opcodeRaw) else { return }
        
        // TFTP 只处理读请求 (RRQ) 来分发无盘镜像引导程序
        if opcode == .rrq {
            processRRQ(buffer: Array(buffer[2..<readBytes]), clientAddr: clientAddr)
        } else {
            // 对于 WRQ 或其他未知命令直接返回 ILLEGAL OPERATION 错误
            sendDirectError(code: .illegalOperation, message: "Only Read Request (RRQ) is supported by AEMachBoot.", dest: clientAddr)
        }
    }
    
    private func processRRQ(buffer: [UInt8], clientAddr: sockaddr_in) {
        var offset = 0
        
        // 1. 提取 null-terminated 引导文件名
        guard let fileNameEnd = buffer[offset...].firstIndex(of: 0) else { return }
        let rawFileName = String(cString: Array(buffer[offset..<fileNameEnd]))
        offset = fileNameEnd + 1
        
        // 2. 提取传输模式 Mode (octet / mail / netascii)
        guard offset < buffer.count, let modeEnd = buffer[offset...].firstIndex(of: 0) else { return }
        let mode = String(cString: Array(buffer[offset..<modeEnd])).lowercased()
        offset = modeEnd + 1
        
        logger.info("TFTP incoming RRQ for: '\(rawFileName)' (Mode: \(mode))", sys: "com.aemachboot.network", cat: "TFTP")
        
        // 3. 提取高级选项信息 (RFC 2347)
        var options = [String: String]()
        while offset < buffer.count {
            guard let optKeyEnd = buffer[offset...].firstIndex(of: 0) else { break }
            let key = String(cString: Array(buffer[offset..<optKeyEnd])).lowercased()
            offset = optKeyEnd + 1
            
            guard offset < buffer.count, let optValEnd = buffer[offset...].firstIndex(of: 0) else { break }
            let val = String(cString: Array(buffer[offset..<optValEnd]))
            offset = optValEnd + 1
            
            options[key] = val
        }
        
        // 对目录遍历攻击（Traversal Attack）进行前置防御安全过滤
        let cleanFileName = rawFileName.replacingOccurrences(of: "..", with: "")
        let fullPath = URL(fileURLWithPath: rootDirectory).appendingPathComponent(cleanFileName).path
        
        // 4. 为该客户端创建专属的 Ephemeral 临时端口文件传输子会话
        let clientIP = String(cString: inet_ntoa(clientAddr.sin_addr))
        let clientPort = UInt16(clientAddr.sin_port).bigEndian
        let sessionID = "\(clientIP):\(clientPort)-\(UUID().uuidString.prefix(6))"
        
        do {
            let session = try TFTPTransferSession(
                sessionID: sessionID,
                clientAddr: clientAddr,
                filePath: fullPath,
                options: options,
                logger: logger,
                onCompleted: { [weak self] id in
                    self?.removeSession(id)
                }
            )
            
            sessionLock.lock()
            activeSessions[sessionID] = session
            sessionLock.unlock()
            
            session.start()
        } catch {
            let tftpErrCode = (error as NSError).code
            let code = TFTPErrorCode(rawValue: UInt16(tftpErrCode)) ?? .notDefined
            sendDirectError(code: code, message: error.localizedDescription, dest: clientAddr)
        }
    }
    
    private func removeSession(_ id: String) {
        sessionLock.lock()
        activeSessions.removeValue(forKey: id)
        sessionLock.unlock()
    }
    
    private func sendDirectError(code: TFTPErrorCode, message: String, dest: sockaddr_in) {
        var packet = Data()
        packet.append(UInt8((TFTPOpcode.error.rawValue >> 8) & 0xFF))
        packet.append(UInt8(TFTPOpcode.error.rawValue & 0xFF))
        packet.append(UInt8((code.rawValue >> 8) & 0xFF))
        packet.append(UInt8(code.rawValue & 0xFF))
        packet.append((message + "\0").data(using: .ascii)!)
        
        var target = dest
        packet.withUnsafeBytes { rawBuffer in
            _ = withUnsafePointer(to: &target) { socketAddrPtr in
                socketAddrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { destAddr in
                    sendto(mainSocketFd, rawBuffer.baseAddress, packet.count, 0, destAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
