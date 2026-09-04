import Foundation

/// iSCSI 协议操作码 (RFC 3720)
public enum iSCSIOpcode: UInt8, Sendable {
    // Initiator -> Target
    case nopOut          = 0x00
    case scsiCommand     = 0x01
    case scsiTaskReq     = 0x02
    case loginReq        = 0x03
    case textReq         = 0x04
    case scsiDataOut     = 0x05
    case logoutReq       = 0x06
    
    // Target -> Initiator
    case nopIn           = 0x20
    case scsiResponse    = 0x21
    case taskResp        = 0x22
    case loginResp       = 0x23
    case textResp        = 0x24
    case scsiDataIn      = 0x25
    case logoutResp      = 0x26
    case r2t             = 0x31
}

/// iSCSI 连接状态机
public enum iSCSIConnectionState: Sendable {
    case free
    case securityNegotiation
    case loginOperationalNegotiation
    case fullFeaturePhase
    case logoutInProgress
    case closed
}

/// iSCSI PDU (Protocol Data Unit) 头部及载荷封装结构
public struct iSCSIPDU: Sendable {
    public var bhs: Data
    public var ahs: Data = Data()
    public var dataSegment: Data = Data()
    
    public init(bhs: Data) {
        self.bhs = bhs
    }
    
    public init(opcode: iSCSIOpcode, dataSegmentLength: Int) {
        var bhs = Data(repeating: 0, count: 48)
        bhs[0] = opcode.rawValue
        
        let len = UInt32(dataSegmentLength)
        bhs[5] = UInt8((len >> 16) & 0xFF)
        bhs[6] = UInt8((len >> 8) & 0xFF)
        bhs[7] = UInt8(len & 0xFF)
        
        self.bhs = bhs
    }
    
    public var opcode: UInt8 {
        get { bhs[0] & 0x3F }
        set { bhs[0] = (bhs[0] & 0xC0) | (newValue & 0x3F) }
    }
    
    public var immediateFlag: Bool {
        get { (bhs[0] & 0x80) != 0 }
        set { bhs[0] = newValue ? (bhs[0] | 0x80) : (bhs[0] & 0x7F) }
    }
    
    public var finalFlag: Bool {
        get { (bhs[1] & 0x80) != 0 }
        set { bhs[1] = newValue ? (bhs[1] | 0x80) : (bhs[1] & 0x7F) }
    }
    
    public var transitFlag: Bool {
        get { (bhs[1] & 0x80) != 0 }
        set { bhs[1] = newValue ? (bhs[1] | 0x80) : (bhs[1] & 0x7F) }
    }
    
    public var csg: UInt8 {
        get { (bhs[1] & 0x0C) >> 2 }
        set { bhs[1] = (bhs[1] & 0xF3) | ((newValue & 0x03) << 2) }
    }
    
    public var nsg: UInt8 {
        get { bhs[1] & 0x03 }
        set { bhs[1] = (bhs[1] & 0xFC) | (newValue & 0x03) }
    }
    
    public var dataSegmentLength: Int {
        get {
            let high = Int(bhs[5]) << 16
            let mid  = Int(bhs[6]) << 8
            let low  = Int(bhs[7])
            return high | mid | low
        }
        set {
            let len = UInt32(newValue)
            bhs[5] = UInt8((len >> 16) & 0xFF)
            bhs[6] = UInt8((len >> 8) & 0xFF)
            bhs[7] = UInt8(len & 0xFF)
        }
    }
    
    public var lun: UInt64 {
        get {
            bhs.withUnsafeBytes { rawBuffer in
                rawBuffer.load(fromByteOffset: 8, as: UInt64.self).bigEndian
            }
        }
    }
    
    public var tpgt: UInt16 {
        get {
            bhs.withUnsafeBytes { rawBuffer in
                rawBuffer.load(fromByteOffset: 12, as: UInt16.self).bigEndian
            }
        }
        set {
            let val = newValue.bigEndian
            withUnsafeBytes(of: val) { bytes in
                bhs[12] = bytes[0]
                bhs[13] = bytes[1]
            }
        }
    }
    
    public var tsih: UInt16 {
        get {
            bhs.withUnsafeBytes { rawBuffer in
                rawBuffer.load(fromByteOffset: 14, as: UInt16.self).bigEndian
            }
        }
        set {
            let val = newValue.bigEndian
            withUnsafeBytes(of: val) { bytes in
                bhs[14] = bytes[0]
                bhs[15] = bytes[1]
            }
        }
    }
    
    public var initiatorTaskTag: UInt32 {
        get {
            bhs.withUnsafeBytes { rawBuffer in
                rawBuffer.load(fromByteOffset: 16, as: UInt32.self).bigEndian
            }
        }
        set {
            let val = newValue.bigEndian
            withUnsafeBytes(of: val) { bytes in
                for i in 0..<4 { bhs[16 + i] = bytes[i] }
            }
        }
    }
    
    public var statSN: UInt32 {
        get {
            bhs.withUnsafeBytes { rawBuffer in
                rawBuffer.load(fromByteOffset: 24, as: UInt32.self).bigEndian
            }
        }
        set {
            let val = newValue.bigEndian
            withUnsafeBytes(of: val) { bytes in
                for i in 0..<4 { bhs[24 + i] = bytes[i] }
            }
        }
    }
    
    public var expCmdSN: UInt32 {
        get {
            bhs.withUnsafeBytes { rawBuffer in
                rawBuffer.load(fromByteOffset: 28, as: UInt32.self).bigEndian
            }
        }
        set {
            let val = newValue.bigEndian
            withUnsafeBytes(of: val) { bytes in
                for i in 0..<4 { bhs[28 + i] = bytes[i] }
            }
        }
    }
    
    public var maxCmdSN: UInt32 {
        get {
            bhs.withUnsafeBytes { rawBuffer in
                rawBuffer.load(fromByteOffset: 32, as: UInt32.self).bigEndian
            }
        }
        set {
            let val = newValue.bigEndian
            withUnsafeBytes(of: val) { bytes in
                for i in 0..<4 { bhs[32 + i] = bytes[i] }
            }
        }
    }
}

/// 工业级 iSCSI 物理连接状态管理器
public final class iSCSIConnection: @unchecked Sendable {
    public let clientFd: Int32
    public var state: iSCSIConnectionState = .free
    
    private var statSN: UInt32 = 1
    private var expCmdSN: UInt32 = 0
    private var maxCmdSN: UInt32 = 128
    
    private var maxRecvDataSegmentLength: Int = 262144
    private var initiatorName: String = ""
    private var targetName: String = ""
    
    private let scsiHandler: SCSICommandHandler
    private let logger: AEMachLogger
    private let lock = NSLock()
    
    // 写事务（Data-Out / R2T）状态上下文
    private var currentTTT: UInt32 = 0xAA000000
    private var expectedWriteOffset: UInt32 = 0
    private var expectedWriteLen: UInt32 = 0
    private var activeWriteITT: UInt32 = 0
    private var activeWriteCDB: Data = Data()
    private var accumulatedWriteBuffer = Data()
    
    public init(clientFd: Int32, scsiHandler: SCSICommandHandler, logger: AEMachLogger) {
        self.clientFd = clientFd
        self.scsiHandler = scsiHandler
        self.logger = logger
        
        var optVal: Int32 = 1
        setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &optVal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(clientFd, SOL_SOCKET, SO_KEEPALIVE, &optVal, socklen_t(MemoryLayout<Int32>.size))
    }
    
    deinit {
        close(clientFd)
    }
    
    public func runSessionLoop() {
        self.state = .securityNegotiation
        var bhsBuffer = [UInt8](repeating: 0, count: 48)
        
        while true {
            let readBytes = recvExact(clientFd, buffer: &bhsBuffer, length: 48)
            guard readBytes == 48 else {
                logger.info("iSCSI connection closed by peer.", sys: "com.aemachboot.iscsi", cat: "Session")
                break
            }
            
            var pdu = iSCSIPDU(bhs: Data(bhsBuffer))
            let dataLen = pdu.dataSegmentLength
            
            if dataLen > 0 {
                let padding = (4 - (dataLen % 4)) % 4
                var payloadBuffer = [UInt8](repeating: 0, count: dataLen + padding)
                
                let payloadReadBytes = recvExact(clientFd, buffer: &payloadBuffer, length: dataLen + padding)
                guard payloadReadBytes == dataLen + padding else {
                    logger.error("Failed to read expected data segment size: \(dataLen) + padding \(padding)", sys: "com.aemachboot.iscsi", cat: "Session")
                    break
                }
                pdu.dataSegment = Data(payloadBuffer.prefix(dataLen))
            }
            
            do {
                try dispatchPDU(pdu)
            } catch {
                logger.error("iSCSI protocol violation: \(error.localizedDescription). Resetting session.", sys: "com.aemachboot.iscsi", cat: "Session")
                break
            }
        }
        
        self.state = .closed
    }
    
    private func dispatchPDU(_ pdu: iSCSIPDU) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let rawOpcode = pdu.opcode
        
        if rawOpcode != 0x03 {
            let cmdSN = pdu.bhs.withUnsafeBytes { rawBuffer in
                rawBuffer.load(fromByteOffset: 24, as: UInt32.self).bigEndian
            }
            if cmdSN >= self.expCmdSN {
                self.expCmdSN = cmdSN + 1
                self.maxCmdSN = self.expCmdSN + 128
            }
        }
        
        switch rawOpcode {
        case 0x03: // Login Request
            try handleLoginRequest(pdu)
            
        case 0x01: // SCSI Command
            try handleSCSICommand(pdu)
            
        case 0x02: // Task Management Request
            try handleTaskManagementRequest(pdu)
            
        case 0x04: // Text Request
            try handleTextRequest(pdu)
            
        case 0x05: // SCSI Data-Out
            try handleSCSIDataOut(pdu)
            
        case 0x06: // Logout Request
            try handleLogoutRequest(pdu)
            
        case 0x00: // NOP-Out
            try handleNopOut(pdu)
            
        default:
            logger.warn("Unimplemented iSCSI Opcode [0x\(String(format: "%02X", rawOpcode))] received.", sys: "com.aemachboot.iscsi", cat: "Session")
            break
        }
    }
    
    private func handleLoginRequest(_ pdu: iSCSIPDU) throws {
        logger.info("iSCSI Login Request received. CSG: \(pdu.csg), NSG: \(pdu.nsg)", sys: "com.aemachboot.iscsi", cat: "Session")
        
        let cmdSN = pdu.bhs.withUnsafeBytes { rawBuffer in
            rawBuffer.load(fromByteOffset: 24, as: UInt32.self).bigEndian
        }
        self.expCmdSN = cmdSN + 1
        self.maxCmdSN = self.expCmdSN + 128
        
        let textSegment = String(data: pdu.dataSegment, encoding: .utf8) ?? ""
        let lines = textSegment.components(separatedBy: "\0")
        var responseParams = [String: String]()
        
        responseParams["TargetPortalGroupTag"] = "1"
        
        for line in lines {
            if line.isEmpty { continue }
            let kv = line.components(separatedBy: "=")
            if kv.count == 2 {
                let key = kv[0]
                let value = kv[1]
                logger.debug("Negotiating -> Key: \(key), Val: \(value)", sys: "com.aemachboot.iscsi", cat: "Session")
                
                switch key {
                case "InitiatorName":
                    self.initiatorName = value
                case "TargetName":
                    self.targetName = value
                case "SessionType":
                    responseParams["SessionType"] = value
                case "AuthMethod":
                    responseParams["AuthMethod"] = "None"
                case "HeaderDigest", "DataDigest":
                    responseParams[key] = "None"
                case "MaxRecvDataSegmentLength":
                    if let clientMax = Int(value) {
                        self.maxRecvDataSegmentLength = min(262144, clientMax)
                        responseParams["MaxRecvDataSegmentLength"] = "\(self.maxRecvDataSegmentLength)"
                    }
                case "FirstBurstLength":
                    responseParams["FirstBurstLength"] = "262144"
                case "MaxBurstLength":
                    responseParams["MaxBurstLength"] = "262144"
                case "ImmediateData":
                    responseParams["ImmediateData"] = (value.lowercased() == "yes") ? "Yes" : "No"
                case "InitialR2T":
                    responseParams["InitialR2T"] = "Yes"
                case "MaxOutstandingR2T":
                    responseParams["MaxOutstandingR2T"] = "1"
                case "DataPDUInOrder":
                    responseParams["DataPDUInOrder"] = "Yes"
                case "DataSequenceInOrder":
                    responseParams["DataSequenceInOrder"] = "Yes"
                case "ErrorRecoveryLevel":
                    responseParams["ErrorRecoveryLevel"] = "0"
                case "DefaultTime2Wait":
                    responseParams["DefaultTime2Wait"] = "2"
                case "DefaultTime2Retain":
                    responseParams["DefaultTime2Retain"] = "20"
                default:
                    break
                }
            }
        }
        
        var respText = ""
        for (k, v) in responseParams {
            respText += "\(k)=\(v)\0"
        }
        let respData = respText.data(using: .utf8) ?? Data()
        
        var responsePDU = iSCSIPDU(opcode: .loginResp, dataSegmentLength: respData.count)
        responsePDU.initiatorTaskTag = pdu.initiatorTaskTag
        
        responsePDU.bhs[2] = 0x00 // Version-max
        responsePDU.bhs[3] = 0x00 // Version-active
        
        for i in 8...13 {
            responsePDU.bhs[i] = pdu.bhs[i]
        }
        
        responsePDU.tsih = 1
        
        if pdu.transitFlag {
            responsePDU.transitFlag = true
            responsePDU.csg = pdu.csg
            responsePDU.nsg = pdu.nsg
            
            responsePDU.bhs[20] = 0xFF
            responsePDU.bhs[21] = 0xFF
            responsePDU.bhs[22] = 0xFF
            responsePDU.bhs[23] = 0xFF
            
            if pdu.nsg == 3 {
                self.state = .fullFeaturePhase
                logger.info("iSCSI Session successfully entered FULL FEATURE PHASE (FFP)!", sys: "com.aemachboot.iscsi", cat: "Session")
            }
        } else {
            responsePDU.transitFlag = false
            responsePDU.csg = pdu.csg
            responsePDU.nsg = pdu.csg
        }
        
        responsePDU.statSN = statSN
        statSN += 1
        responsePDU.expCmdSN = expCmdSN
        responsePDU.maxCmdSN = maxCmdSN
        responsePDU.dataSegment = respData
        
        try sendPDU(responsePDU)
    }
    
    private func handleSCSICommand(_ pdu: iSCSIPDU) throws {
        let cdb = pdu.bhs.subdata(in: 32..<48)
        let edtl = pdu.bhs.withUnsafeBytes { rawBuffer in
            rawBuffer.load(fromByteOffset: 20, as: UInt32.self).bigEndian
        }
        let opCode = cdb[0]
        
        var writePayload: Data? = nil
        if pdu.dataSegmentLength > 0 {
            writePayload = pdu.dataSegment
        }
        
        logger.trace("SCSI Command [0x\(String(format: "%02X", opCode))] EDTL: \(edtl), ITT: \(pdu.initiatorTaskTag)", sys: "com.aemachboot.iscsi", cat: "SCSI")
        
        // 判断是否为写指令 (WRITE 6 / WRITE 10 / WRITE 16) 且需要后续 Data-Out 帧
        let isWriteOp = (opCode == 0x0A || opCode == 0x2A || opCode == 0x8A)
        let immediateDataCount = UInt32(writePayload?.count ?? 0)
        
        if isWriteOp && immediateDataCount < edtl {
            self.activeWriteITT = pdu.initiatorTaskTag
            self.activeWriteCDB = cdb
            self.expectedWriteOffset = immediateDataCount
            self.expectedWriteLen = edtl - immediateDataCount
            self.accumulatedWriteBuffer = writePayload ?? Data()
            self.currentTTT += 1
            
            try sendR2T(itt: pdu.initiatorTaskTag, offset: expectedWriteOffset, length: expectedWriteLen)
            return
        }
        
        // 读指令或一次性附带完整 Immediate Data 的写指令
        let response = scsiHandler.processCDB(cdb, writeData: writePayload)
        
        if response.status == .good && !response.responseData.isEmpty {
            try sendSCSIReadData(itt: pdu.initiatorTaskTag, data: response.responseData)
        } else {
            try sendSCSIResponse(itt: pdu.initiatorTaskTag, response: response)
        }
    }
    
    private func handleSCSIDataOut(_ pdu: iSCSIPDU) throws {
        let itt = pdu.initiatorTaskTag
        let targetTransferTag = pdu.bhs.withUnsafeBytes { rawBuffer in
            rawBuffer.load(fromByteOffset: 20, as: UInt32.self).bigEndian
        }
        let bufferOffset = pdu.bhs.withUnsafeBytes { rawBuffer in
            rawBuffer.load(fromByteOffset: 40, as: UInt32.self).bigEndian
        }
        
        guard itt == activeWriteITT, targetTransferTag == currentTTT else {
            logger.error("Out-of-band Data-Out packet ignored. ITT mismatch (\(itt) vs \(activeWriteITT))", sys: "com.aemachboot.iscsi", cat: "SCSI")
            return
        }
        
        accumulatedWriteBuffer.append(pdu.dataSegment)
        
        let totalReceived = UInt32(accumulatedWriteBuffer.count)
        let totalExpected = expectedWriteOffset + expectedWriteLen
        
        if bufferOffset + UInt32(pdu.dataSegmentLength) >= totalExpected || totalReceived >= totalExpected {
            // 【关键修复】：透传完整的原始 activeWriteCDB 和最终累计的数据缓冲区
            let response = scsiHandler.processCDB(activeWriteCDB, writeData: accumulatedWriteBuffer)
            
            try sendSCSIResponse(itt: itt, response: response)
            
            self.activeWriteITT = 0
            self.activeWriteCDB = Data()
            self.accumulatedWriteBuffer.removeAll()
        }
    }
    
    private func handleLogoutRequest(_ pdu: iSCSIPDU) throws {
        logger.info("iSCSI Logout Request received. Terminating session...", sys: "com.aemachboot.iscsi", cat: "Session")
        
        var responsePDU = iSCSIPDU(opcode: .logoutResp, dataSegmentLength: 0)
        responsePDU.finalFlag = true
        responsePDU.initiatorTaskTag = pdu.initiatorTaskTag
        responsePDU.statSN = statSN
        statSN += 1
        responsePDU.expCmdSN = expCmdSN
        responsePDU.maxCmdSN = maxCmdSN
        responsePDU.bhs[2] = 0 // Success
        
        try sendPDU(responsePDU)
        self.state = .logoutInProgress
    }
    
    private func handleNopOut(_ pdu: iSCSIPDU) throws {
        var responsePDU = iSCSIPDU(opcode: .nopIn, dataSegmentLength: 0)
        responsePDU.finalFlag = true
        responsePDU.initiatorTaskTag = pdu.initiatorTaskTag
        responsePDU.statSN = statSN
        statSN += 1
        responsePDU.expCmdSN = expCmdSN
        responsePDU.maxCmdSN = maxCmdSN
        
        responsePDU.bhs[20] = pdu.bhs[20]
        responsePDU.bhs[21] = pdu.bhs[21]
        responsePDU.bhs[22] = pdu.bhs[22]
        responsePDU.bhs[23] = pdu.bhs[23]
        
        try sendPDU(responsePDU)
    }
    
    private func handleTaskManagementRequest(_ pdu: iSCSIPDU) throws {
        let functionCode: UInt8 = pdu.bhs[1] & 0x7F
        logger.info("iSCSI Task Management Function [0x\(String(format: "%02X", functionCode))] received.", sys: "com.aemachboot.iscsi", cat: "Session")
        
        var responsePDU = iSCSIPDU(opcode: .taskResp, dataSegmentLength: 0)
        responsePDU.finalFlag = true
        responsePDU.initiatorTaskTag = pdu.initiatorTaskTag
        
        responsePDU.bhs[2] = 0x00 // Function Complete
        
        responsePDU.statSN = statSN
        statSN += 1
        responsePDU.expCmdSN = expCmdSN
        responsePDU.maxCmdSN = maxCmdSN
        
        try sendPDU(responsePDU)
    }

    private func handleTextRequest(_ pdu: iSCSIPDU) throws {
        logger.info("iSCSI Text Request received.", sys: "com.aemachboot.iscsi", cat: "Session")
        
        let textSegment = String(data: pdu.dataSegment, encoding: .utf8) ?? ""
        var responseParams = [String: String]()
        
        if textSegment.contains("SendTargets=") {
            responseParams["TargetName"] = "iqn.2026-07.com.aemachboot:target0"
            responseParams["TargetAddress"] = "0.0.0.0:3260,1"
        }
        
        var respText = ""
        for (k, v) in responseParams {
            respText += "\(k)=\(v)\0"
        }
        let respData = respText.data(using: .utf8) ?? Data()
        
        var responsePDU = iSCSIPDU(opcode: .textResp, dataSegmentLength: respData.count)
        responsePDU.finalFlag = true
        responsePDU.initiatorTaskTag = pdu.initiatorTaskTag
        
        responsePDU.bhs[20] = 0xFF
        responsePDU.bhs[21] = 0xFF
        responsePDU.bhs[22] = 0xFF
        responsePDU.bhs[23] = 0xFF
        
        responsePDU.statSN = statSN
        statSN += 1
        responsePDU.expCmdSN = expCmdSN
        responsePDU.maxCmdSN = maxCmdSN
        responsePDU.dataSegment = respData
        
        try sendPDU(responsePDU)
    }
    
    private func sendSCSIReadData(itt: UInt32, data: Data) throws {
        var offset = 0
        var dataSN: UInt32 = 0
        let totalSize = data.count
        
        while offset < totalSize {
            let chunkLen = min(maxRecvDataSegmentLength, totalSize - offset)
            let isFinal = (offset + chunkLen) >= totalSize
            
            var dataInPDU = iSCSIPDU(opcode: .scsiDataIn, dataSegmentLength: chunkLen)
            dataInPDU.finalFlag = isFinal
            dataInPDU.initiatorTaskTag = itt
            
            if isFinal {
                dataInPDU.bhs[1] |= 0x01 // S-flag: Status present
                dataInPDU.bhs[3] = 0x00 // SCSI Status = GOOD
            }
            
            dataInPDU.statSN = statSN
            if isFinal {
                statSN += 1
            }
            
            dataInPDU.expCmdSN = expCmdSN
            dataInPDU.maxCmdSN = maxCmdSN
            
            let dataSNBE = dataSN.bigEndian
            withUnsafeBytes(of: dataSNBE) { bytes in
                for i in 0..<4 { dataInPDU.bhs[36 + i] = bytes[i] }
            }
            dataSN += 1
            
            let offsetBE = UInt32(offset).bigEndian
            withUnsafeBytes(of: offsetBE) { bytes in
                for i in 0..<4 { dataInPDU.bhs[40 + i] = bytes[i] }
            }
            
            dataInPDU.dataSegment = data.subdata(in: offset..<(offset + chunkLen))
            offset += chunkLen
            
            try sendPDU(dataInPDU)
        }
    }
    
    private func sendR2T(itt: UInt32, offset: UInt32, length: UInt32) throws {
        var r2tPDU = iSCSIPDU(opcode: .r2t, dataSegmentLength: 0)
        r2tPDU.finalFlag = true
        r2tPDU.initiatorTaskTag = itt
        
        let tttBE = currentTTT.bigEndian
        withUnsafeBytes(of: tttBE) { bytes in
            for i in 0..<4 { r2tPDU.bhs[20 + i] = bytes[i] }
        }
        
        r2tPDU.statSN = statSN
        statSN += 1
        r2tPDU.expCmdSN = expCmdSN
        r2tPDU.maxCmdSN = maxCmdSN
        
        let offsetBE = offset.bigEndian
        withUnsafeBytes(of: offsetBE) { bytes in
            for i in 0..<4 { r2tPDU.bhs[40 + i] = bytes[i] }
        }
        
        let lenBE = length.bigEndian
        withUnsafeBytes(of: lenBE) { bytes in
            for i in 0..<4 { r2tPDU.bhs[44 + i] = bytes[i] }
        }
        
        try sendPDU(r2tPDU)
    }
    
    private func sendSCSIResponse(itt: UInt32, response: SCSIResponse) throws {
        let hasSense = response.status == .checkCondition
        let senseLength = hasSense ? response.senseData.count : 0
        
        var dataSegment = Data()
        if hasSense {
            var senseLenBE = UInt16(senseLength).bigEndian
            dataSegment.append(UnsafeBufferPointer(start: &senseLenBE, count: 1))
            dataSegment.append(response.senseData)
        }
        
        var responsePDU = iSCSIPDU(opcode: .scsiResponse, dataSegmentLength: dataSegment.count)
        responsePDU.finalFlag = true
        responsePDU.initiatorTaskTag = itt
        
        responsePDU.statSN = statSN
        statSN += 1
        responsePDU.expCmdSN = expCmdSN
        responsePDU.maxCmdSN = maxCmdSN
        
        responsePDU.bhs[3] = response.status.rawValue
        responsePDU.dataSegment = dataSegment
        
        try sendPDU(responsePDU)
    }
    
    private func sendPDU(_ pdu: iSCSIPDU) throws {
        var packet = Data()
        packet.append(pdu.bhs)
        packet.append(pdu.dataSegment)
        
        let dataLen = pdu.dataSegment.count
        let padding = (4 - (dataLen % 4)) % 4
        if padding > 0 {
            packet.append(Data(repeating: 0, count: padding))
        }
        
        let result = packet.withUnsafeBytes { rawBuffer -> Int in
            send(clientFd, rawBuffer.baseAddress, packet.count, 0)
        }
        
        if result < 0 {
            throw NSError(domain: "iSCSIConnection", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "TCP socket transmission error"])
        }
    }
    
    private func recvExact(_ fd: Int32, buffer: inout [UInt8], length: Int) -> Int {
        var totalBytesReceived = 0
        while totalBytesReceived < length {
            let leftToRead = length - totalBytesReceived
            let bytesRead = recv(fd, &buffer[totalBytesReceived], leftToRead, 0)
            guard bytesRead > 0 else {
                return bytesRead
            }
            totalBytesReceived += bytesRead
        }
        return totalBytesReceived
    }
}

public final class iSCSITarget: @unchecked Sendable {
    private var listenSocketFd: Int32 = -1
    private let port: UInt16 = 3260
    private let scsiHandler: SCSICommandHandler
    private let logger: AEMachLogger
    private let queue: DispatchQueue
    private var isRunning: Bool = false
    private let lock = NSLock()
    
    public init(scsiHandler: SCSICommandHandler, logger: AEMachLogger = .shared) {
        self.scsiHandler = scsiHandler
        self.logger = logger
        self.queue = DispatchQueue(label: "com.aemachboot.iscsi.target", qos: .userInteractive, attributes: .concurrent)
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
            throw NSError(domain: "iSCSITarget", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create iSCSI socket"])
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
            logger.error("iSCSI Target failed binding to port 3260 (Errno: \(err)).", sys: "com.aemachboot.iscsi", cat: "Server")
            throw NSError(domain: "iSCSITarget", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "iSCSI bind failed"])
        }
        
        guard listen(fd, 64) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: "iSCSITarget", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "iSCSI listen failed"])
        }
        
        self.listenSocketFd = fd
        self.isRunning = true
        
        logger.info("iSCSI Target active and ready for diskless connections on TCP Port 3260.", sys: "com.aemachboot.iscsi", cat: "Server")
        
        queue.async { [weak self] in
            self?.acceptConnections()
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
        logger.info("iSCSI Target has shut down.", sys: "com.aemachboot.iscsi", cat: "Server")
    }
    
    private func acceptConnections() {
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
            
            let clientIP = String(cString: inet_ntoa(clientAddr.sin_addr))
            logger.info("New diskless host initiator connected: \(clientIP)", sys: "com.aemachboot.iscsi", cat: "Server")
            
            queue.async { [weak self] in
                guard let self = self else { return }
                let connection = iSCSIConnection(clientFd: clientFd, scsiHandler: self.scsiHandler, logger: self.logger)
                connection.runSessionLoop()
            }
        }
    }
}
