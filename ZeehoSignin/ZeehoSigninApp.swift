import AppIntents
import SwiftUI

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
        return true
    }
}

struct ZeehoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ZeehoSignInIntent(),
            phrases: [
                "用\(.applicationName)签到",
                "让\(.applicationName)打卡",
            ],
            shortTitle: "签到",
            systemImageName: "checkmark.seal"
        )
    }
}
