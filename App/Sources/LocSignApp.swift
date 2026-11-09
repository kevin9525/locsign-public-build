import SwiftUI

@main
struct LocSignApp: App {
    @StateObject private var installation = InstallationSettings.live()
    var body: some Scene {
        WindowGroup {
            TabView {
                SigningView(settings: installation).tabItem { Label("安装", systemImage: "signature") }
                ConnectionView(settings: installation).tabItem { Label("连接", systemImage: "cable.connector") }
                NavigationStack {
                    ContentUnavailableView {
                        Label("定位功能验证中", systemImage: "location.circle")
                    } description: {
                        Text("目标是地图选点、全局模拟与一键恢复。当前版本尚未接入设备端定位服务，请先验证设备连接。")
                    }
                    .navigationTitle("虚拟定位")
                }
                .tabItem { Label("定位", systemImage: "mappin.and.ellipse") }
            }
        }
    }
}
