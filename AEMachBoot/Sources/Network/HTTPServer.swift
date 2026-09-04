import Foundation

/// 工业级高并发 HTTP / 1.1 Bootstrap 文件分发服务器
public final class HTTPServer: @unchecked Sendable {
    private var listenSocketFd: Int32 = -1
    private let port: UInt16
    private let documentRoot: String
    private let logger: AEMachLogger
    private let serverQueue: DispatchQueue
    private var isRunning: Bool = false
    private let lock = NSLock()
    
    public init(port: UInt16 = 8080, documentRoot: String, logger: AEMachLogger = .shared) {
        self.port = port
        self.documentRoot = documentRoot
        self.logger = logger
        self.serverQueue = DispatchQueue(label: "com.aemachboot.network.http_server", qos: .default, attributes: .concurrent)
    }
    
    deinit {
        stop()
    }
    
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isRunning else { return }
        
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            let err = errno
            throw NSError(domain: "HTTPServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create TCP socket"])
        }
        
        var optVal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optVal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &optVal, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        
        let bindStatus = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        
        guard bindStatus == 0 else {
            let err = errno
            close(fd)
            logger.error("HTTP binding to port \(port) failed (Errno: \(err)).", sys: "com.aemachboot.network", cat: "HTTP")
            throw NSError(domain: "HTTPServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "HTTP binding failed"])
        }
        
        guard listen(fd, 128) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: "HTTPServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "TCP listen failed"])
        }
        
        self.listenSocketFd = fd
        self.isRunning = true
        
        logger.info("HTTP Bootstrap Accelerator successfully listening on port \(port), root: \(documentRoot)", sys: "com.aemachboot.network", cat: "HTTP")
        
        serverQueue.async { [weak self] in
            self?.acceptConnectionsLoop()
        }
    }
    
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        guard isRunning else { return }
        
        if listenSocketFd >= 0 {
            close(listenSocketFd)
            listenSocketFd = -1
        }
        
        isRunning = false
        logger.info("HTTP Server shutdown complete.", sys: "com.aemachboot.network", cat: "HTTP")
    }
    
    private func acceptConnectionsLoop() {
        while true {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr -> Int32 in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(listenSocketFd, sockaddrPtr, &addrLen)
                }
            }
            
            guard clientFd >= 0 else {
                lock.lock()
                let currentRunning = isRunning
                lock.unlock()
                if !currentRunning { break }
                continue
            }
            
            serverQueue.async { [weak self] in
                self?.handleClientConnection(clientFd)
            }
        }
    }
    
    private func handleClientConnection(_ clientFd: Int32) {
        defer { close(clientFd) }
        
        var headerBuffer = Data()
        var tempBuffer = [UInt8](repeating: 0, count: 1024)
        
        while true {
            let bytesRead = recv(clientFd, &tempBuffer, tempBuffer.count, 0)
            guard bytesRead > 0 else { return }
            
            headerBuffer.append(contentsOf: tempBuffer.prefix(bytesRead))
            if let string = String(data: headerBuffer, encoding: .ascii), string.contains("\r\n\r\n") {
                break
            }
            if headerBuffer.count > 8192 {
                sendRawErrorResponse(clientFd, statusCode: "413 Payload Too Large")
                return
            }
        }
        
        guard let requestString = String(data: headerBuffer, encoding: .utf8) else { return }
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        
        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else {
            sendRawErrorResponse(clientFd, statusCode: "400 Bad Request")
            return
        }
        
        let method = requestParts[0].uppercased()
        let relativePath = requestParts[1]
        
        guard method == "GET" || method == "HEAD" else {
            sendRawErrorResponse(clientFd, statusCode: "405 Method Not Allowed")
            return
        }
        
        let cleanPath = relativePath.components(separatedBy: "?").first ?? "/"
        let decodedPath = cleanPath.removingPercentEncoding ?? cleanPath
        var sanitizedPath = decodedPath.replacingOccurrences(of: "..", with: "")
        
        // 💥【修复下载报错】：如果请求根目录 "/"，自动定位到 boot.ipxe
        if sanitizedPath == "/" || sanitizedPath.isEmpty {
            sanitizedPath = "/boot.ipxe"
        }
        
        var targetFilePath = URL(fileURLWithPath: documentRoot).appendingPathComponent(sanitizedPath).path
        let fileManager = FileManager.default
        
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: targetFilePath, isDirectory: &isDir) {
            if isDir.boolValue {
                targetFilePath = URL(fileURLWithPath: targetFilePath).appendingPathComponent("boot.ipxe").path
            }
        }
        
        guard fileManager.fileExists(atPath: targetFilePath) else {
            logger.warn("HTTP File not found: \(sanitizedPath) (Path: \(targetFilePath))", sys: "com.aemachboot.network", cat: "HTTP")
            sendRawErrorResponse(clientFd, statusCode: "404 Not Found")
            return
        }
        
        guard let fileStream = InputStream(fileAtPath: targetFilePath) else {
            sendRawErrorResponse(clientFd, statusCode: "403 Forbidden")
            return
        }
        
        fileStream.open()
        defer { fileStream.close() }
        
        let fileAttributes = try? fileManager.attributesOfItem(atPath: targetFilePath)
        let fileSize = fileAttributes?[.size] as? UInt64 ?? 0
        
        let mimeType: String = targetFilePath.hasSuffix(".ipxe") ? "text/plain" : "application/octet-stream"
        
        var headerStr = "HTTP/1.1 200 OK\r\n"
        headerStr += "Server: AEMachBoot HTTP Accelerator\r\n"
        headerStr += "Content-Type: \(mimeType)\r\n"
        headerStr += "Content-Length: \(fileSize)\r\n"
        headerStr += "Connection: close\r\n\r\n"
        
        guard let headerData = headerStr.data(using: .ascii) else { return }
        
        _ = headerData.withUnsafeBytes { rawBuffer in
            send(clientFd, rawBuffer.baseAddress, headerData.count, 0)
        }
        
        if method == "HEAD" { return }
        
        let chunkBufferSize = 65536
        var chunkBuffer = [UInt8](repeating: 0, count: chunkBufferSize)
        
        logger.info("HTTP Streaming file: \(sanitizedPath) (\(fileSize) bytes) successfully.", sys: "com.aemachboot.network", cat: "HTTP")
        
        while fileStream.hasBytesAvailable {
            let readLen = fileStream.read(&chunkBuffer, maxLength: chunkBufferSize)
            guard readLen > 0 else { break }
            
            let sentBytes = send(clientFd, &chunkBuffer, readLen, 0)
            if sentBytes < 0 {
                logger.error("HTTP peer reset connection mid-transfer.", sys: "com.aemachboot.network", cat: "HTTP")
                break
            }
        }
    }
    
    private func sendRawErrorResponse(_ fd: Int32, statusCode: String) {
        var resp = "HTTP/1.1 \(statusCode)\r\n"
        resp += "Server: AEMachBoot HTTP Accelerator\r\n"
        resp += "Content-Length: 0\r\n"
        resp += "Connection: close\r\n\r\n"
        
        if let data = resp.data(using: .ascii) {
            _ = data.withUnsafeBytes { rawBuffer in
                send(fd, rawBuffer.baseAddress, data.count, 0)
            }
        }
    }
}
