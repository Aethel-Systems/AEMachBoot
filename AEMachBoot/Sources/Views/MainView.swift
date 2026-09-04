import SwiftUI

/// 侧边栏导航选择枚举
public enum SidebarSelection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case diskManager = "Image Manager"
    case networkSettings = "Network Settings"
    case logConsole = "Log Console"
    
    public var id: String { self.rawValue }
    
    public var icon: String {
        switch self {
        case .dashboard: return "gauge"
        case .diskManager: return "internaldrive"
        case .networkSettings: return "network"
        case .logConsole: return "terminal"
        }
    }
}

/// 主窗口布局框架视图
public struct MainView: View {
    @StateObject private var state = AppState()
    @State private var sidebarSelection: SidebarSelection? = .dashboard
    
    public init() {}
    
    public var body: some View {
        NavigationSplitView {
            List(SidebarSelection.allCases, selection: $sidebarSelection) { item in
                NavigationLink(value: item) {
                    Label(item.rawValue, systemImage: item.icon)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .listStyle(.sidebar)
            
            // 侧边栏底部的快捷控制区域
            VStack(spacing: 8) {
                Divider()
                HStack {
                    Circle()
                        .fill(indicatorColor(for: state.globalState))
                        .frame(width: 10, height: 10)
                    Text("Service: \(state.globalState.rawValue)")
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal)
                
                Button(action: { state.toggleServices() }) {
                    Text(state.globalState == .running ? "Stop All Services" : "Power On Engine")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.globalState == .running ? .red : .blue)
                .padding([.horizontal, .bottom])
            }
        } detail: {
            if let selection = sidebarSelection {
                switch selection {
                case .dashboard:
                    DashboardView(state: state)
                case .diskManager:
                    ImageManagerView(state: state)
                case .networkSettings:
                    NetworkSettingsView(state: state)
                case .logConsole:
                    LogConsoleView(state: state)
                }
            } else {
                Text("Select an option from the sidebar")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 550)
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