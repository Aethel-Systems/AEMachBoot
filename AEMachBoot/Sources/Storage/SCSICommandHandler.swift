import Foundation

/// SCSI 状态码 (ANSI SAM-4)
public enum SCSIStatus: UInt8, Sendable {
    case good = 0x00
    case checkCondition = 0x02
    case conditionMet = 0x04
    case busy = 0x08
    case reservationConflict = 0x18
    case taskSetFull = 0x28
}

/// SCSI 感测键值 (Sense Keys)
public enum SCSISenseKey: UInt8, Sendable {
    case noSense = 0x00
    case recoveredError = 0x01
    case notReady = 0x02
    case mediumError = 0x03
    case hardwareError = 0x04
    case illegalRequest = 0x05
    case unitAttention = 0x06
    case dataProtect = 0x07
    case blankCheck = 0x08
    case vendorSpecific = 0x09
    case copyAborted = 0x0A
    case abortedCommand = 0x0B
    case volumeOverflow = 0x0D
    case miscompare = 0x0E
}

/// SCSI 附加感测码信息 (ASC / ASCQ)
public struct SCSISenseCode: Sendable {
    public let asc: UInt8
    public let ascq: UInt8
    
    public static let noAdditionalSense = SCSISenseCode(asc: 0x00, ascq: 0x00)
    public static let logicalUnitNotReadyFormatInProgress = SCSISenseCode(asc: 0x04, ascq: 0x04)
    public static let unrecoveredReadError = SCSISenseCode(asc: 0x11, ascq: 0x00)
    public static let writeError = SCSISenseCode(asc: 0x0C, ascq: 0x02)
    public static let writeProtected = SCSISenseCode(asc: 0x27, ascq: 0x00)
    public static let invalidCommandOperationCode = SCSISenseCode(asc: 0x20, ascq: 0x00)
    public static let logicalBlockAddressOutOfRange = SCSISenseCode(asc: 0x21, ascq: 0x00)
    public static let invalidFieldInCDB = SCSISenseCode(asc: 0x24, ascq: 0x00)
    public static let savingParametersNotSupported = SCSISenseCode(asc: 0x39, ascq: 0x00)
    public static let logicalUnitNotSupported = SCSISenseCode(asc: 0x25, ascq: 0x00)
}

/// SCSI 响应载荷
public struct SCSIResponse: Sendable {
    public let status: SCSIStatus
    public let responseData: Data
    public let senseData: Data
    
    public init(status: SCSIStatus, responseData: Data = Data(), senseData: Data = Data()) {
        self.status = status
        self.responseData = responseData
        self.senseData = senseData
    }
}

/// 工业级 ANSI SPC-4 / SBC-3 SCSI 指令集处理器
public final class SCSICommandHandler: @unchecked Sendable {
    private let blockDevice: BlockDeviceReader
    private let logger: AEMachLogger
    
    public init(blockDevice: BlockDeviceReader, logger: AEMachLogger = .shared) {
        self.blockDevice = blockDevice
        self.logger = logger
    }
    
    /// 处理 SCSI 核心入口函数
    public func processCDB(_ cdb: Data, writeData: Data?) -> SCSIResponse {
        guard !cdb.isEmpty else {
            return buildSenseResponse(key: .illegalRequest, code: .invalidFieldInCDB)
        }
        
        let opCode = cdb[0]
        
        do {
            switch opCode {
            case 0x00: // TEST UNIT READY
                return handleTestUnitReady()
                
            case 0x08: // READ (6)
                return try handleRead6(cdb: cdb)
                
            case 0x0A: // WRITE (6)
                return try handleWrite6(cdb: cdb, writeData: writeData)
                
            case 0x12: // INQUIRY
                return try handleInquiry(cdb: cdb)
                
            case 0x15, 0x55: // MODE SELECT (6 / 10)
                return SCSIResponse(status: .good)
                
            case 0x1A: // MODE SENSE (6)
                return try handleModeSense6(cdb: cdb)
                
            case 0x5A: // MODE SENSE (10)
                return try handleModeSense10(cdb: cdb)
                
            case 0x1B: // START STOP UNIT
                return handleStartStopUnit()
                
            case 0x1E: // PREVENT ALLOW MEDIUM REMOVAL
                return SCSIResponse(status: .good)
                
            case 0x25: // READ CAPACITY (10)
                return try handleReadCapacity10()
                
            case 0x28: // READ (10)
                return try handleRead10(cdb: cdb)
                
            case 0x2A: // WRITE (10)
                return try handleWrite10(cdb: cdb, writeData: writeData)
                
            case 0x2F: // VERIFY (10)
                return SCSIResponse(status: .good)
                
            case 0x35, 0x91: // SYNCHRONIZE CACHE (10 / 16)
                return try handleSynchronizeCache()
                
            case 0x88: // READ (16)
                return try handleRead16(cdb: cdb)
                
            case 0x8A: // WRITE (16)
                return try handleWrite16(cdb: cdb, writeData: writeData)
                
            case 0x8F: // VERIFY (16)
                return SCSIResponse(status: .good)
                
            case 0x9E: // SERVICE ACTION IN (16) [主要为 READ CAPACITY (16)]
                return try handleServiceActionIn16(cdb: cdb)
                
            case 0xA0: // REPORT LUNS
                return handleReportLuns(cdb: cdb)
                
            case 0xA3: // MAINTENANCE IN [主要为 REPORT TARGET PORT GROUPS (ALUA)]
                return handleMaintenanceIn(cdb: cdb)
                
            default:
                logger.warn("SCSI Opcode [0x\(String(format: "%02X", opCode))] received but unsupported.", sys: "com.aemachboot.storage", cat: "SCSI")
                return buildSenseResponse(key: .illegalRequest, code: .invalidCommandOperationCode)
            }
        } catch let err as BlockDeviceError {
            logger.error("BlockDeviceError during SCSI Command processing: \(err.localizedDescription)", sys: "com.aemachboot.storage", cat: "SCSI")
            switch err {
            case .diskFull:
                return buildSenseResponse(key: .mediumError, code: .writeError)
            case .alignmentViolation, .invalidSectors:
                return buildSenseResponse(key: .illegalRequest, code: .logicalBlockAddressOutOfRange)
            case .permissionDenied:
                return buildSenseResponse(key: .dataProtect, code: .writeProtected)
            default:
                return buildSenseResponse(key: .hardwareError, code: .unrecoveredReadError)
            }
        } catch {
            logger.error("Unexpected error during SCSI execution: \(error.localizedDescription)", sys: "com.aemachboot.storage", cat: "SCSI")
            return buildSenseResponse(key: .hardwareError, code: .unrecoveredReadError)
        }
    }
    
    // MARK: - 具体指令处理句柄
    
    private func handleTestUnitReady() -> SCSIResponse {
        return SCSIResponse(status: .good)
    }
    
    private func handleRead6(cdb: Data) throws -> SCSIResponse {
        let lba = UInt32(cdb[1] & 0x1F) << 16 | UInt32(cdb[2]) << 8 | UInt32(cdb[3])
        var transferLength = UInt32(cdb[4])
        if transferLength == 0 { transferLength = 256 }
        
        if transferLength == 0 { return SCSIResponse(status: .good) }
        let payload = try blockDevice.readSectors(at: UInt64(lba), count: transferLength)
        return SCSIResponse(status: .good, responseData: payload)
    }
    
    private func handleWrite6(cdb: Data, writeData: Data?) throws -> SCSIResponse {
        let lba = UInt32(cdb[1] & 0x1F) << 16 | UInt32(cdb[2]) << 8 | UInt32(cdb[3])
        var transferLength = UInt32(cdb[4])
        if transferLength == 0 { transferLength = 256 }
        
        if transferLength == 0 { return SCSIResponse(status: .good) }
        
        guard let payload = writeData, payload.count == Int(transferLength) * Int(blockDevice.sectorSize) else {
            return buildSenseResponse(key: .illegalRequest, code: .invalidFieldInCDB)
        }
        
        try blockDevice.writeSectors(at: UInt64(lba), data: payload)
        return SCSIResponse(status: .good)
    }
    
    private func handleInquiry(cdb: Data) throws -> SCSIResponse {
        let evpd = (cdb[1] & 0x01) == 0x01
        let pageCode = cdb[2]
        let allocationLength = UInt16(cdb[3]) << 8 | UInt16(cdb[4])
        
        var responseBuffer = Data()
        
        if !evpd {
            // 标准主 INQUIRY (SPC-4)
            responseBuffer.append(0x00) // Direct Access Block Device (Disk)
            responseBuffer.append(0x00) // RBC / Non-removable
            responseBuffer.append(0x06) // SPC-4
            responseBuffer.append(0x02) // Response Data Format = 2
            responseBuffer.append(31)   // Additional Length
            responseBuffer.append(0x00) // No SCCS/ACC/TPGS
            responseBuffer.append(0x00)
            responseBuffer.append(0x02) // CmdQue = 1
            
            let vendor = "AEMACH  ".data(using: .utf8)!
            responseBuffer.append(vendor)
            
            let product = "AEMachBoot Disk ".data(using: .utf8)!
            responseBuffer.append(product)
            
            let revision = "0001".data(using: .utf8)!
            responseBuffer.append(revision)
        } else {
            // EVPD (Vital Product Data Pages)
            switch pageCode {
            case 0x00: // Supported VPD Pages
                responseBuffer.append(0x00)
                responseBuffer.append(0x00)
                responseBuffer.append(0x00)
                responseBuffer.append(4)    // Page Length
                responseBuffer.append(0x00) // Supported Pages
                responseBuffer.append(0x80) // Serial Number
                responseBuffer.append(0x83) // Device ID
                responseBuffer.append(0xB0) // Block Limits Page (Windows 必需)
                
            case 0x80: // Serial Number Page
                responseBuffer.append(0x00)
                responseBuffer.append(0x80)
                responseBuffer.append(0x00)
                
                let serialNumber = "AEMB-LUN-VOL001".data(using: .utf8)!
                responseBuffer.append(UInt8(serialNumber.count))
                responseBuffer.append(serialNumber)
                
            case 0x83: // Device Identification Page
                responseBuffer.append(0x00)
                responseBuffer.append(0x83)
                responseBuffer.append(0x00)
                
                var designatorData = Data()
                designatorData.append(0x01) // Binary Code Set
                designatorData.append(0x03) // Association=Logical Unit, Designator=NAA
                designatorData.append(0x00) // Reserved
                designatorData.append(8)    // Length = 8 Bytes
                
                let naaIEEE: [UInt8] = [0x50, 0x00, 0x30, 0x1A, 0xAA, 0xBB, 0xCC, 0xDD]
                designatorData.append(contentsOf: naaIEEE)
                
                responseBuffer.append(UInt8(designatorData.count))
                responseBuffer.append(designatorData)
                
            case 0xB0: // Block Limits VPD Page (SBC-3 逻辑块对齐声明)
                responseBuffer.append(0x00)
                responseBuffer.append(0xB0)
                responseBuffer.append(0x00)
                responseBuffer.append(0x3C) // Page Length = 60
                
                // WSNOP=0, Compare & Write Native Block Length = 0
                responseBuffer.append(0x00)
                responseBuffer.append(0x00)
                
                // Maximum Compare and Write Length (0)
                responseBuffer.append(0x00)
                
                // Optimal Transfer Length Granularity = 1 Sector (BE 16)
                responseBuffer.append(0x00)
                responseBuffer.append(0x01)
                
                // Maximum Transfer Length (e.g. 2048 Sectors = 1MB)
                responseBuffer.append(contentsOf: unpackBigEndian32(2048))
                
                // Optimal Transfer Length
                responseBuffer.append(contentsOf: unpackBigEndian32(1024))
                
                // 填充剩余标准的 44 字节保留 0 值
                responseBuffer.append(Data(repeating: 0, count: 44))
                
            default:
                logger.warn("Unsupported EVPD Page: 0x\(String(format: "%02X", pageCode)) requested.", sys: "com.aemachboot.storage", cat: "SCSI")
                return buildSenseResponse(key: .illegalRequest, code: .invalidFieldInCDB)
            }
        }
        
        let safeLength = min(Int(allocationLength), responseBuffer.count)
        return SCSIResponse(status: .good, responseData: responseBuffer.prefix(safeLength))
    }
    
    private func handleReadCapacity10() throws -> SCSIResponse {
        var response = Data()
        let totalBlocks = blockDevice.sectorCount
        let blockSize = UInt32(blockDevice.sectorSize)
        
        let reportBlocks: UInt32
        if totalBlocks == 0 {
            reportBlocks = 0
        } else if totalBlocks >= UInt64(UInt32.max) {
            reportBlocks = UInt32.max
        } else {
            reportBlocks = UInt32(totalBlocks - 1)
        }
        
        response.append(contentsOf: unpackBigEndian32(reportBlocks))
        response.append(contentsOf: unpackBigEndian32(blockSize))
        
        return SCSIResponse(status: .good, responseData: response)
    }
    
    private func handleServiceActionIn16(cdb: Data) throws -> SCSIResponse {
        let serviceAction = cdb[1] & 0x1F
        guard serviceAction == 0x10 else {
            return buildSenseResponse(key: .illegalRequest, code: .invalidFieldInCDB)
        }
        
        var response = Data()
        let totalBlocks = blockDevice.sectorCount
        let blockSize = UInt32(blockDevice.sectorSize)
        
        let reportBlocks = totalBlocks > 0 ? totalBlocks - 1 : 0
        
        response.append(contentsOf: unpackBigEndian64(reportBlocks))
        response.append(contentsOf: unpackBigEndian32(blockSize))
        response.append(0x00) // P_TYPE = 0, PROT_EN = 0
        response.append(0x00) // Logical blocks per physical block exponent = 0
        response.append(0x00) // Lowest aligned logical block address MSB
        response.append(0x00)
        response.append(contentsOf: Array(repeating: UInt8(0), count: 12))
        
        return SCSIResponse(status: .good, responseData: response)
    }
    
    private func handleRead10(cdb: Data) throws -> SCSIResponse {
        let lba = UInt32(cdb[2]) << 24 | UInt32(cdb[3]) << 16 | UInt32(cdb[4]) << 8 | UInt32(cdb[5])
        let transferLength = UInt16(cdb[7]) << 8 | UInt16(cdb[8])
        
        logger.trace("READ (10) - LBA: \(lba), Sectors: \(transferLength)", sys: "com.aemachboot.storage", cat: "SCSI")
        
        if transferLength == 0 {
            return SCSIResponse(status: .good)
        }
        
        let payload = try blockDevice.readSectors(at: UInt64(lba), count: UInt32(transferLength))
        return SCSIResponse(status: .good, responseData: payload)
    }
    
    private func handleRead16(cdb: Data) throws -> SCSIResponse {
        let lba = UInt64(cdb[2]) << 56 | UInt64(cdb[3]) << 48 | UInt64(cdb[4]) << 40 | UInt64(cdb[5]) << 32 |
                  UInt64(cdb[6]) << 24 | UInt64(cdb[7]) << 16 | UInt64(cdb[8]) << 8  | UInt64(cdb[9])
        
        let transferLength = UInt32(cdb[10]) << 24 | UInt32(cdb[11]) << 16 | UInt32(cdb[12]) << 8 | UInt32(cdb[13])
        
        logger.trace("READ (16) - LBA: \(lba), Sectors: \(transferLength)", sys: "com.aemachboot.storage", cat: "SCSI")
        
        if transferLength == 0 {
            return SCSIResponse(status: .good)
        }
        
        let payload = try blockDevice.readSectors(at: lba, count: transferLength)
        return SCSIResponse(status: .good, responseData: payload)
    }
    
    private func handleWrite10(cdb: Data, writeData: Data?) throws -> SCSIResponse {
        let lba = UInt32(cdb[2]) << 24 | UInt32(cdb[3]) << 16 | UInt32(cdb[4]) << 8 | UInt32(cdb[5])
        let transferLength = UInt16(cdb[7]) << 8 | UInt16(cdb[8])
        
        logger.trace("WRITE (10) - LBA: \(lba), Sectors: \(transferLength)", sys: "com.aemachboot.storage", cat: "SCSI")
        
        if transferLength == 0 {
            return SCSIResponse(status: .good)
        }
        
        guard let payload = writeData, payload.count == Int(transferLength) * Int(blockDevice.sectorSize) else {
            logger.error("WRITE (10) payload length mismatch! Expected \(Int(transferLength) * Int(blockDevice.sectorSize)) bytes, got \(writeData?.count ?? 0)", sys: "com.aemachboot.storage", cat: "SCSI")
            return buildSenseResponse(key: .illegalRequest, code: .invalidFieldInCDB)
        }
        
        try blockDevice.writeSectors(at: UInt64(lba), data: payload)
        return SCSIResponse(status: .good)
    }
    
    private func handleWrite16(cdb: Data, writeData: Data?) throws -> SCSIResponse {
        let lba = UInt64(cdb[2]) << 56 | UInt64(cdb[3]) << 48 | UInt64(cdb[4]) << 40 | UInt64(cdb[5]) << 32 |
                  UInt64(cdb[6]) << 24 | UInt64(cdb[7]) << 16 | UInt64(cdb[8]) << 8  | UInt64(cdb[9])
        
        let transferLength = UInt32(cdb[10]) << 24 | UInt32(cdb[11]) << 16 | UInt32(cdb[12]) << 8 | UInt32(cdb[13])
        
        logger.trace("WRITE (16) - LBA: \(lba), Sectors: \(transferLength)", sys: "com.aemachboot.storage", cat: "SCSI")
        
        if transferLength == 0 {
            return SCSIResponse(status: .good)
        }
        
        guard let payload = writeData, payload.count == Int(transferLength) * Int(blockDevice.sectorSize) else {
            return buildSenseResponse(key: .illegalRequest, code: .invalidFieldInCDB)
        }
        
        try blockDevice.writeSectors(at: lba, data: payload)
        return SCSIResponse(status: .good)
    }
    
    private func handleModeSense6(cdb: Data) throws -> SCSIResponse {
        let pageCode = cdb[2] & 0x3F
        let allocationLength = cdb[4]
        
        var responseBuffer = Data()
        responseBuffer.append(0x00) // Mode Data Length
        responseBuffer.append(0x00) // Medium Type
        responseBuffer.append(0x00) // Device-Specific Parameter
        responseBuffer.append(0x00) // Block Descriptor Length
        
        try fillModePage(pageCode: pageCode, into: &responseBuffer)
        
        responseBuffer[0] = UInt8(responseBuffer.count - 1)
        
        let safeLength = min(Int(allocationLength), responseBuffer.count)
        return SCSIResponse(status: .good, responseData: responseBuffer.prefix(safeLength))
    }
    
    private func handleModeSense10(cdb: Data) throws -> SCSIResponse {
        let pageCode = cdb[2] & 0x3F
        let allocationLength = UInt16(cdb[7]) << 8 | UInt16(cdb[8])
        
        var responseBuffer = Data()
        responseBuffer.append(0x00) // Mode Data Length MSB
        responseBuffer.append(0x00) // Mode Data Length LSB
        responseBuffer.append(0x00) // Medium Type
        responseBuffer.append(0x00) // Device-Specific Parameter
        responseBuffer.append(0x00) // LongLBA bit
        responseBuffer.append(0x00) // Reserved
        responseBuffer.append(0x00) // Block Descriptor Length MSB
        responseBuffer.append(0x00) // Block Descriptor Length LSB
        
        try fillModePage(pageCode: pageCode, into: &responseBuffer)
        
        let actualLength = UInt16(responseBuffer.count - 2)
        responseBuffer[0] = UInt8((actualLength >> 8) & 0xFF)
        responseBuffer[1] = UInt8(actualLength & 0xFF)
        
        let safeLength = min(Int(allocationLength), responseBuffer.count)
        return SCSIResponse(status: .good, responseData: responseBuffer.prefix(safeLength))
    }
    
    private func fillModePage(pageCode: UInt8, into buffer: inout Data) throws {
        switch pageCode {
        case 0x01: // Read-Write Error Recovery Page
            buffer.append(0x01)
            buffer.append(0x0A) // Page Length = 10
            buffer.append(0x00) // AWRE, ARRE disabled
            buffer.append(0x00) // Read Retry Count
            buffer.append(contentsOf: Array(repeating: UInt8(0), count: 8))
            
        case 0x08: // Caching Mode Page
            buffer.append(0x08)
            buffer.append(0x12) // Page Length = 18
            buffer.append(0x04) // WCE (Write Cache Enable) = 1
            buffer.append(0x00)
            buffer.append(0x00)
            buffer.append(0x00)
            buffer.append(contentsOf: Array(repeating: UInt8(0), count: 12))
            
        case 0x1C: // Informational Exceptions Control (SMART)
            buffer.append(0x1C)
            buffer.append(0x0A) // Page Length = 10
            buffer.append(0x08) // MRIE = 8 (Report on Request)
            buffer.append(contentsOf: Array(repeating: UInt8(0), count: 9))
            
        case 0x3F: // Return All Supported Pages
            try fillModePage(pageCode: 0x01, into: &buffer)
            try fillModePage(pageCode: 0x08, into: &buffer)
            try fillModePage(pageCode: 0x1C, into: &buffer)
            
        default:
            break
        }
    }
    
    private func handleReportLuns(cdb: Data) -> SCSIResponse {
        let allocationLength = UInt32(cdb[6]) << 24 | UInt32(cdb[7]) << 16 | UInt32(cdb[8]) << 8 | UInt32(cdb[9])
        
        var responseBuffer = Data()
        responseBuffer.append(0x00)
        responseBuffer.append(0x00)
        responseBuffer.append(0x00)
        responseBuffer.append(0x08) // LUN List Length = 8 Bytes (1 LUN)
        responseBuffer.append(contentsOf: Array(repeating: UInt8(0), count: 4))
        
        // Single LUN 0
        responseBuffer.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        
        let safeLength = min(Int(allocationLength), responseBuffer.count)
        return SCSIResponse(status: .good, responseData: responseBuffer.prefix(safeLength))
    }
    
    private func handleMaintenanceIn(cdb: Data) -> SCSIResponse {
        let serviceAction = cdb[1] & 0x1F
        let allocationLength = UInt32(cdb[6]) << 24 | UInt32(cdb[7]) << 16 | UInt32(cdb[8]) << 8 | UInt32(cdb[9])
        
        // 0x0A = REPORT TARGET PORT GROUPS (ALUA / MPIO 查询)
        if serviceAction == 0x0A {
            var responseBuffer = Data()
            
            // Total Return Data Length (32 bytes - 4) = 28
            responseBuffer.append(0x00)
            responseBuffer.append(0x00)
            responseBuffer.append(0x00)
            responseBuffer.append(28)
            
            // Target Port Group Descriptor
            responseBuffer.append(0x00) // Pref=0, State = Active / Optimized (0x00)
            responseBuffer.append(0x0F) // Supported States: Active/Optimized, Active/NonOptimized, Standby, Unavailable
            responseBuffer.append(0x00) // Target Port Group ID MSB
            responseBuffer.append(0x01) // Target Port Group ID LSB = 1
            responseBuffer.append(0x00) // Reserved
            responseBuffer.append(0x00) // Status Code = No status
            responseBuffer.append(0x00) // Target Port Count = 1
            responseBuffer.append(0x01) // Target Port Count = 1
            
            // Target Port Descriptor
            responseBuffer.append(0x00)
            responseBuffer.append(0x00)
            responseBuffer.append(0x00) // Relative Target Port Identifier MSB
            responseBuffer.append(0x01) // Relative Target Port Identifier LSB = 1
            
            let safeLength = min(Int(allocationLength), responseBuffer.count)
            return SCSIResponse(status: .good, responseData: responseBuffer.prefix(safeLength))
        }
        
        return buildSenseResponse(key: .illegalRequest, code: .invalidFieldInCDB)
    }
    
    private func handleSynchronizeCache() throws -> SCSIResponse {
        try blockDevice.flush()
        return SCSIResponse(status: .good)
    }
    
    private func handleStartStopUnit() -> SCSIResponse {
        return SCSIResponse(status: .good)
    }
    
    // MARK: - 私有辅助函数
    
    private func buildSenseResponse(key: SCSISenseKey, code: SCSISenseCode) -> SCSIResponse {
        var sense = Data()
        sense.append(0x70) // Fixed Format Current Sense
        sense.append(0x00)
        sense.append(key.rawValue & 0x0F)
        sense.append(contentsOf: Array(repeating: UInt8(0), count: 4))
        sense.append(10)   // Additional Sense Length
        sense.append(contentsOf: Array(repeating: UInt8(0), count: 4))
        sense.append(code.asc)
        sense.append(code.ascq)
        sense.append(0x00)
        sense.append(contentsOf: Array(repeating: UInt8(0), count: 3))
        
        return SCSIResponse(status: .checkCondition, senseData: sense)
    }
    
    private func unpackBigEndian32(_ val: UInt32) -> [UInt8] {
        return [
            UInt8((val >> 24) & 0xFF),
            UInt8((val >> 16) & 0xFF),
            UInt8((val >> 8) & 0xFF),
            UInt8(val & 0xFF)
        ]
    }
    
    private func unpackBigEndian64(_ val: UInt64) -> [UInt8] {
        return [
            UInt8((val >> 56) & 0xFF),
            UInt8((val >> 48) & 0xFF),
            UInt8((val >> 40) & 0xFF),
            UInt8((val >> 32) & 0xFF),
            UInt8((val >> 24) & 0xFF),
            UInt8((val >> 16) & 0xFF),
            UInt8((val >> 8) & 0xFF),
            UInt8(val & 0xFF)
        ]
    }
}
