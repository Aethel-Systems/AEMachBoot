import SwiftUI

/// 仪表盘状态大卡片
struct DashboardView: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("PXE / iSCSI Engine Dashboard")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .padding(.top)
                
                // 子服务健康卡片矩阵网格
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220))], spacing: 16) {
                    ServiceStatusCard(title: "DHCP Server", state: state.dhcpState, port: "UDP 67")
                    ServiceStatusCard(title: "TFTP Server", state: state.tftpState, port: "UDP 69")
                    ServiceStatusCard(title: "HTTP Server", state: state.httpState, port: "TCP 8080")
                    ServiceStatusCard(title: "iSCSI Target", state: state.iscsiState, port: "TCP 3260")
                }
                
                // 运行状态与错误输出栏
                if let error = state.coordinator.lastErrorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("Fatal Igniter Error")
                                .font(.headline)
                        }
                        Text(error)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }
                
                // 活动客户端列表看板
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connected Disks Status")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    if state.globalState == .running {
                        HStack {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                            VStack(alignment: .leading) {
                                Text("Storage Target Path:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(state.selectedImagePath)
                                    .font(.system(.body, design: .monospaced))
                            }
                            Spacer()
                        }
                        .padding()
                        .background(Color(NSColor.windowBackgroundColor))
                        .cornerRadius(8)
                    } else {
                        Text("All protocols offline. Wake up the engine to start hosting.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2)))
            }
            .padding()
        }
    }
}

struct ServiceStatusCard: View {
    let title: String
    let state: ServiceCoordinatorState
    let port: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Circle()
                    .fill(indicatorColor(for: state))
                    .frame(width: 8, height: 8)
            }
            
            Text(state.rawValue)
                .font(.title)
                .fontWeight(.bold)
            
            Text(port)
                .font(.footnote)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(4)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
    }
    
    private func indicatorColor(for state: ServiceCoordinatorState) -> Color {
        switch state {
        case .stopped: return .gray
        case .starting: return .orange
        case .running: return .green
        case .stopping: return .yellow
        case .fault: return .red
        }
    }
}