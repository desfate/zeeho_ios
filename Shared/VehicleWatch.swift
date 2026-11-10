import Foundation
import UserNotifications

/// 告警阈值常量（与 Android VehicleWatch 对齐）。
enum VehicleWatchConsts {
    static let LOW = 20
    static let CLEAR = 25
    static let TIRE_BAR = 1.9
    static let CHANNEL_CHARGE = "zeeho-charge"
    static let CHANNEL_PROGRESS = "zeeho-charge-progress"
    static let CHANNEL_ALERT = "zeeho-vehicle"
}

/// 用户可勾选的告警开关。
struct WatchPrefs: Codable, Equatable, Sendable {
    var charge = true
    var messages = true
    var low = false
    var offline = false
    var tire = false

    var anyEnabled: Bool { charge || messages || low || offline || tire }
}

/// 每次刷新后保存的状态快照，用于下一次对比增量。
struct WatchSlot: Codable, Equatable, Sendable {
    var charge: String?
    var online: Bool?
    var lowNotified: Bool = false
    var tireNotified: Bool = false
    var msgId: String?
}

/// 待发出的一条本地通知。
struct WatchNote: Sendable {
    let id: Int
    let title: String
    let body: String
    let channel: String
    let ongoing: Bool
    let cancel: Bool
}

struct WatchMail: Sendable {
    let unread: Int
    let text: String
    let id: String
}

struct WatchStep {
    let slot: WatchSlot
    let notes: [WatchNote]
}

/// 车辆监控：对比前后状态，生成告警通知。
enum VehicleWatch {
    static func evaluate(previous: WatchSlot?, vehicle: VehicleStatus, prefs: WatchPrefs, mail: WatchMail?) -> WatchStep {
        let vin = (vehicle.vin ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? vehicle.titleText
            : (vehicle.vin ?? vehicle.titleText)
        let nowCharge = vehicle.chargeDisplay
        let nowOnline = online(vehicle.onlineText)
        var lowNotified = previous?.lowNotified == true
        var tireNotified = previous?.tireNotified == true
        var notes: [WatchNote] = []
        let seen = previous != nil

        // 充电进度（ongoing）
        if prefs.charge {
            if nowCharge == "充电中" {
                let soc = vehicle.battery.map { " · \($0)%" } ?? ""
                let extra = [vehicle.powerText, vehicle.etaText].compactMap { $0 }.joined(separator: " · ")
                notes.append(WatchNote(
                    id: Self.noteId(vin: vin, kind: 0),
                    title: "充电中\(soc)",
                    body: extra.isEmpty ? "充电器已连接" : extra,
                    channel: VehicleWatchConsts.CHANNEL_PROGRESS,
                    ongoing: true,
                    cancel: false
                ))
                if seen && previous?.charge != "充电中" {
                    let body = vehicle.battery.map { "当前电量 \($0)%" } ?? "充电器已连接"
                    notes.append(WatchNote(id: Self.noteId(vin: vin, kind: 1), title: "开始充电", body: body, channel: VehicleWatchConsts.CHANNEL_CHARGE, ongoing: false, cancel: false))
                }
            } else if previous?.charge == "充电中" {
                notes.append(WatchNote(id: Self.noteId(vin: vin, kind: 0), title: "", body: "", channel: VehicleWatchConsts.CHANNEL_PROGRESS, ongoing: false, cancel: true))
            }
            if seen && previous?.charge == "充电中" && nowCharge == "充电完成" {
                let body = vehicle.battery.map { "当前电量 \($0)%，可以拔枪了" } ?? "可以拔枪了"
                notes.append(WatchNote(id: Self.noteId(vin: vin, kind: 2), title: "已充满", body: body, channel: VehicleWatchConsts.CHANNEL_CHARGE, ongoing: false, cancel: false))
            }
            if seen && previous?.charge == "充电中" && nowCharge == "未充电" {
                let body = vehicle.battery.map { "当前电量 \($0)% · 充电器已断开" } ?? "充电器已断开"
                notes.append(WatchNote(id: Self.noteId(vin: vin, kind: 3), title: "充电已停止", body: body, channel: VehicleWatchConsts.CHANNEL_CHARGE, ongoing: false, cancel: false))
            }
        }

        // 低电量告警（非充电状态下，低于 LOW 才发一次；回到 CLEAR 以上可重置）
        let soc = vehicle.battery
        let charging = nowCharge == "充电中" || nowCharge == "充电完成"
        if soc == nil || soc! >= VehicleWatchConsts.CLEAR || charging { lowNotified = false }
        if prefs.low && seen, let soc, soc >= 0, soc <= VehicleWatchConsts.LOW, !charging && !lowNotified {
            notes.append(WatchNote(
                id: Self.noteId(vin: vin, kind: 4),
                title: "电量偏低",
                body: "当前电量 \(soc)%，建议尽快充电",
                channel: VehicleWatchConsts.CHANNEL_ALERT,
                ongoing: false,
                cancel: false
            ))
            lowNotified = true
        }

        // 离线告警
        if prefs.offline && seen && previous?.online == true && nowOnline == false {
            notes.append(WatchNote(
                id: Self.noteId(vin: vin, kind: 5),
                title: "车辆离线",
                body: "\(vehicle.titleText) 已离线，状态与充电可能停止更新",
                channel: VehicleWatchConsts.CHANNEL_ALERT,
                ongoing: false,
                cancel: false
            ))
        }

        // 胎压异常
        let problem = tireProblem(vehicle)
        if problem == nil { tireNotified = false }
        if prefs.tire && seen, let problem, !tireNotified {
            notes.append(WatchNote(
                id: Self.noteId(vin: vin, kind: 6),
                title: "胎压异常",
                body: problem,
                channel: VehicleWatchConsts.CHANNEL_ALERT,
                ongoing: false,
                cancel: false
            ))
            tireNotified = true
        }

        // 新车辆消息
        var msgId = previous?.msgId
        if let mail {
            if prefs.messages && seen, previous?.msgId != nil, previous?.msgId != mail.id, mail.unread > 0 {
                let body = mail.text.isEmpty ? "有新的车辆消息" : mail.text
                notes.append(WatchNote(
                    id: Self.noteId(vin: vin, kind: 7),
                    title: "新车辆消息",
                    body: "\(mail.unread) 条未读 · \(body)",
                    channel: VehicleWatchConsts.CHANNEL_ALERT,
                    ongoing: false,
                    cancel: false
                ))
            }
            msgId = mail.id
        }

        return WatchStep(
            slot: WatchSlot(charge: nowCharge, online: nowOnline, lowNotified: lowNotified, tireNotified: tireNotified, msgId: msgId),
            notes: notes
        )
    }

    static func tireProblem(_ vehicle: VehicleStatus) -> String? {
        var parts: [String] = []
        if let front = vehicle.frontBar, front > 0 && front < VehicleWatchConsts.TIRE_BAR {
            parts.append("前轮 \(String(format: "%.1f", front)) bar")
        }
        if let rear = vehicle.rearBar, rear > 0 && rear < VehicleWatchConsts.TIRE_BAR {
            parts.append("后轮 \(String(format: "%.1f", rear)) bar")
        }
        if !parts.isEmpty { return parts.joined(separator: "，") + "，低于警戒值" }
        if vehicle.tireWarn { return "\(vehicle.titleText) 车机报胎压异常" }
        return nil
    }

    static func online(_ text: String?) -> Bool? {
        let v = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.isEmpty || v == "未知" { return nil }
        if v.contains("离线") || v == "offline" || v == "0" { return false }
        if v.contains("在线") || v == "online" || v == "1" { return true }
        return nil
    }

    private static func noteId(vin: String, kind: Int) -> Int {
        3000 + (abs(vin.hashValue) % 0x0FFF) * 8 + kind
    }
}

// MARK: - ZeehoNotifier（UserNotifications 包装）

enum ZeehoNotifier {
    static func ensureChannels() {
        let center = UNUserNotificationCenter.current()
        let groups: [(String, String, Bool)] = [
            (VehicleWatchConsts.CHANNEL_CHARGE, "充电状态变更", false),
            (VehicleWatchConsts.CHANNEL_PROGRESS, "充电进行中", true),
            (VehicleWatchConsts.CHANNEL_ALERT, "车辆异常告警", false),
        ]
        // iOS 不支持 Android 那种渠道组，这里用 threadIdentifier 分组
        // 只在首次请求通知权限时注册类别
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            var categories: Set<UNNotificationCategory> = []
            for (channel, _, ongoing) in groups {
                let category = UNNotificationCategory(
                    identifier: channel,
                    actions: [],
                    intentIdentifiers: [],
                    options: ongoing ? .customDismissAction : []
                )
                categories.insert(category)
            }
            center.setNotificationCategories(categories)
        }
    }

    /// 请求通知权限（可多次调用）。
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// 按 WatchNote 发通知。ongoing = true 会用 `.ongoing` 组，便于在通知中心持续展示。cancel = true 会移除对应通知。
    static func vehicle(_ note: WatchNote) {
        let center = UNUserNotificationCenter.current()
        if note.cancel {
            center.removeDeliveredNotifications(withIdentifiers: ["zeeho:\(note.id)"])
            center.removePendingNotificationRequests(withIdentifiers: ["zeeho:\(note.id)"])
            return
        }
        center.getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            guard authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            content.sound = .default
            content.categoryIdentifier = note.channel
            content.threadIdentifier = note.channel
            if #available(iOS 16.0, *) {
                content.interruptionLevel = .timeSensitive
                if note.ongoing {
                    content.relevanceScore = 0.6
                }
            }
            // ongoing 通知立即发送（零秒后），以便在通知中心持续存在
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.05, repeats: false)
            let request = UNNotificationRequest(identifier: "zeeho:\(note.id)", content: content, trigger: trigger)
            center.add(request) { _ in }
        }
    }
}

// MARK: - 刷新后统一评估告警

enum ZeehoVehicleAlerts {
    /// 在每次 refresh 完成后调用：遍历所有车辆，对比上次 slot，发通知。
    static func after(status: SigninStatus) {
        ZeehoNotifier.requestAuthorizationIfNeeded()
        ZeehoNotifier.ensureChannels()
        let prefs = ZeehoFiles.watchPrefs()
        guard prefs.anyEnabled else { return }
        let slots = ZeehoFiles.loadWatch()
        var updated = slots
        let accountRows = status.accountRows
        let allVehicles = accountRows.flatMap { row in
            row.shownVehicles.map { v in (v.accountId ?? row.id, v) }
        }
        // 去重（按 vin 或 accountId+title）
        var seen = Set<String>()
        var evaluated: [VehicleStatus] = []
        for (accountId, vehicle) in allVehicles {
            let key = vehicle.vin?.isEmpty == false ? "vin:\(vehicle.vin!)" : "acc:\(accountId)|\(vehicle.titleText)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            evaluated.append(vehicle)
        }
        if evaluated.isEmpty, let first = status.vehicle {
            evaluated.append(first)
        }
        var accountMail: [String: WatchMail] = [:]
        for row in accountRows {
            accountMail[row.id] = WatchMail(unread: 0, text: "", id: row.id) // 占位：iOS 端没车辆消息接口
        }
        for vehicle in evaluated {
            let key = vehicle.vin?.isEmpty == false ? vehicle.vin! : "\(vehicle.accountId ?? "")|\(vehicle.titleText)"
            let previous = updated[key]
            let account = accountRows.first { $0.id == vehicle.accountId }
            let mail = account.map { accountMail[$0.id] } ?? nil
            let step = VehicleWatch.evaluate(previous: previous, vehicle: vehicle, prefs: prefs, mail: mail)
            updated[key] = step.slot
            for note in step.notes {
                ZeehoNotifier.vehicle(note)
            }
        }
        ZeehoFiles.saveWatch(updated)
    }
}

// MARK: - 持久化

extension ZeehoFiles {
    static func watchPrefs() -> WatchPrefs {
        let url = directory().appendingPathComponent("watch-prefs.json")
        if let data = try? Data(contentsOf: url),
           let prefs = try? JSONDecoder().decode(WatchPrefs.self, from: data) {
            return prefs
        }
        return WatchPrefs()
    }

    static func saveWatchPrefs(_ prefs: WatchPrefs) {
        let url = directory().appendingPathComponent("watch-prefs.json")
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func loadWatch() -> [String: WatchSlot] {
        let url = directory().appendingPathComponent("watch-slots.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: WatchSlot].self, from: data) else { return [:] }
        return raw
    }

    static func saveWatch(_ slots: [String: WatchSlot]) {
        let url = directory().appendingPathComponent("watch-slots.json")
        guard let data = try? JSONEncoder().encode(slots) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
