import SwiftUI

/// 实时事件监视控制台，支持关键字检索与过滤
struct LogConsoleView: View {
    @ObservedObject var state: AppState
    @State private var autoScroll: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶层控制栏
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search raw output...", text: $state.logSearchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(6)
                .frame(width: 260)
                
                Picker("Level Filter:", selection: $state.selectedLogLevelFilter) {
                    Text("TRACE").tag(AELogLevel.trace)
                    Text("DEBUG").tag(AELogLevel.debug)
                    Text("INFO").tag(AELogLevel.info)
                    Text("WARN").tag(AELogLevel.warning)
                    Text("ERROR").tag(AELogLevel.error)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                
                Spacer()
                
                Button(action: { state.clearLogs() }) {
                    Label("Flush", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding([.horizontal, .top])
            
            // 终端框体
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let filteredLines = state.logConsoleLines.filter { line in
                            // 检查级别和检索词匹配过滤
                            if !state.logSearchQuery.isEmpty && !line.lowercased().contains(state.logSearchQuery.lowercased()) {
                                return false
                            }
                            return true
                        }
                        
                        ForEach(filteredLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(logColor(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .padding([.horizontal, .bottom])
                .onChange(of: state.logConsoleLines) { newValue in
                    if autoScroll, let last = newValue.last {
                        withAnimation {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    
    private func logColor(for line: String) -> Color {
        if line.contains("[ERROR]") || line.contains("[FATAL]") {
            return .red
        } else if line.contains("[WARN]") {
            return .yellow
        } else if line.contains("[DEBUG]") {
            return .gray
        } else {
            return .primary
        }
    }
}
