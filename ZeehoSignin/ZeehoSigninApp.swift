import AppIntents
import SwiftUI
import UIKit

@main
struct ZeehoSigninApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ZeehoModel()

    init() {
        #if DEBUG
        ZeehoCrypto.selfCheck()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ZeehoBackground.register()
        ZeehoBackground.schedule(status: ZeehoFiles.loadStatus(), replace: false)
        ZeehoNotifier.requestAuthorizationIfNeeded()
        // iOS 15 兼容：主屏长按 App 图标显示快捷弹窗（iOS 16+ 用 AppIntents 的 AppShortcutProvider）
        if #available(iOS 16.0, *) {
            // AppShortcutProvider 自动生效
        } else {
            configureLegacyShortcutItems(on: application)
        }
        return true
    }

    private func configureLegacyShortcutItems(on application: UIApplication) {
        let items = [
            UIApplicationShortcutItem(
                type: "zeeho.find",
                localizedTitle: "寻车",
                localizedSubtitle: "车辆闪灯",
                icon: UIApplicationShortcutIcon(systemImageName: "magnifyingglass")
            ),
            UIApplicationShortcutItem(
                type: "zeeho.horn",
                localizedTitle: "鸣笛",
                localizedSubtitle: "鸣笛闪灯",
                icon: UIApplicationShortcutIcon(systemImageName: "speaker.wave.2")
            ),
            UIApplicationShortcutItem(
                type: "zeeho.lock",
                localizedTitle: "关锁",
                localizedSubtitle: "云端关锁",
                icon: UIApplicationShortcutIcon(systemImageName: "lock.fill")
            ),
            UIApplicationShortcutItem(
                type: "zeeho.unlock",
                localizedTitle: "开锁",
                localizedSubtitle: "云端开锁",
                icon: UIApplicationShortcutIcon(systemImageName: "lock.open")
            ),
        ]
        application.shortcutItems = items
    }

    // iOS 15 旧快捷弹窗点击后的处理
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        let map: [String: VehicleAction] = [
            "zeeho.find": .find, "zeeho.horn": .horn,
            "zeeho.seat": .seat, "zeeho.lock": .lock, "zeeho.unlock": .unlock,
        ]
        guard let action = map[shortcutItem.type] else { completionHandler(false); return }
        // 暂存命令，App 前台打开时执行（App 未运行时 shortcut 会先打开 App）
        Task {
            if let status = ZeehoFiles.loadStatus(),
               let first = status.accountRows.flatMap({ $0.shownVehicles }).first(where: { !($0.vin ?? "").isEmpty }) {
                _ = await ZeehoEngine.command(action, accountId: first.accountId ?? "", vin: first.vin ?? "")
            }
            completionHandler(true)
        }
    }
}

// iOS 16+ AppShortcutsProvider 见 ZeehoIntents.swift 的 ZeehoVehicleShortcuts。
// ZeehoSignInIntent 已在 ZeehoIntent.swift。
