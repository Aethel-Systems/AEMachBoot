import SwiftUI

/// 网络接口绑定及 DHCP 配置视图
struct NetworkSettingsView: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Network Coordination Settings")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.top)
                
                // 1. 物理网卡绑定选择
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ethernet Interface Binding")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Picker("Interface Name:", selection: $state.selectedInterfaceID) {
                        ForEach(state.availableInterfaces) { info in
                            Text("\(info.name) [\(info.ipv4Address ?? "Offline")]")
                                .tag(info.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.large)
                    
                    if let selected = state.availableInterfaces.first(where: { $0.id == state.selectedInterfaceID }) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Physical MAC:")
                                    .fontWeight(.medium)
                                Text(selected.macAddress ?? "Unknown")
                            }
                            HStack {
                                Text("Subnet Mask:")
                                    .fontWeight(.medium)
                                Text(selected.subnetMask ?? "Unknown")
                            }
                            HStack {
                                Text("Subnet Broadcast:")
                                    .fontWeight(.medium)
                                Text(selected.broadcastAddress ?? "None")
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                
                // 2. DHCP 服务器动作机制选择 (Standard vs Proxy)
                VStack(alignment: .leading, spacing: 14) {
                    Text("DHCP Mode Parameters")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Toggle(isOn: $state.isProxyDHCP) {
                        VStack(alignment: .leading) {
                            Text("ProxyDHCP Mode (Recommended)")
                                .font(.headline)
                            Text("Only inject PXE boot variables. Client IP addresses will be allocated by your existing central DHCP/Router.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    
                    if !state.isProxyDHCP {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Caution: Standard DHCP assigns IP addresses in the local network segment. Please guarantee that there are no conflicting routers on the same line.")
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                
                Button(action: { state.refreshInterfaces() }) {
                    Label("Refresh active interfaces", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}