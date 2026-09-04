import Foundation
import SystemConfiguration

/// 描述一个物理或虚拟网卡的结构体
public struct NetworkInterfaceInfo: Sendable, Identifiable {
    public var id: String { name }
    /// 网卡系统名称 (例如 "en0")
    public let name: String
    /// IPv4 地址 (例如 "192.168.1.100")
    public let ipv4Address: String?
    /// 子网掩码 (例如 "255.255.255.0")
    public let subnetMask: String?
    /// 广播地址 (例如 "192.168.1.255")
    public let broadcastAddress: String?
    /// MAC 地址 (例如 "00:11:22:33:44:55")
    public let macAddress: String?
    /// 网卡当前的物理运行标志状态
    public let isUp: Bool
    public let isLoopback: Bool
    public let supportsBroadcast: Bool
}

/// 工业级网卡信息检索管理器
/// 利用 macOS 底层 BSD 系统的 `getifaddrs` 套接字接口，无缓存实时提取网卡的物理寻址、IP配置及状态标记。
public final class NetworkInterfaceManager: Sendable {
    private let logger: AEMachLogger
    
    public init(logger: AEMachLogger = .shared) {
        self.logger = logger
    }
    
    /// 获取 macOS 当前系统中所有处于活跃状态并支持 IPv4 寻址的物理网卡列表
    public func retrieveActiveInterfaces() -> [NetworkInterfaceInfo] {
        var interfaces = [NetworkInterfaceInfo]()
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>? = nil
        
        // 调用 BSD 标准 getifaddrs 系统调用
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            let err = errno
            logger.error("getifaddrs system call failed with error code: \(err)", sys: "com.aemachboot.network", cat: "Interface")
            return []
        }
        
        defer {
            freeifaddrs(ifaddrPointer) // 强规则：必须在函数退出前释放系统分配链表内存
        }
        
        // 临时字典，用于将同名网卡的 AF_INET 节点 (IP) 与 AF_LINK 节点 (MAC) 合并
        var tempMap = [String: (ipv4: String?, mask: String?, bcast: String?, mac: String?, flags: UInt32)]()
        
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while ptr != nil {
            guard let interface = ptr?.pointee else { break }
            
            let name = String(cString: interface.ifa_name)
            let flags = interface.ifa_flags
            let family = interface.ifa_addr != nil ? interface.ifa_addr.pointee.sa_family : 0
            
            // 初始化字典实体
            if tempMap[name] == nil {
                tempMap[name] = (nil, nil, nil, nil, flags)
            }
            
            if family == UInt8(AF_INET) {
                // 处理 IPv4 地址与掩码
                var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var maskBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var bcastBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                
                // 提取 IP 地址
                if let ifaAddr = interface.ifa_addr {
                    ifaAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socketIn in
                        _ = inet_ntop(AF_INET, &socketIn.pointee.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                    }
                }
                
                // 提取子网掩码
                if let ifaNetmask = interface.ifa_netmask {
                    ifaNetmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socketIn in
                        _ = inet_ntop(AF_INET, &socketIn.pointee.sin_addr, &maskBuffer, socklen_t(INET_ADDRSTRLEN))
                    }
                }
                
                // 提取广播地址 (仅当网卡置位 BROADCAST 标志)
                if (flags & UInt32(IFF_BROADCAST)) != 0, let ifaDstaddr = interface.ifa_dstaddr {
                    ifaDstaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socketIn in
                        _ = inet_ntop(AF_INET, &socketIn.pointee.sin_addr, &bcastBuffer, socklen_t(INET_ADDRSTRLEN))
                    }
                }
                
                let ipStr = String(cString: ipBuffer)
                let maskStr = String(cString: maskBuffer)
                let bcastStr = String(cString: bcastBuffer)
                
                let current = tempMap[name]!
                tempMap[name] = (
                    ipStr.isEmpty ? current.ipv4 : ipStr,
                    maskStr.isEmpty ? current.mask : maskStr,
                    bcastStr.isEmpty ? current.bcast : bcastStr,
                    current.mac,
                    flags
                )
                
            } else if family == UInt8(AF_LINK) {
                // 处理 MAC 物理寻址
                if let ifaAddr = interface.ifa_addr {
                    ifaAddr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl in
                        let sdlData = sdl.pointee
                        if sdlData.sdl_type == IFT_ETHER { // 严格筛选以太网物理媒介
                            let sdlIndex = Int(sdlData.sdl_nlen)
                            
                            // 借由指针算术定位到物理地址缓冲区起点
                            withUnsafePointer(to: sdlData.sdl_data) { rawDataPtr in
                                rawDataPtr.withMemoryRebound(to: UInt8.self, capacity: 12) { baseBytePtr in
                                    let macStartPtr = baseBytePtr.advanced(by: sdlIndex)
                                    var macBytes = [String]()
                                    for i in 0..<Int(sdlData.sdl_alen) {
                                        macBytes.append(String(format: "%02x", macStartPtr.advanced(by: i).pointee))
                                    }
                                    if !macBytes.isEmpty {
                                        let macStr = macBytes.joined(separator: ":")
                                        let current = tempMap[name]!
                                        tempMap[name] = (current.ipv4, current.mask, current.bcast, macStr, flags)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            ptr = ptr?.pointee.ifa_next
        }
        
        // 格式化输出为最终模型
        for (name, data) in tempMap {
            let isUp = (data.flags & UInt32(IFF_UP)) != 0
            let isLoopback = (data.flags & UInt32(IFF_LOOPBACK)) != 0
            let supportsBroadcast = (data.flags & UInt32(IFF_BROADCAST)) != 0
            
            // 过滤掉未配置 IP 的虚设网卡，但保留物理以太网
            if data.ipv4 == nil && data.mac == nil { continue }
            
            interfaces.append(NetworkInterfaceInfo(
                name: name,
                ipv4Address: data.ipv4,
                subnetMask: data.mask,
                broadcastAddress: data.bcast,
                macAddress: data.mac,
                isUp: isUp,
                isLoopback: isLoopback,
                supportsBroadcast: supportsBroadcast
            ))
        }
        
        // 排序：物理网卡（如 en0）排在虚拟网卡前面
        return interfaces.sorted { $0.name < $1.name }
    }
}