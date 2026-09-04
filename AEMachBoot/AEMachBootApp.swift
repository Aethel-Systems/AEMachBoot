import SwiftUI

@main
struct AEMachBootApp: App {
    
    init() {
        // 全局日志系统基础设置
        AEMachLogger.shared.info("AEMachBoot Host PXE Application Core launching...", sys: "com.aemachboot.ui", cat: "Main")
    }
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .navigationTitle("AEMachBoot - macOS Host PXE Server Platform")
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
