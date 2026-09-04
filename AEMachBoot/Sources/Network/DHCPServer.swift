import Foundation

/// DHCP 报文类型定义 (RFC 2131)
public enum DHCPMessageType: UInt8, Sendable {
    case discover = 1
    case offer = 2
    case request = 3
    case decline = 4
    case ack = 5
    case nak = 6
    case release = 7
    case inform = 8
}

/// 核心 DHCP / PXE 数据报文封装
public struct DHCPPacket: Sendable {
    public var op: UInt8 = 1        // 1 = Boot Request, 2 = Boot Reply
    public var htype: UInt8 = 1     // 1 = Ethernet
    public var hlen: UInt8 = 6      // MAC Address Length
    public var hops: UInt8 = 0
    public var xid: UInt32 = 0      // Transaction ID
    public var secs: UInt16 = 0
    public var flags: UInt16 = 0    // 0x8000 = Broadcast Flag
    public var ciaddr: UInt32 = 0   // Client IP
    public var yiaddr: UInt32 = 0   // Your IP (Assigned to Client)
    public var siaddr: UInt32 = 0   // Server IP (Next Server / TFTP Boot Host)
    public var giaddr: UInt32 = 0   // Gateway IP
    public var chaddr: Data = Data(repeating: 0, count: 16) // Client MAC Address
    public var sname: String = ""   // Server Host Name (64 Bytes)
    public var file: String = ""    // Boot File Path (128 Bytes)
    
    // 选项字典
    public var options: [UInt8: Data] = [:]
    
    public init() {}
    
    public init(rawBytes: Data) throws {
        guard rawBytes.count >= 240 else {
            throw NSError(domain: "DHCPServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "DHCP packet size too small"])
        }
        
        self.op = rawBytes[0]
        self.htype = rawBytes[1]
        self.hlen = rawBytes[2]
        self.hops = rawBytes[3]
        
        self.xid = rawBytes.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).bigEndian }
        self.secs = rawBytes.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self).bigEndian }
        self.flags = rawBytes.withUnsafeBytes { $0.load(fromByteOffset: 10, as: UInt16.self).bigEndian }
        
        self.ciaddr = rawBytes.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self).bigEndian }
        self.yiaddr = rawBytes.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self).bigEndian }
        self.siaddr = rawBytes.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self).bigEndian }
        self.giaddr = rawBytes.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self).bigEndian }
        
        self.chaddr = rawBytes.subdata(in: 28..<44)
        
        let snameBytes = rawBytes.subdata(in: 44..<108)
        self.sname = snameBytes.withUnsafeBytes { rawPtr -> String in
            guard let baseAddress = rawPtr.baseAddress else { return "" }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
        
        let fileBytes = rawBytes.subdata(in: 108..<236)
        self.file = fileBytes.withUnsafeBytes { rawPtr -> String in
            guard let baseAddress = rawPtr.baseAddress else { return "" }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
        
        let magicCookie = rawBytes.subdata(in: 236..<240)
        guard magicCookie == Data([99, 130, 83, 99]) else {
            throw NSError(domain: "DHCPServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid DHCP Magic Cookie"])
        }
        
        var offset = 240
        while offset < rawBytes.count {
            let optCode = rawBytes[offset]
            if optCode == 255 { break }
            if optCode == 0 {
                offset += 1
                continue
            }
            
            guard offset + 1 < rawBytes.count else { break }
            let length = Int(rawBytes[offset + 1])
            
            guard offset + 2 + length <= rawBytes.count else { break }
            let val = rawBytes.subdata(in: (offset + 2)..<(offset + 2 + length))
            
            self.options[optCode] = val
            offset += 2 + length
        }
    }
    
    public func serialize() -> Data {
        var data = Data(capacity: 300)
        
        data.append(op)
        data.append(htype)
        data.append(hlen)
        data.append(hops)
        
        var xidBE = xid.bigEndian
        data.append(UnsafeBufferPointer(start: &xidBE, count: 1))
        
        var secsBE = secs.bigEndian
        data.append(UnsafeBufferPointer(start: &secsBE, count: 1))
        
        var flagsBE = flags.bigEndian
        data.append(UnsafeBufferPointer(start: &flagsBE, count: 1))
        
        var ciaddrBE = ciaddr.bigEndian
        data.append(UnsafeBufferPointer(start: &ciaddrBE, count: 1))
        
        var yiaddrBE = yiaddr.bigEndian
        data.append(UnsafeBufferPointer(start: &yiaddrBE, count: 1))
        
        var siaddrBE = siaddr.bigEndian
        data.append(UnsafeBufferPointer(start: &siaddrBE, count: 1))
        
        var giaddrBE = giaddr.bigEndian
        data.append(UnsafeBufferPointer(start: &giaddrBE, count: 1))
        
        var fixedMac = chaddr
        if fixedMac.count < 16 {
            fixedMac.append(Data(repeating: 0, count: 16 - fixedMac.count))
        } else {
            fixedMac = fixedMac.prefix(16)
        }
        data.append(fixedMac)
        
        var fixedSname = sname.data(using: .utf8) ?? Data()
        fixedSname.append(Data(repeating: 0, count: 64 - fixedSname.count))
        data.append(fixedSname.prefix(64))
        
        var fixedFile = file.data(using: .utf8) ?? Data()
        fixedFile.append(Data(repeating: 0, count: 128 - fixedFile.count))
        data.append(fixedFile.prefix(128))
        
        data.append(Data([99, 130, 83, 99]))
        
        let sortedCodes = options.keys.sorted { opt1, opt2 in
            if opt1 == 53 { return true }
            if opt2 == 53 { return false }
            if opt1 == 54 { return true }
            if opt2 == 54 { return false }
            return opt1 < opt2
        }
        
        for optCode in sortedCodes {
            if let optVal = options[optCode] {
                data.append(optCode)
                data.append(UInt8(optVal.count))
                data.append(optVal)
            }
        }
        
        data.append(255)
        
        while data.count < 300 {
            data.append(0)
        }
        
        return data
    }
}

public struct DHCPServerConfig: Sendable {
    public let isProxyDHCP: Bool
    public let interfaceName: String
    public let localIP: String
    public let subnetMask: String
    public let startIPRange: String?
    public let endIPRange: String?
    public let routerIP: String?
    public let bootServerIP: String
    public let bootFileName: String
    
    public init(
        isProxyDHCP: Bool,
        interfaceName: String,
        localIP: String,
        subnetMask: String,
        startIPRange: String? = nil,
        endIPRange: String? = nil,
        routerIP: String? = nil,
        bootServerIP: String,
        bootFileName: String
    ) {
        self.isProxyDHCP = isProxyDHCP
        self.interfaceName = interfaceName
        self.localIP = localIP
        self.subnetMask = subnetMask
        self.startIPRange = startIPRange
        self.endIPRange = endIPRange
        self.routerIP = routerIP
        self.bootServerIP = bootServerIP
        self.bootFileName = bootFileName
    }
}

public final class DHCPServer: @unchecked Sendable {
    private var socketFd: Int32 = -1
    private var socketFd4011: Int32 = -1
    private var readSource4011: DispatchSourceRead? = nil
    private let config: DHCPServerConfig
    private let logger: AEMachLogger
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead? = nil
    private var isRunning: Bool = false
    private let lock = NSLock()
    
    private var macLastXID: [String: UInt32] = [:]
    private var macStageMap: [String: Int] = [:]
    private var macLastSeen: [String: Date] = [:]
    private let stageLock = NSLock()
    
    public init(config: DHCPServerConfig, logger: AEMachLogger = .shared) {
        self.config = config
        self.logger = logger
        self.queue = DispatchQueue(label: "com.aemachboot.network.dhcp_loop", qos: .userInteractive)
    }
    
    deinit {
        stop()
    }
    
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isRunning else { return }
        
        logger.info("Initializing DHCP Engine...", sys: "com.aemachboot.network", cat: "DHCP")
        
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            let err = errno
            throw NSError(domain: "DHCPServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }
        
        var optVal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optVal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &optVal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &optVal, socklen_t(MemoryLayout<Int32>.size))
        
        var ifIdx = if_nametoindex(config.interfaceName)
        if ifIdx > 0 {
            let boundRes = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &ifIdx, socklen_t(MemoryLayout<UInt32>.size))
            if boundRes == 0 {
                logger.info("Successfully bound DHCP socket directly to interface '\(config.interfaceName)' (Index: \(ifIdx)) via IP_BOUND_IF", sys: "com.aemachboot.network", cat: "DHCP")
            }
        }
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(67).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        
        let bindStatus = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        
        guard bindStatus == 0 else {
            let err = errno
            close(fd)
            logger.error("DHCP Port 67 bind failed. Errno: \(err)", sys: "com.aemachboot.network", cat: "DHCP")
            throw NSError(domain: "DHCPServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Port 67 bind failure."])
        }
        
        self.socketFd = fd
        self.isRunning = true
        
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleIncomingData()
        }
        source.resume()
        self.readSource = source
        
        if config.isProxyDHCP {
            try start4011Listener()
        }
        
        logger.info("DHCP Server active on Port 67 (\(config.isProxyDHCP ? "ProxyDHCP Mode" : "Standard Mode"))", sys: "com.aemachboot.network", cat: "DHCP")
    }
    
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        guard isRunning else { return }
        
        if let source = readSource {
            source.cancel()
            self.readSource = nil
        }
        
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
        
        if let source = readSource4011 {
            source.cancel()
            self.readSource4011 = nil
        }
        if socketFd4011 >= 0 {
            close(socketFd4011)
            socketFd4011 = -1
        }
        
        stageLock.lock()
        macLastXID.removeAll()
        macStageMap.removeAll()
        macLastSeen.removeAll()
        stageLock.unlock()
        
        isRunning = false
    }
    
    private func handleIncomingData() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let readBytes = withUnsafeMutablePointer(to: &clientAddr) { addrPtr -> Int in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                recvfrom(socketFd, &buffer, buffer.count, 0, sockaddrPtr, &addrLen)
            }
        }
        
        guard readBytes > 0 else { return }
        let packetData = Data(bytes: buffer, count: readBytes)
        
        do {
            let packet = try DHCPPacket(rawBytes: packetData)
            processDHCPRequest(packet)
        } catch {
            logger.warn("Malformed DHCP packet ignored.", sys: "com.aemachboot.network", cat: "DHCP")
        }
    }
    
    private func processDHCPRequest(_ incoming: DHCPPacket) {
        guard let messageTypeData = incoming.options[53], !messageTypeData.isEmpty else { return }
        let messageTypeValue = messageTypeData[0]
        
        guard let type = DHCPMessageType(rawValue: messageTypeValue) else { return }
        
        let macStr = incoming.chaddr.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
        logger.info("DHCP Packet received. Type: \(type), MAC: \(macStr), XID: \(String(format: "0x%08X", incoming.xid))", sys: "com.aemachboot.network", cat: "DHCP")
        
        switch type {
        case .discover:
            let hasPXEFlag = incoming.options[60].flatMap { String(data: $0, encoding: .ascii)?.contains("PXEClient") } ?? false
            
            if config.isProxyDHCP {
                if hasPXEFlag {
                    sendProxyOffer(for: incoming)
                }
            } else {
                sendStandardOffer(for: incoming)
            }
            
        case .request:
            if config.isProxyDHCP {
                let hasPXEFlag = incoming.options[60].flatMap { String(data: $0, encoding: .ascii)?.contains("PXEClient") } ?? false
                if hasPXEFlag {
                    sendProxyAck(for: incoming)
                }
            } else {
                sendStandardAck(for: incoming)
            }
        default:
            break
        }
    }
    
    private func shouldDeliverStage2(for packet: DHCPPacket) -> Bool {
        let macStr = packet.chaddr.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
        
        let isIPXEHeader = (packet.options[77].flatMap { String(data: $0, encoding: .ascii)?.contains("iPXE") } ?? false) || (packet.options[175] != nil)
        if isIPXEHeader { return true }
        
        let now = Date()
        stageLock.lock()
        defer { stageLock.unlock() }
        
        if let lastSeen = macLastSeen[macStr], now.timeIntervalSince(lastSeen) > 30.0 {
            macStageMap[macStr] = 0
            macLastXID[macStr] = nil
        }
        macLastSeen[macStr] = now
        
        let lastXID = macLastXID[macStr]
        let currentStage = macStageMap[macStr] ?? 0
        
        if let oldXID = lastXID, oldXID == packet.xid {
            return currentStage == 2
        }
        
        macLastXID[macStr] = packet.xid
        if currentStage >= 1 {
            macStageMap[macStr] = 2
            return true
        } else {
            macStageMap[macStr] = 1
            return false
        }
    }
    
    private func sendProxyOffer(for discover: DHCPPacket) {
        let isStage2 = shouldDeliverStage2(for: discover)
        let ipBytes = unpackIP(config.bootServerIP)
        
        var reply = DHCPPacket()
        reply.op = 2
        reply.xid = discover.xid
        reply.flags = discover.flags
        reply.chaddr = discover.chaddr
        
        reply.yiaddr = 0
        reply.siaddr = convertIPStringToUInt32(config.bootServerIP)
        
        reply.options[53] = Data([DHCPMessageType.offer.rawValue])
        reply.options[54] = Data(unpackIP(config.localIP))
        reply.options[60] = "PXEClient".data(using: .ascii)
        
        if isStage2 {
            let tftpScript = "boot.ipxe"
            let iscsiRootPath = "iscsi:\(config.bootServerIP):tcp:3260:0:iqn.2026-07.com.aemachboot:target0"
            
            logger.info("💥 [TFTP Stage 2 Active] Handing TFTP Script '\(tftpScript)' & iSCSI Root-Path for XID: \(String(format: "0x%08X", discover.xid))", sys: "com.aemachboot.network", cat: "DHCP")
            
            reply.file = tftpScript
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = tftpScript.data(using: .ascii)
            reply.options[17] = iscsiRootPath.data(using: .ascii)
            
            var opt43 = Data()
            opt43.append(6); opt43.append(1); opt43.append(7)
            opt43.append(255)
            reply.options[43] = opt43
        } else {
            let bootFile = getBootFileName(for: discover)
            logger.info("Formulating ProxyDHCP Offer (Native PXE Stage 1, BootFile: \(bootFile))...", sys: "com.aemachboot.network", cat: "DHCP")
            
            reply.file = bootFile
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = bootFile.data(using: .ascii)
            
            var opt43 = Data()
            opt43.append(6); opt43.append(1); opt43.append(7)
            opt43.append(10); opt43.append(2); opt43.append(0); opt43.append(0)
            
            opt43.append(8); opt43.append(7)
            opt43.append(0); opt43.append(0)
            opt43.append(1)
            opt43.append(contentsOf: ipBytes)
            
            opt43.append(71); opt43.append(4)
            opt43.append(0); opt43.append(0)
            opt43.append(0); opt43.append(0)
            
            opt43.append(255)
            reply.options[43] = opt43
        }
        
        sendPacket(reply, forceBroadcast: true)
    }
    
    private func sendProxyAck(for request: DHCPPacket) {
        let isStage2 = shouldDeliverStage2(for: request)
        let ipBytes = unpackIP(config.bootServerIP)
        
        var reply = DHCPPacket()
        reply.op = 2
        reply.xid = request.xid
        reply.flags = request.flags
        reply.chaddr = request.chaddr
        
        reply.yiaddr = 0
        reply.siaddr = convertIPStringToUInt32(config.bootServerIP)
        
        reply.options[53] = Data([DHCPMessageType.ack.rawValue])
        reply.options[54] = Data(unpackIP(config.localIP))
        reply.options[60] = "PXEClient".data(using: .ascii)
        
        if isStage2 {
            let tftpScript = "boot.ipxe"
            let iscsiRootPath = "iscsi:\(config.bootServerIP):tcp:3260:0:iqn.2026-07.com.aemachboot:target0"
            
            reply.file = tftpScript
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = tftpScript.data(using: .ascii)
            reply.options[17] = iscsiRootPath.data(using: .ascii)
            
            var opt43 = Data()
            opt43.append(6); opt43.append(1); opt43.append(7)
            opt43.append(255)
            reply.options[43] = opt43
        } else {
            let bootFile = getBootFileName(for: request)
            reply.file = bootFile
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = bootFile.data(using: .ascii)
            
            var opt43 = Data()
            opt43.append(6); opt43.append(1); opt43.append(7)
            opt43.append(10); opt43.append(2); opt43.append(0); opt43.append(0)
            
            opt43.append(8); opt43.append(7)
            opt43.append(0); opt43.append(0)
            opt43.append(1)
            opt43.append(contentsOf: ipBytes)
            
            opt43.append(71); opt43.append(4)
            opt43.append(0); opt43.append(0)
            opt43.append(0); opt43.append(0)
            
            opt43.append(255)
            reply.options[43] = opt43
        }
        
        sendPacket(reply, forceBroadcast: true)
    }
    
    private func sendStandardOffer(for discover: DHCPPacket) {
        let isStage2 = shouldDeliverStage2(for: discover)
        guard let startIP = config.startIPRange else { return }
        
        var reply = DHCPPacket()
        reply.op = 2
        reply.xid = discover.xid
        reply.flags = discover.flags
        reply.chaddr = discover.chaddr
        
        reply.yiaddr = convertIPStringToUInt32(startIP)
        reply.siaddr = convertIPStringToUInt32(config.bootServerIP)
        
        reply.options[53] = Data([DHCPMessageType.offer.rawValue])
        reply.options[54] = Data(unpackIP(config.localIP))
        reply.options[1] = Data(unpackIP(config.subnetMask))
        if let router = config.routerIP {
            reply.options[3] = Data(unpackIP(router))
        }
        
        if isStage2 {
            let tftpScript = "boot.ipxe"
            let iscsiRootPath = "iscsi:\(config.bootServerIP):tcp:3260:0:iqn.2026-07.com.aemachboot:target0"
            
            logger.info("💥 [Standard Mode Stage 2 Active] Handing TFTP Script '\(tftpScript)' & iSCSI Root-Path to IP \(startIP)", sys: "com.aemachboot.network", cat: "DHCP")
            
            reply.file = tftpScript
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = tftpScript.data(using: .ascii)
            reply.options[17] = iscsiRootPath.data(using: .ascii)
        } else {
            let bootFile = getBootFileName(for: discover)
            logger.info("Formulating Standard DHCP Offer (Native PXE Stage 1, Assigned IP: \(startIP), BootFile: \(bootFile))...", sys: "com.aemachboot.network", cat: "DHCP")
            
            reply.file = bootFile
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = bootFile.data(using: .ascii)
            
            // 💥【关键修复】：根据 RFC 标准，Standard 模式下不塞 Option 60/43，避免 UEFI 厂商解释器抛错！
        }
        
        sendPacket(reply, forceBroadcast: true)
    }
    
    private func sendStandardAck(for request: DHCPPacket) {
        let isStage2 = shouldDeliverStage2(for: request)
        guard let startIP = config.startIPRange else { return }
        
        var reply = DHCPPacket()
        reply.op = 2
        reply.xid = request.xid
        reply.flags = request.flags
        reply.chaddr = request.chaddr
        
        reply.yiaddr = convertIPStringToUInt32(startIP)
        reply.siaddr = convertIPStringToUInt32(config.bootServerIP)
        
        reply.options[53] = Data([DHCPMessageType.ack.rawValue])
        reply.options[54] = Data(unpackIP(config.localIP))
        reply.options[1] = Data(unpackIP(config.subnetMask))
        if let router = config.routerIP {
            reply.options[3] = Data(unpackIP(router))
        }
        
        if isStage2 {
            let tftpScript = "boot.ipxe"
            let iscsiRootPath = "iscsi:\(config.bootServerIP):tcp:3260:0:iqn.2026-07.com.aemachboot:target0"
            
            reply.file = tftpScript
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = tftpScript.data(using: .ascii)
            reply.options[17] = iscsiRootPath.data(using: .ascii)
        } else {
            let bootFile = getBootFileName(for: request)
            reply.file = bootFile
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = bootFile.data(using: .ascii)
            
            // 💥【关键修复】：Standard ACK 同样移除 Option 60/43，解决 UEFI 拿到 ACK 瞬间掉入 Shell 的死穴！
        }
        
        sendPacket(reply, forceBroadcast: true)
    }
    
    private func sendPacket(_ packet: DHCPPacket, forceBroadcast: Bool = true) {
        let serializedData = packet.serialize()
        
        var destAddr = sockaddr_in()
        destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = in_port_t(68).bigEndian
        
        if forceBroadcast || packet.ciaddr == 0 || (packet.flags & 0x8000) != 0 || packet.yiaddr == 0 {
            destAddr.sin_addr.s_addr = INADDR_BROADCAST.bigEndian
        } else {
            destAddr.sin_addr.s_addr = packet.yiaddr.bigEndian
        }
        
        var sendResult = withUnsafePointer(to: &destAddr) { destPtr -> Int in
            destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                serializedData.withUnsafeBytes { dataBytes in
                    sendto(socketFd, dataBytes.baseAddress, serializedData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        
        if sendResult < 0 && (forceBroadcast || packet.ciaddr == 0 || (packet.flags & 0x8000) != 0 || packet.yiaddr == 0) {
            let subnetIP = getSubnetBroadcastAddress(ip: config.localIP, mask: config.subnetMask)
            inet_pton(AF_INET, subnetIP, &destAddr.sin_addr)
            
            sendResult = withUnsafePointer(to: &destAddr) { destPtr -> Int in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    serializedData.withUnsafeBytes { dataBytes in
                        sendto(socketFd, dataBytes.baseAddress, serializedData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        
        if sendResult < 0 {
            let err = errno
            let errStr = String(cString: strerror(err))
            logger.error("DHCP Send FAIL! Errno: \(err) (\(errStr))", sys: "com.aemachboot.network", cat: "DHCP")
        } else {
            let destIPStr = String(cString: inet_ntoa(destAddr.sin_addr))
            logger.info("DHCP Send SUCCESS! Sent \(sendResult) bytes to \(destIPStr):68 (XID: \(String(format: "0x%08X", packet.xid)))", sys: "com.aemachboot.network", cat: "DHCP")
        }
    }
    
    private func getBootFileName(for packet: DHCPPacket) -> String {
        if let archData = packet.options[93], archData.count >= 2 {
            let arch = UInt16(archData[0]) << 8 | UInt16(archData[1])
            if arch == 0 {
                return "ipxe.kpxe"
            }
        }
        return config.bootFileName
    }
    
    private func convertIPStringToUInt32(_ ipString: String) -> UInt32 {
        var addr = in_addr()
        if inet_pton(AF_INET, ipString, &addr) == 1 {
            return addr.s_addr.bigEndian
        }
        return 0
    }
    
    private func unpackIP(_ ipStr: String) -> [UInt8] {
        var addr = in_addr()
        guard inet_pton(AF_INET, ipStr, &addr) == 1 else { return [0, 0, 0, 0] }
        let rawVal = addr.s_addr.bigEndian
        return [
            UInt8((rawVal >> 24) & 0xFF),
            UInt8((rawVal >> 16) & 0xFF),
            UInt8((rawVal >> 8) & 0xFF),
            UInt8(rawVal & 0xFF)
        ]
    }
    
    private func formatIP(_ ip: UInt32) -> String {
        let bytes = [
            UInt8((ip >> 24) & 0xFF),
            UInt8((ip >> 16) & 0xFF),
            UInt8((ip >> 8) & 0xFF),
            UInt8(ip & 0xFF)
        ]
        return bytes.map { String($0) }.joined(separator: ".")
    }
    
    private func getSubnetBroadcastAddress(ip: String, mask: String) -> String {
        var ipAddr = in_addr()
        var maskAddr = in_addr()
        guard inet_pton(AF_INET, ip, &ipAddr) == 1, inet_pton(AF_INET, mask, &maskAddr) == 1 else {
            return "255.255.255.255"
        }
        let broadcastBinary = ipAddr.s_addr | (~maskAddr.s_addr)
        var broadcastInAddr = in_addr(s_addr: broadcastBinary)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &broadcastInAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
            return String(cString: buf)
        }
        return "255.255.255.255"
    }
    
    private func start4011Listener() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        
        var optVal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optVal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &optVal, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(4011).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        
        let bindStatus = withUnsafePointer(to: &addr, { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        })
        
        guard bindStatus == 0 else {
            close(fd)
            logger.warn("ProxyDHCP secondary port 4011 binding failed.", sys: "com.aemachboot.network", cat: "DHCP")
            return
        }
        
        self.socketFd4011 = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleIncomingData4011()
        }
        source.resume()
        self.readSource4011 = source
        logger.info("ProxyDHCP secondary listener active on Port 4011", sys: "com.aemachboot.network", cat: "DHCP")
    }
    
    private func handleIncomingData4011() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let readBytes = withUnsafeMutablePointer(to: &clientAddr) { addrPtr -> Int in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                recvfrom(socketFd4011, &buffer, buffer.count, 0, sockaddrPtr, &addrLen)
            }
        }
        
        guard readBytes > 0 else { return }
        let packetData = Data(bytes: buffer, count: readBytes)
        
        do {
            let packet = try DHCPPacket(rawBytes: packetData)
            process4011Request(packet, clientAddr: clientAddr)
        } catch {
            logger.warn("Malformed 4011 packet ignored.", sys: "com.aemachboot.network", cat: "DHCP")
        }
    }
    
    private func process4011Request(_ incoming: DHCPPacket, clientAddr: sockaddr_in) {
        logger.info("Received Port 4011 BINL Request from PXE client. XID: \(String(format: "0x%08X", incoming.xid))", sys: "com.aemachboot.network", cat: "DHCP")
        
        let isStage2 = shouldDeliverStage2(for: incoming)
        var reply = DHCPPacket()
        reply.op = 2
        reply.xid = incoming.xid
        reply.flags = incoming.flags
        reply.chaddr = incoming.chaddr
        
        reply.yiaddr = incoming.ciaddr
        reply.siaddr = convertIPStringToUInt32(config.bootServerIP)
        
        reply.options[53] = Data([DHCPMessageType.ack.rawValue])
        reply.options[54] = Data(unpackIP(config.localIP))
        reply.options[60] = "PXEClient".data(using: .ascii)
        
        if isStage2 {
            let tftpScript = "boot.ipxe"
            let iscsiRootPath = "iscsi:\(config.bootServerIP):tcp:3260:0:iqn.2026-07.com.aemachboot:target0"
            
            reply.file = tftpScript
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = tftpScript.data(using: .ascii)
            reply.options[17] = iscsiRootPath.data(using: .ascii)
        } else {
            let bootFile = getBootFileName(for: incoming)
            reply.file = bootFile
            reply.options[66] = config.bootServerIP.data(using: .ascii)
            reply.options[67] = bootFile.data(using: .ascii)
        }
        
        let serializedData = reply.serialize()
        var dest = clientAddr
        
        let sendResult = withUnsafePointer(to: &dest) { destPtr -> Int in
            destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                serializedData.withUnsafeBytes { dataBytes in
                    sendto(socketFd4011, dataBytes.baseAddress, serializedData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        
        if sendResult < 0 {
            logger.error("Failed to transmit 4011 ACK response. Error code: \(errno)", sys: "com.aemachboot.network", cat: "DHCP")
        } else {
            logger.info("Successfully sent 4011 PXE Boot ACK to client.", sys: "com.aemachboot.network", cat: "DHCP")
        }
    }
}
