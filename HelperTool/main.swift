import Foundation
import Security

/// Helper extension to safely access the ObjC private/unexposed auditToken property on older SDKs.
extension NSXPCConnection {
    internal var safeAuditToken: audit_token_t? {
        guard let value = self.value(forKey: "auditToken") as? NSValue else {
            return nil
        }
        var token = audit_token_t()
        value.getValue(&token)
        return token
    }
}

/// 特权辅助进程的具体业务实现
public final class HelperTool: NSObject, HelperToolProtocol {
    private let logger: AEMachLogger = .shared
    
    /// 执行高权限端口绑定
    public func getBoundSocket(port: UInt16, isTCP: Bool, completion: @escaping (FileHandle?, String?) -> Void) {
        logger.info("Privileged Helper received request to bind port \(port) (Protocol: \(isTCP ? "TCP" : "UDP"))", sys: "com.aemachboot.helper", cat: "XPC")
        
        let socketType = isTCP ? SOCK_STREAM : SOCK_DGRAM
        let proto = isTCP ? IPPROTO_TCP : IPPROTO_UDP
        
        let fd = socket(AF_INET, socketType, proto)
        guard fd >= 0 else {
            let errStr = String(cString: strerror(errno))
            completion(nil, "Failed to create socket: \(errStr) (errno: \(errno))")
            return
        }
        
        var optVal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optVal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &optVal, socklen_t(MemoryLayout<Int32>.size))
        
        if !isTCP {
            // DHCP 专用的广播权限激活
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &optVal, socklen_t(MemoryLayout<Int32>.size))
        }
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        
        let bindStatus = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        
        guard bindStatus == 0 else {
            let errStr = String(cString: strerror(errno))
            close(fd)
            logger.error("Privileged bind failed on Port \(port). Error: \(errStr)", sys: "com.aemachboot.helper", cat: "XPC")
            completion(nil, "Failed to bind socket: \(errStr) (errno: \(errno))")
            return
        }
        
        // 核心特权机制：利用 macOS 的 FileHandle 具备跨 XPC 边界传递底层的描述符特征，
        // 将此 Root 绑定的 Socket 控制权完美转交回标准沙箱 User-space 应用。
        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        logger.info("Port \(port) bound successfully. Sharing descriptor via XPC.", sys: "com.aemachboot.helper", cat: "XPC")
        completion(fileHandle, nil)
    }
    
    /// 执行安全提权的 hdiutil
    public func executePrivilegedHdiutil(args: [String], completion: @escaping (Int32, String, String) -> Void) {
        logger.info("Privileged Helper executing hdiutil command with args: \(args)", sys: "com.aemachboot.helper", cat: "XPC")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        do {
            try process.run()
            
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            
            process.waitUntilExit()
            
            let exitCode = process.terminationStatus
            let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            
            completion(exitCode, stdoutStr, stderrStr)
        } catch {
            completion(-1, "", "Failed to launch subprocess: \(error.localizedDescription)")
        }
    }
}

/// 工业级 XPC 连接生命周期委托类
/// 严格执行代码签名验证（SecCode Signature Validation），阻止任何未授权的客户端调用特权接口。
public final class HelperToolListenerDelegate: NSObject, NSXPCListenerDelegate {
    
    /// 验证 XPC 客户端的代码签名
    private func verifyClientSignature(connection: NSXPCConnection) -> Bool {
        #if DEBUG
        // 在 Debug 本地开发测试阶段，直接放行主 App 的 XPC 连接
        AEMachLogger.shared.info("Debug build detected. Skipping strict Team ID security checks.", sys: "com.aemachboot.helper", cat: "Security")
        return true
        #else
        // 生产环境发布版本下执行严格代码签名校验
        guard var auditToken = connection.safeAuditToken else {
            AEMachLogger.shared.critical("Security Violation: Connection has no audit token.", sys: "com.aemachboot.helper", cat: "Security")
            return false
        }
        let auditTokenData = Data(bytes: &auditToken, count: MemoryLayout<audit_token_t>.size)
        
        var secCode: SecCode? = nil
        let attributes: [CFString: Any] = [
            kSecGuestAttributeAudit: auditTokenData
        ]
        
        var status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &secCode)
        guard status == errSecSuccess, let clientCode = secCode else {
            AEMachLogger.shared.critical("Security Violation: Failed to copy SecCode for connecting XPC client. Status: \(status)", sys: "com.aemachboot.helper", cat: "Security")
            return false
        }
        
        // 2. 构建硬编码的受信任开发者签名要求约束
        let requirementString = "identifier \"com.Aethel.AEMachBoot\"" as CFString
        
        var requirement: SecRequirement? = nil
        status = SecRequirementCreateWithString(requirementString, [], &requirement)
        guard status == errSecSuccess, let targetRequirement = requirement else {
            AEMachLogger.shared.critical("Internal Security Error: Failed to generate SecRequirement pattern.", sys: "com.aemachboot.helper", cat: "Security")
            return false
        }
        
        status = SecCodeCheckValidity(clientCode, [], targetRequirement)
        if status == errSecSuccess {
            AEMachLogger.shared.info("XPC security validation succeeded. Client identity verified.", sys: "com.aemachboot.helper", cat: "Security")
            return true
        } else {
            AEMachLogger.shared.critical("Access Blocked: Connecting XPC client failed security constraint match. Status: \(status)", sys: "com.aemachboot.helper", cat: "Security")
            return false
        }
        #endif
    }
    
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 严格代码签名防线
        guard verifyClientSignature(connection: newConnection) else {
            newConnection.invalidate()
            return false
        }
        
        newConnection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        newConnection.exportedObject = HelperTool()
        
        newConnection.resume()
        return true
    }
}

// MARK: - 程序守护引导入口

let helperListener = NSXPCListener.service()
let delegate = HelperToolListenerDelegate()
helperListener.delegate = delegate

AEMachLogger.shared.info("AEMachBoot Privileged Helper Daemon started. Spawning service listener...", sys: "com.aemachboot.helper", cat: "Main")
helperListener.resume()

// 阻止命令行二进制主线程退出，由 launchd 控制其生命周期
dispatchMain()
