import Darwin
import Foundation
import UserNotifications

enum ZeehoTokenError: LocalizedError {
    case invalid
    case busy

    var errorDescription: String? {
        switch self {
        case .invalid:
            return "没有找到 UUID 格式的 Token"
        case .busy:
            return "正在签到，请稍后再试"
        }
    }
}

/// 同一进程里避免两路签到叠在一起。跨进程（App 与小组件）再用文件锁。
private enum ZeehoGate {
    private static let lock = NSLock()
    private static var running = false
    private static var generation = 0

    static func tryBegin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    static func end() {
        lock.lock()
        running = false
        lock.unlock()
    }

    static func bump() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    static var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
}

private enum ZeehoLock {
    struct Owner: Codable, Equatable {
        var pid: Int32
        var startedMs: Int64
    }

    static func tryAcquire() -> Owner? {
        let url = ZeehoFiles.directory().appendingPathComponent("engine.lock")
        if let data = try? Data(contentsOf: url),
           let owner = try? JSONDecoder().decode(Owner.self, from: data) {
            let age = Date().timeIntervalSince1970 * 1000 - Double(owner.startedMs)
            if age < 90_000, isAlive(owner.pid) {
                return nil
            }
        }
        let owner = Owner(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        guard let data = try? JSONEncoder().encode(owner) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return owner
    }

    static func release(_ owner: Owner) {
        let url = ZeehoFiles.directory().appendingPathComponent("engine.lock")
        guard let data = try? Data(contentsOf: url),
              let current = try? JSONDecoder().decode(Owner.self, from: data),
              current == owner else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

enum ZeehoEngine {
    static func refresh(ignoreGate: Bool) async -> SigninStatus {
        let cached = ZeehoFiles.loadStatus()
        if !ignoreGate, let cached, !shouldContact(cached, now: Date()) {
            await ZeehoFiles.ensureAvatars(cached)
            return await refillVoltageIfNeeded(cached)
        }
        guard ZeehoGate.tryBegin() else {
            return cached ?? .missingToken()
        }
        defer { ZeehoGate.end() }
        guard let owner = ZeehoLock.tryAcquire() else {
            return ZeehoFiles.loadStatus() ?? .missingToken()
        }
        defer { ZeehoLock.release(owner) }
        if !ignoreGate, let latest = ZeehoFiles.loadStatus(), !shouldContact(latest, now: Date()) {
            await ZeehoFiles.ensureAvatars(latest)
            return await refillVoltageIfNeeded(latest)
        }
        return await execute(generation: ZeehoGate.currentGeneration)
    }

    static func refillVoltageIfNeeded(_ status: SigninStatus) async -> SigninStatus {
        let missing = VehicleRoster.all(status).contains { ($0.voltageText ?? "").isEmpty && !($0.vin ?? "").isEmpty }
        guard missing, status.hasToken != false else { return status }
        let secrets = ZeehoConfig.current()
        let stored = ZeehoFiles.loadAccounts()
        var rows = status.accountRows
        var changed = false
        for index in rows.indices {
            guard rows[index].tokenInvalid != true,
                  let account = stored.first(where: { $0.id == rows[index].id }) else { continue }
            let fresh = await ZeehoClient().loadVehicles(token: account.token, secrets: secrets)
            guard !fresh.isEmpty else { continue }
            rows[index].vehicles = fresh.map { vehicle in
                var copy = vehicle
                if (copy.accountId ?? "").isEmpty { copy.accountId = account.id }
                return copy
            }
            rows[index].vehicle = rows[index].vehicles?.first
            changed = true
        }
        guard changed else { return status }
        var board = status
        board.accounts = rows
        let distinct = VehicleRoster.distinct(rows.flatMap(\.shownVehicles))
        if !distinct.isEmpty {
            board.vehicles = distinct
            board.vehicle = distinct[0]
        }
        ZeehoFiles.saveStatus(board)
        return board
    }

    static func watchIfDue() async -> SigninStatus {
        if Date().timeIntervalSince1970 - ZeehoFiles.loadWatchAt() < TimeInterval(ZeehoFiles.loadRefreshMinutes() * 60) {
            return ZeehoFiles.loadStatus() ?? .missingToken()
        }
        return await watch()
    }

    static func runPoints() async -> String {
        let stored = ZeehoFiles.loadAccounts()
        guard !stored.isEmpty else { return "先添加账号" }
        guard ZeehoGate.tryBegin() else { return "正在处理上一个请求" }
        defer { ZeehoGate.end() }
        guard let owner = ZeehoLock.tryAcquire() else { return "正在处理上一个请求" }
        defer { ZeehoLock.release(owner) }
        return await runPointsNow(stored: stored)
    }

    static func addAccount(_ raw: String) async throws -> SigninStatus {
        let token = ZeehoToken.normalize(raw)
        guard ZeehoToken.isUUID(token) else { throw ZeehoTokenError.invalid }
        guard ZeehoGate.tryBegin() else { throw ZeehoTokenError.busy }
        defer { ZeehoGate.end() }
        guard let owner = ZeehoLock.tryAcquire() else { throw ZeehoTokenError.busy }
        defer { ZeehoLock.release(owner) }
        var accounts = ZeehoFiles.loadAccounts()
        if !accounts.contains(where: { $0.token == token }) {
            accounts.append(ZeehoStoredAccount(id: UUID().uuidString.lowercased(), label: "", token: token))
            try ZeehoFiles.saveAccounts(accounts)
        }
        return await execute(generation: ZeehoGate.currentGeneration)
    }

    static func removeAccount(id: String) -> SigninStatus {
        ZeehoGate.bump()
        let stored = ZeehoFiles.loadAccounts().filter { $0.id != id }
        try? ZeehoFiles.saveAccounts(stored)
        if stored.isEmpty {
            let status = SigninStatus.missingToken()
            ZeehoFiles.saveStatus(status)
            return status
        }
        let cached = ZeehoFiles.loadStatus()?.accounts ?? []
        let rows = stored.map { account in
            cached.first { $0.id == account.id } ?? .pending(account)
        }
        let status = SigninStatus.aggregate(rows, now: Date())
        ZeehoFiles.saveStatus(status)
        return status
    }

    static func command(_ action: VehicleAction, accountId: String, vin: String, chargeValue: String? = nil) async -> String {
        guard let account = ZeehoFiles.loadAccounts().first(where: { $0.id == accountId }) else {
            return "找不到这个账号"
        }
        guard ZeehoGate.tryBegin() else { return "正在处理上一个请求" }
        defer { ZeehoGate.end() }
        return await ZeehoClient().command(action, token: account.token, vin: vin, secrets: ZeehoConfig.current(), chargeValue: chargeValue)
    }

    static func chargeOptions(accountId: String, vin: String) async -> [String] {
        guard let account = ZeehoFiles.loadAccounts().first(where: { $0.id == accountId }) else { return [] }
        guard ZeehoGate.tryBegin() else { return [] }
        defer { ZeehoGate.end() }
        return await ZeehoClient().chargeOptions(token: account.token, vin: vin, secrets: ZeehoConfig.current())
    }

    static func clearToken() {
        ZeehoGate.bump()
        ZeehoFiles.deleteToken()
        ZeehoFiles.saveStatus(.missingToken())
    }

    static func shouldContact(_ cached: SigninStatus, now: Date) -> Bool {
        if cached.hasToken == false { return false }
        if cached.tokenInvalid == true {
            let last = cached.lastAttemptUnix ?? 0
            return now.timeIntervalSince1970 - last >= 6 * 3600
        }
        if cached.signedToday == true, cached.today == ZeehoClock.todayString(now) {
            let updated = cached.updatedAtUnix ?? 0
            return now.timeIntervalSince1970 - updated >= 3 * 3600
        }
        let last = cached.lastAttemptUnix ?? 0
        return now.timeIntervalSince1970 - last >= 15 * 60
    }

    private static func execute(generation: Int) async -> SigninStatus {
        let now = Date()
        let cached = ZeehoFiles.loadStatus()
        let stored = ZeehoFiles.loadAccounts()
        guard !stored.isEmpty else {
            let status = SigninStatus.missingToken(now: now)
            ZeehoFiles.saveStatus(status)
            return status
        }
        if Task.isCancelled {
            return cached ?? .missingToken()
        }
        let secrets = ZeehoConfig.current()
        var rows: [AccountSignin] = []
        for account in stored {
            if Task.isCancelled {
                return cached ?? SigninStatus.aggregate(rows, now: Date())
            }
            let status = await ZeehoClient().run(token: account.token, secrets: secrets, now: now)
            let previous = cached?.accounts?.first { $0.id == account.id }
            var row = AccountSignin.make(account: account, status: status, previous: previous)
            await runPointsIfDue(account: account, secrets: secrets, row: &row)
            await ZeehoFiles.cacheAvatar(id: account.id, url: row.avatar)
            rows.append(row)
        }
        if Task.isCancelled {
            return cached ?? SigninStatus.aggregate(rows, now: Date())
        }
        let board = SigninStatus.aggregate(rows, now: Date())
        guard ZeehoGate.currentGeneration == generation else {
            return ZeehoFiles.loadStatus() ?? board
        }
        ZeehoFiles.saveStatus(board)
        await ZeehoWatch.deliver(previous: cached, current: board)
        ZeehoFiles.recordBatteries(VehicleRoster.all(board))
        ZeehoFiles.saveWatchAt()
        if rows.contains(where: { $0.posted == true }) {
            await ZeehoWatch.notify(title: board.displayTitle, body: board.message ?? board.displayTitle)
        }
        return board
    }

    private static func watch() async -> SigninStatus {
        let cached = ZeehoFiles.loadStatus() ?? .missingToken()
        guard cached.hasToken != false else { return cached }
        guard ZeehoGate.tryBegin() else { return cached }
        defer { ZeehoGate.end() }
        guard let owner = ZeehoLock.tryAcquire() else { return ZeehoFiles.loadStatus() ?? cached }
        defer { ZeehoLock.release(owner) }
        let secrets = ZeehoConfig.current()
        let stored = ZeehoFiles.loadAccounts()
        guard !stored.isEmpty else { return cached }
        var rows: [AccountSignin] = []
        for account in stored {
            var previous = cached.accounts?.first { $0.id == account.id } ?? .pending(account)
            if previous.tokenInvalid == true {
                rows.append(previous)
                continue
            }
            let vehicles = await ZeehoClient().loadVehicles(token: account.token, secrets: secrets)
            if !vehicles.isEmpty {
                previous.vehicles = vehicles.map { vehicle in
                    var copy = vehicle
                    if (copy.accountId ?? "").isEmpty { copy.accountId = account.id }
                    return copy
                }
                previous.vehicle = previous.vehicles?.first
            }
            if let uid = previous.userId, !uid.isEmpty {
                var scratch = SigninStatus()
                scratch.userId = uid
                await ZeehoClient().fillInbox(token: account.token, secrets: secrets, status: &scratch)
                previous.unread = scratch.unread ?? previous.unread
                if let text = scratch.latestMessage, !text.isEmpty { previous.latestMessage = text }
                if let id = scratch.latestMessageId, !id.isEmpty { previous.latestMessageId = id }
            }
            rows.append(previous)
        }
        var board = cached
        board.accounts = rows
        let vehicles = VehicleRoster.distinct(rows.flatMap(\.shownVehicles))
        if !vehicles.isEmpty {
            board.vehicles = vehicles
            board.vehicle = vehicles[0]
        }
        ZeehoFiles.saveStatus(board)
        await ZeehoWatch.deliver(previous: cached, current: board)
        ZeehoFiles.recordBatteries(VehicleRoster.all(board))
        ZeehoFiles.saveWatchAt()
        return board
    }

    private static func runPointsIfDue(account: ZeehoStoredAccount, secrets: ZeehoSecrets, row: inout AccountSignin) async {
        var prefs = ZeehoFiles.loadPoints()
        guard prefs.enabled, row.tokenInvalid != true, let uid = row.userId, !uid.isEmpty else { return }
        let today = ZeehoClock.todayString()
        if prefs.days[account.id] == today { return }
        let run = await ZeehoClient().runCommunityTasks(token: account.token, userId: uid, secrets: secrets, prefs: prefs)
        prefs.result = run.text
        if run.ok { prefs.days[account.id] = today }
        ZeehoFiles.savePoints(prefs)
        let prior = row.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        row.message = prior.isEmpty ? run.text : "\(prior)\n\(run.text)"
    }

    private static func runPointsNow(stored: [ZeehoStoredAccount]) async -> String {
        let secrets = ZeehoConfig.current()
        let cached = ZeehoFiles.loadStatus()
        var prefs = ZeehoFiles.loadPoints()
        var lines: [String] = []
        for account in stored {
            let row = cached?.accounts?.first { $0.id == account.id }
            let label = account.label.isEmpty ? (row?.displayName ?? "账号") : account.label
            if row?.tokenInvalid == true {
                lines.append("\(label)：登录态已失效")
                continue
            }
            guard let uid = row?.userId, !uid.isEmpty else {
                lines.append("没有账号 ID。下拉刷新一次签到后再试（会从 baseInfo.id 读取）")
                continue
            }
            let run = await ZeehoClient().runCommunityTasks(token: account.token, userId: uid, secrets: secrets, prefs: prefs)
            if run.ok { prefs.days[account.id] = ZeehoClock.todayString() }
            lines.append("\(label)：\(run.text)")
        }
        let summary = lines.joined(separator: "\n")
        prefs.result = summary
        ZeehoFiles.savePoints(prefs)
        return summary
    }
}

struct ZeehoWatchPrefs: Codable, Equatable, Sendable {
    var charge = true
    var messages = true
    var low = false
    var offline = false
    var tire = false
}

struct ZeehoWatchSlot: Codable, Equatable, Sendable {
    var charge: String?
    var online: Bool?
    var lowNotified = false
    var tireNotified = false
    var msgId: String?
}

enum ZeehoWatch {
    private static let low = 20
    private static let clear = 25
    private static let tireBar = 1.9

    static func requestAccess() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            return true
        }
        if settings.authorizationStatus == .denied { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func deliver(previous: SigninStatus?, current: SigninStatus) async {
        let prefs = ZeehoFiles.loadWatchPrefs()
        guard prefs.charge || prefs.messages || prefs.low || prefs.offline || prefs.tire else { return }
        var slots = ZeehoFiles.loadWatchSlots()
        var mailed: Set<String> = []
        for vehicle in VehicleRoster.all(current) {
            let key = slotKey(vehicle)
            if key.isEmpty { continue }
            let accountId = vehicle.accountId ?? ""
            let mail = current.accounts?.first { $0.id == accountId }
            let includeMail = !accountId.isEmpty && mailed.insert(accountId).inserted
            let notes = notes(
                previous: slots[key],
                vehicle: vehicle,
                prefs: prefs,
                mail: includeMail ? mail : nil
            )
            slots[key] = notes.slot
            for note in notes.items {
                await post(note, key: key)
            }
        }
        ZeehoFiles.saveWatchSlots(slots)
    }

    private static func notes(
        previous: ZeehoWatchSlot?,
        vehicle: VehicleStatus,
        prefs: ZeehoWatchPrefs,
        mail: AccountSignin?
    ) -> (slot: ZeehoWatchSlot, items: [Note]) {
        let nowCharge = vehicle.chargeDisplay
        let nowOnline = online(vehicle.onlineText)
        var lowNotified = previous?.lowNotified == true
        var tireNotified = previous?.tireNotified == true
        var items: [Note] = []
        let seen = previous != nil

        if prefs.charge {
            if nowCharge == "充电中" {
                let soc = vehicle.battery.map { " · \($0)%" } ?? ""
                let extra = [vehicle.powerText, vehicle.etaText.map { "预计 \($0) 充满" }]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                items.append(Note(kind: "progress", title: "充电中\(soc)", body: extra.isEmpty ? "充电器已连接" : extra))
                if seen, previous?.charge != "充电中" {
                    let text = vehicle.battery.map { "当前电量 \($0)%" } ?? "充电器已连接"
                    items.append(Note(kind: "start", title: "开始充电", body: text))
                }
            } else if previous?.charge == "充电中" {
                items.append(Note(kind: "progress", title: "", body: "", cancel: true))
            }
            if seen, previous?.charge == "充电中", nowCharge == "充电完成" {
                let text = vehicle.battery.map { "当前电量 \($0)%，可以拔枪了" } ?? "可以拔枪了"
                items.append(Note(kind: "done", title: "已充满", body: text))
            }
            if seen, previous?.charge == "充电中", nowCharge == "未充电" {
                let text = vehicle.battery.map { "当前电量 \($0)% · 充电器已断开" } ?? "充电器已断开"
                items.append(Note(kind: "stop", title: "充电已停止", body: text))
            }
        }

        let soc = vehicle.battery
        let charging = nowCharge == "充电中" || nowCharge == "充电完成"
        if soc == nil || (soc ?? 0) >= clear || charging { lowNotified = false }
        if prefs.low, seen, let soc, soc >= 0, soc <= low, !charging, !lowNotified {
            items.append(Note(kind: "low", title: "电量偏低", body: "当前电量 \(soc)%，建议尽快充电"))
            lowNotified = true
        }

        if prefs.offline, seen, previous?.online == true, nowOnline == false {
            items.append(Note(kind: "offline", title: "车辆离线", body: "\(vehicle.titleText) 已离线，状态与充电可能停止更新"))
        }

        let problem = tireProblem(vehicle)
        if problem == nil { tireNotified = false }
        if prefs.tire, seen, let problem, !tireNotified {
            items.append(Note(kind: "tire", title: "胎压异常", body: problem))
            tireNotified = true
        }

        var msgId = previous?.msgId
        if let mail, let id = mail.latestMessageId, !id.isEmpty {
            if prefs.messages, seen, let prior = previous?.msgId, prior != id, (mail.unread ?? 0) > 0 {
                let body = (mail.latestMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let text = body.isEmpty ? "有新的车辆消息" : body
                items.append(Note(kind: "mail", title: "新车辆消息", body: "\(mail.unread ?? 0) 条未读 · \(text)"))
            }
            msgId = id
        }

        return (
            ZeehoWatchSlot(
                charge: nowCharge,
                online: nowOnline ?? previous?.online,
                lowNotified: lowNotified,
                tireNotified: tireNotified,
                msgId: msgId
            ),
            items
        )
    }

    private static func tireProblem(_ vehicle: VehicleStatus) -> String? {
        var parts: [String] = []
        if let front = vehicle.frontBar, front > 0, front < tireBar {
            parts.append(String(format: "前轮 %.1f bar", front))
        }
        if let rear = vehicle.rearBar, rear > 0, rear < tireBar {
            parts.append(String(format: "后轮 %.1f bar", rear))
        }
        if !parts.isEmpty { return parts.joined(separator: "，") + "，低于警戒值" }
        if vehicle.tireWarn { return "\(vehicle.titleText) 车机报胎压异常" }
        return nil
    }

    private static func online(_ text: String?) -> Bool? {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "未知" { return nil }
        if value.contains("离线") || value.uppercased() == "OFFLINE" || value == "0" { return false }
        if value.contains("在线") || value.uppercased() == "ONLINE" || value == "1" { return true }
        return nil
    }

    static func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "zeeho.signin", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func slotKey(_ vehicle: VehicleStatus) -> String {
        (vehicle.vin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func post(_ note: Note, key: String) async {
        let center = UNUserNotificationCenter.current()
        let id = "zeeho.watch.\(note.kind).\(stable(key))"
        if note.cancel {
            center.removeDeliveredNotifications(withIdentifiers: [id])
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = note.kind == "progress" ? nil : .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await center.add(request)
    }

    private static func stable(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private struct Note {
        var kind: String
        var title: String
        var body: String
        var cancel = false
    }
}
