//
//  ZeehoIntents.swift
//  ZeehoSignin
//
//  AppIntents 快捷方式：Siri 语音指令 + 主屏长按弹窗（iOS 16+）。
//  与 Android 的 VehicleShortcuts 对齐。
//
//  ZeehoSignInIntent（签到）和 ZeehoStageControlIntent（Widget 控车暂存）定义在 ZeehoIntent.swift。
//  本文件额外补充：寻车 / 鸣笛 / 开坐垫 / 开锁 / 关锁 的 Siri 指令。
//  每个类一个 Intent（AppIntents 不支持泛型），主逻辑在 runCommand(_:)。
//

import AppIntents
import Foundation

// MARK: - 执行命令（统一入口）

/// 从本地 status + accounts 里找第一个有有效 vin 的车辆，直接执行。
@MainActor
private func runCommand(_ action: VehicleAction) async -> String {
    let accounts = ZeehoFiles.loadAccounts()
    guard !accounts.isEmpty else { return "没配 Token，先在 App 里粘贴 Authorization" }
    guard let status = ZeehoFiles.loadStatus() else { return "先打开 App 刷新一下车辆信息" }
    let candidates = status.accountRows.flatMap { row in
        row.shownVehicles.compactMap { vehicle -> (String, VehicleStatus)? in
            guard let vin = vehicle.vin, !vin.isEmpty else { return nil }
            return (row.id, vehicle)
        }
    }
    guard let (accountId, vehicle) = candidates.first else { return "没车辆，先打开 App 刷新" }
    return await ZeehoEngine.command(action, accountId: accountId, vin: vehicle.vin ?? "")
}

// MARK: - 五个控车快捷指令

@available(iOS 16.0, *)
struct ZeehoFindIntent: AppIntent {
    static let title: LocalizedStringResource = "寻车"
    static let description = IntentDescription("让车辆闪灯")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await runCommand(.find)
        return .result(dialog: msg)
    }
}

@available(iOS 16.0, *)
struct ZeehoHornIntent: AppIntent {
    static let title: LocalizedStringResource = "鸣笛"
    static let description = IntentDescription("车辆会鸣笛并闪灯")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await runCommand(.horn)
        return .result(dialog: msg)
    }
}

@available(iOS 16.0, *)
struct ZeehoSeatIntent: AppIntent {
    static let title: LocalizedStringResource = "开坐垫"
    static let description = IntentDescription("坐垫锁会弹开")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await runCommand(.seat)
        return .result(dialog: msg)
    }
}

@available(iOS 16.0, *)
struct ZeehoUnlockIntent: AppIntent {
    static let title: LocalizedStringResource = "开锁"
    static let description = IntentDescription("云端开锁")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await runCommand(.unlock)
        return .result(dialog: msg)
    }
}

@available(iOS 16.0, *)
struct ZeehoLockIntent: AppIntent {
    static let title: LocalizedStringResource = "关锁"
    static let description = IntentDescription("云端关锁")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await runCommand(.lock)
        return .result(dialog: msg)
    }
}

// MARK: - AppShortcutsProvider（主屏长按弹窗，Siri 短语）

@available(iOS 16.0, *)
struct ZeehoVehicleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: ZeehoSignInIntent(),
                phrases: [
                    "用\(.applicationName)签到",
                    "让\(.applicationName)打卡",
                ],
                shortTitle: "签到",
                systemImageName: "checkmark.seal"
            ),
            AppShortcut(
                intent: ZeehoFindIntent(),
                phrases: ["寻车", "找车在哪", "\(.applicationName)寻车"],
                shortTitle: "寻车",
                systemImageName: "magnifyingglass"
            ),
            AppShortcut(
                intent: ZeehoHornIntent(),
                phrases: ["鸣笛", "按一下喇叭", "\(.applicationName)鸣笛"],
                shortTitle: "鸣笛",
                systemImageName: "speaker.wave.2"
            ),
            AppShortcut(
                intent: ZeehoSeatIntent(),
                phrases: ["开坐垫", "打开坐垫锁"],
                shortTitle: "开坐垫",
                systemImageName: "rectangle.on.rectangle.angled"
            ),
            AppShortcut(
                intent: ZeehoUnlockIntent(),
                phrases: ["开锁", "打开车锁"],
                shortTitle: "开锁",
                systemImageName: "lock.open"
            ),
            AppShortcut(
                intent: ZeehoLockIntent(),
                phrases: ["关锁", "锁车"],
                shortTitle: "关锁",
                systemImageName: "lock.fill"
            ),
        ]
    }
}
