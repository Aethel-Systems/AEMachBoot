import Foundation

/// 共享的 XPC 协议定义。此协议必须同时存在于主 App 客户端与特权辅助工具服务端。
@objc(HelperToolProtocol)
public protocol HelperToolProtocol {
    /// 请求特权进程创建并绑定低端口（如 UDP 67/69），并将绑定后的 File Descriptor 通过 XPC 安全地回传给主 App
    /// - Parameters:
    ///   - port: 欲绑定的端口号 (如 67, 69)
    ///   - isTCP: true 代表绑定 TCP, false 代表绑定 UDP
    ///   - completion: 异步回调。如果绑定成功，回传包装了文件描述符的 FileHandle 对象；若失败则返回错误消息
    func getBoundSocket(port: UInt16, isTCP: Bool, completion: @escaping (FileHandle?, String?) -> Void)
    
    /// 请求特权进程执行 hdiutil 磁盘挂载/创建命令
    /// - Parameters:
    ///   - args: 严格数组化的命令参数（杜绝 Shell 拼接引起的注入漏洞）
    ///   - completion: 异步回调。回传退出码、标准输出和标准错误
    func executePrivilegedHdiutil(args: [String], completion: @escaping (Int32, String, String) -> Void)
}
