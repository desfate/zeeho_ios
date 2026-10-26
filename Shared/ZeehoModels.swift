import Foundation

struct VehicleStatus: Codable, Equatable, Sendable {
    var vehicleName: String?
    var vehiclePicUrl: String?
    var battery: Int?
    var rangeKm: Int?
    var mileageKm: Double?
    var lockText: String?
    var chargeText: String?
    var currentText: String?
    var powerText: String?
    var etaText: String?
    var chargedText: String?
    var rideState: String?
    var signal: String?
    var locationTime: String?
    var address: String?
    var pressureText: String?
    var otaVersion: String?
    var vin: String?
    var voltageText: String?
    var cushionText: String?
    var onlineText: String?
    var todayRideText: String?
    var lastRideText: String?
    var latitude: Double?
    var longitude: Double?
    var frontBar: Double?
    var rearBar: Double?
    var tireWarn: Bool = false
    var accountId: String?
    // Android 版补齐字段
    var currentText: String?
    var powerText: String?
    var etaText: String?
    var chargedText: String?
    var frontBar: Double?
    var rearBar: Double?
    var tireWarn: Bool = false

    var mileageText: String {
        guard let mileageKm else { return "—" }
        return "\(Int(mileageKm.rounded())) km"
    }

    var batteryText: String {
        battery.map { "\($0)%" } ?? "—"
    }

    var rangeText: String {
        rangeKm.map { "\($0) km" } ?? "—"
    }

    var titleText: String {
        let name = vehicleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "车辆" : name
    }

    var chargeDisplay: String {
        let text = (chargeText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let code = text.split(separator: ".").first.map(String.init) ?? text
        switch code {
        case "0", "未充电":
            return "未充电"
        case "1", "充电中":
            return "充电中"
        case "2", "充电完成", "已充满":
            return "充电完成"
        case "", "未知":
            return "未知"
        default:
            if text.contains("充电完成") || text.contains("已充满") { return "充电完成" }
            if text.contains("充电中") { return "充电中" }
            if text.contains("未充电") { return "未充电" }
            return "未知"
        }
    }

    var locationText: String {
        (locationTime ?? "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var onlineDisplay: String {
        VehicleRoster.onlineLabel(onlineText) ?? "—"
    }
}

enum VehicleRoster {
    static func all(_ status: SigninStatus) -> [VehicleStatus] {
        let rows = status.accountRows.flatMap(\.shownVehicles)
        let source: [VehicleStatus]
        if !rows.isEmpty {
            source = rows
        } else if let vehicles = status.vehicles, !vehicles.isEmpty {
            source = vehicles
        } else if let vehicle = status.vehicle {
            source = [vehicle]
        } else {
            source = []
        }
        return distinct(source)
    }

    static func distinct(_ source: [VehicleStatus]) -> [VehicleStatus] {
        var unique: [VehicleStatus] = []
        for vehicle in source {
            if let index = unique.firstIndex(where: { same($0, vehicle) }) {
                unique[index] = merge(unique[index], vehicle)
            } else {
                unique.append(vehicle)
            }
        }
        return unique
    }

    static func same(_ lhs: VehicleStatus, _ rhs: VehicleStatus) -> Bool {
        let leftVin = vinKey(lhs.vin)
        let rightVin = vinKey(rhs.vin)
        if !leftVin.isEmpty, !rightVin.isEmpty, leftVin == rightVin { return true }
        let leftName = nameKey(lhs.titleText)
        let rightName = nameKey(rhs.titleText)
        return !leftName.isEmpty && leftName != "车辆" && leftName == rightName
    }

    private static func vinKey(_ vin: String?) -> String {
        (vin ?? "").uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func nameKey(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func key(_ vehicle: VehicleStatus) -> String {
        let vin = vehicle.vin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !vin.isEmpty { return "vin:\(vin)" }
        return "account:\(vehicle.accountId ?? "")"
    }

    static func caption(_ status: SigninStatus, _ vehicle: VehicleStatus) -> String {
        let account = status.accountRows.first { $0.id == vehicle.accountId }?.displayName
        let name = vehicle.titleText
        if let account, !account.isEmpty, account != name { return "\(account) · \(name)" }
        return name
    }

    static func merge(_ base: VehicleStatus, _ extra: VehicleStatus) -> VehicleStatus {
        var vehicle = score(extra) > score(base) ? extra : base
        let other = score(extra) > score(base) ? base : extra
        func pick(_ a: String?, _ b: String?) -> String? {
            let left = a?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !left.isEmpty { return left }
            let right = b?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return right.isEmpty ? nil : right
        }
        vehicle.vehicleName = pick(vehicle.vehicleName, other.vehicleName)
        vehicle.vehiclePicUrl = pick(vehicle.vehiclePicUrl, other.vehiclePicUrl)
        vehicle.lockText = preferKnown(vehicle.lockText, other.lockText)
        vehicle.chargeText = preferKnown(vehicle.chargeText, other.chargeText)
        vehicle.rideState = pick(vehicle.rideState, other.rideState)
        vehicle.signal = pick(vehicle.signal, other.signal)
        vehicle.locationTime = pick(vehicle.locationTime, other.locationTime)
        vehicle.address = pick(vehicle.address, other.address)
        vehicle.pressureText = pick(vehicle.pressureText, other.pressureText)
        vehicle.otaVersion = pick(vehicle.otaVersion, other.otaVersion)
        vehicle.vin = pick(vehicle.vin, other.vin)
        vehicle.voltageText = pick(vehicle.voltageText, other.voltageText)
        vehicle.cushionText = preferKnown(vehicle.cushionText, other.cushionText)
        vehicle.onlineText = pick(vehicle.onlineText, other.onlineText)
        vehicle.todayRideText = pick(vehicle.todayRideText, other.todayRideText)
        vehicle.lastRideText = pick(vehicle.lastRideText, other.lastRideText)
        vehicle.powerText = pick(vehicle.powerText, other.powerText)
        vehicle.currentText = pick(vehicle.currentText, other.currentText)
        vehicle.etaText = pick(vehicle.etaText, other.etaText)
        vehicle.chargedText = pick(vehicle.chargedText, other.chargedText)
        if vehicle.battery == nil { vehicle.battery = other.battery }
        if vehicle.rangeKm == nil { vehicle.rangeKm = other.rangeKm }
        if vehicle.mileageKm == nil { vehicle.mileageKm = other.mileageKm }
        if vehicle.latitude == nil { vehicle.latitude = other.latitude }
        if vehicle.longitude == nil { vehicle.longitude = other.longitude }
        if vehicle.frontBar == nil { vehicle.frontBar = other.frontBar }
        if vehicle.rearBar == nil { vehicle.rearBar = other.rearBar }
        if (vehicle.accountId ?? "").isEmpty { vehicle.accountId = other.accountId }
        vehicle.tireWarn = vehicle.tireWarn || other.tireWarn
        return vehicle
    }

    static func onlineLabel(_ raw: String?) -> String? {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return nil }
        if flagOn(text) || text.uppercased() == "ONLINE" || text.contains("在线") { return "在线" }
        if text.uppercased() == "OFFLINE" || text.contains("离线") { return "离线" }
        return text
    }

    static func flagOn(_ any: Any?) -> Bool {
        let text = ZeehoJSON.string(any).trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "1" || text.lowercased() == "true" || text.uppercased() == "ONLINE"
    }

    static func minutesLabel(_ minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0, rest > 0 { return "\(hours)小时\(rest)分" }
        if hours > 0 { return "\(hours)小时" }
        return "\(rest)分钟"
    }

    private static func preferKnown(_ primary: String?, _ secondary: String?) -> String? {
        let a = primary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let b = secondary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !a.isEmpty, a != "未知" { return a }
        if !b.isEmpty, b != "未知" { return b }
        if !a.isEmpty { return a }
        return b.isEmpty ? nil : b
    }

    private static func score(_ vehicle: VehicleStatus) -> Int {
        var n = 0
        if vehicle.battery != nil { n += 2 }
        if vehicle.rangeKm != nil { n += 1 }
        if vehicle.mileageKm != nil { n += 1 }
        if !(vehicle.voltageText ?? "").isEmpty { n += 1 }
        if !(vehicle.pressureText ?? "").isEmpty { n += 1 }
        if !(vehicle.address ?? "").isEmpty { n += 1 }
        if !(vehicle.powerText ?? "").isEmpty { n += 1 }
        if !(vehicle.etaText ?? "").isEmpty { n += 1 }
        if !(vehicle.chargedText ?? "").isEmpty { n += 1 }
        if !(vehicle.todayRideText ?? "").isEmpty { n += 1 }
        if let lock = vehicle.lockText, !lock.isEmpty, lock != "未知" { n += 1 }
        return n
    }
}

enum ZeehoWidgetFact: String, CaseIterable, Codable, Sendable {
    case battery, mileage, lock, charge, pressure, signal, voltage, power, eta, charged, ride, address

    var title: String {
        switch self {
        case .battery: return "电量"
        case .mileage: return "总里程"
        case .lock: return "车锁"
        case .charge: return "充电"
        case .pressure: return "胎压"
        case .signal: return "信号"
        case .voltage: return "电压"
        case .power: return "功率"
        case .eta: return "充满"
        case .charged: return "已充"
        case .ride: return "今日骑行"
        case .address: return "位置"
        }
    }

    func text(_ vehicle: VehicleStatus) -> String {
        switch self {
        case .battery: return vehicle.batteryText
        case .mileage: return vehicle.mileageText
        case .lock: return vehicle.lockText?.isEmpty == false ? vehicle.lockText! : "—"
        case .charge: return vehicle.chargeDisplay
        case .pressure: return vehicle.pressureText?.isEmpty == false ? vehicle.pressureText! : "—"
        case .signal: return vehicle.signal?.isEmpty == false ? vehicle.signal! : "—"
        case .voltage: return vehicle.voltageText?.isEmpty == false ? vehicle.voltageText! : "—"
        case .power: return vehicle.powerText?.isEmpty == false ? vehicle.powerText! : "—"
        case .eta: return vehicle.etaText?.isEmpty == false ? vehicle.etaText! : "—"
        case .charged: return vehicle.chargedText?.isEmpty == false ? vehicle.chargedText! : "—"
        case .ride: return vehicle.todayRideText?.isEmpty == false ? vehicle.todayRideText! : "—"
        case .address: return vehicle.address?.isEmpty == false ? vehicle.address! : "暂无位置"
        }
    }

    static let columns = 3
    static let rows = 2
    static let limit = columns * rows
    static let fallback: [ZeehoWidgetFact] = [.mileage, .pressure, .signal]
}

struct ZeehoWidgetConfig: Codable, Equatable, Sendable {
    var facts: [String] = ZeehoWidgetFact.fallback.map(\.rawValue)
    var actions: [String] = ["find", "horn", "seat"]
    var vehicleKey = ""

    var shownFacts: [ZeehoWidgetFact] {
        let picked = facts.compactMap(ZeehoWidgetFact.init(rawValue:)).uniqued().prefix(ZeehoWidgetFact.limit)
        return picked.isEmpty ? ZeehoWidgetFact.fallback : Array(picked)
    }

    var shownActions: [VehicleAction] {
        let options: [VehicleAction] = [.find, .horn, .seat, .unlock, .lock]
        return actions.compactMap(VehicleAction.init(rawValue:)).filter { options.contains($0) }.uniqued().prefix(3).map { $0 }
    }
}

struct ZeehoPointsPrefs: Codable, Equatable, Sendable {
    var enabled = false
    var content = "今日打卡"
    var deleteAfter = true
    var gapMs = 800
    var days: [String: String] = [:]
    var result = ""
}

struct ZeehoBatterySample: Codable, Equatable, Sendable {
    var vin: String
    var name: String
    var at: TimeInterval
    var soc: Int?
    var voltage: String?
    var power: String?
    var charge: String?
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

struct AccountSignin: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var nickName: String?
    var avatar: String?
    var signedToday: Bool?
    var tokenInvalid: Bool?
    var continueDays: Int?
    var totalIntegral: Int?
    var lastTime: String?
    var message: String?
    var ok: Bool?
    var posted: Bool?
    var userId: String?
    var unread: Int?
    var latestMessage: String?
    var latestMessageId: String?
    var vehicle: VehicleStatus?
    var vehicles: [VehicleStatus]?

    var displayName: String {
        if let nickName, !nickName.isEmpty { return nickName }
        if !label.isEmpty { return label }
        return "账号"
    }

    var chip: String {
        if tokenInvalid == true { return "失效" }
        return signedToday == true ? "已签" : "未签"
    }

    var pointsText: String {
        totalIntegral.map(String.init) ?? "—"
    }

    var continueText: String {
        continueDays.map { "\($0) 天" } ?? "—"
    }

    var shownVehicles: [VehicleStatus] {
        if let vehicles, !vehicles.isEmpty { return vehicles }
        if let vehicle { return [vehicle] }
        return []
    }

    static func pending(_ account: ZeehoStoredAccount) -> AccountSignin {
        AccountSignin(
            id: account.id,
            label: account.label,
            signedToday: false,
            tokenInvalid: false,
            message: "等待刷新",
            ok: false
        )
    }

    static func make(account: ZeehoStoredAccount, status: SigninStatus, previous: AccountSignin?) -> AccountSignin {
        var row = AccountSignin(
            id: account.id,
            label: account.label,
            nickName: status.nickName,
            avatar: status.avatar,
            signedToday: status.signedToday,
            tokenInvalid: status.tokenInvalid,
            continueDays: status.continueDays,
            totalIntegral: status.totalIntegral ?? status.integral,
            lastTime: status.lastTime,
            message: status.message,
            ok: status.ok,
            posted: status.posted,
            userId: status.userId,
            unread: status.unread,
            latestMessage: status.latestMessage,
            latestMessageId: status.latestMessageId,
            vehicle: status.vehicle.map { Self.tagged($0, account: account.id) },
            vehicles: status.vehicles?.map { Self.tagged($0, account: account.id) }
        )
        guard let previous else { return row }
        if row.vehicle == nil { row.vehicle = previous.vehicle }
        if row.vehicles == nil || row.vehicles?.isEmpty == true { row.vehicles = previous.vehicles }
        if (row.nickName ?? "").isEmpty { row.nickName = previous.nickName }
        if (row.avatar ?? "").isEmpty { row.avatar = previous.avatar }
        if row.totalIntegral == nil { row.totalIntegral = previous.totalIntegral }
        if row.continueDays == nil { row.continueDays = previous.continueDays }
        if (row.lastTime ?? "").isEmpty { row.lastTime = previous.lastTime }
        if (row.userId ?? "").isEmpty { row.userId = previous.userId }
        if row.unread == nil { row.unread = previous.unread }
        if (row.latestMessage ?? "").isEmpty { row.latestMessage = previous.latestMessage }
        if (row.latestMessageId ?? "").isEmpty { row.latestMessageId = previous.latestMessageId }
        return row
    }

    private static func tagged(_ vehicle: VehicleStatus, account id: String) -> VehicleStatus {
        var vehicle = vehicle
        if (vehicle.accountId ?? "").isEmpty { vehicle.accountId = id }
        return vehicle
    }
}

struct SigninStatus: Codable, Equatable, Sendable {
    var ok: Bool?
    var title: String?
    var message: String?
    var error: String?
    var today: String?
    var nickName: String?
    var avatar: String?
    var userId: String?
    var unread: Int?
    var latestMessage: String?
    var latestMessageId: String?
    var signedToday: Bool?
    var lastTime: String?
    var continueDays: Int?
    var integral: Int?
    var totalIntegral: Int?
    var signinIntegral: Int?
    var tokenInvalid: Bool?
    var posted: Bool?
    var vehicle: VehicleStatus?
    var updatedAt: String?
    var updatedAtUnix: TimeInterval?
    var lastAttemptUnix: TimeInterval?
    var hasToken: Bool?
    var accounts: [AccountSignin]?
    var vehicles: [VehicleStatus]?

    static func missingToken(now: Date = Date()) -> SigninStatus {
        SigninStatus(
            ok: false,
            title: "未配置 Token",
            message: "打开极核签到，粘贴 Authorization 里的 Token",
            error: "未配置 Token",
            today: ZeehoClock.todayString(now),
            signedToday: false,
            tokenInvalid: true,
            updatedAt: ZeehoClock.nowString(now),
            updatedAtUnix: now.timeIntervalSince1970,
            hasToken: false
        )
    }

    static var sample: SigninStatus {
        let now = Date()
        return SigninStatus(
            ok: true,
            title: "今日已签到",
            message: "今日已签到（连续 12 天）",
            today: ZeehoClock.todayString(now),
            nickName: "ZEEHO",
            signedToday: true,
            lastTime: ZeehoClock.todayString(now) + " 08:30:00",
            continueDays: 12,
            integral: 1280,
            totalIntegral: 1280,
            signinIntegral: 3,
            tokenInvalid: false,
            posted: false,
            vehicle: VehicleStatus(
                vehicleName: "ZEEHO",
                battery: 80,
                rangeKm: 64,
                mileageKm: 1234,
                lockText: "已锁",
                chargeText: "未充电",
                rideState: "停放",
                signal: "强",
                locationTime: "08:30"
            ),
            updatedAt: ZeehoClock.nowString(now),
            updatedAtUnix: now.timeIntervalSince1970,
            hasToken: true
        )
    }

    var accountRows: [AccountSignin] { accounts ?? [] }

    var displayTitle: String {
        let rows = accountRows
        if rows.count > 1 {
            let valid = rows.filter { $0.tokenInvalid != true }
            let signed = valid.filter { $0.signedToday == true }.count
            if valid.isEmpty { return "Token 失效" }
            if signed == valid.count { return "全部已签到 \(signed)/\(rows.count)" }
            if signed == 0 { return "今日未签到 0/\(rows.count)" }
            return "部分已签到 \(signed)/\(rows.count)"
        }
        if tokenInvalid == true { return "Token 失效" }
        if hasToken == false { return "未配置 Token" }
        if signedToday == true { return "今日已签到" }
        if ok == false { return "签到失败" }
        return "今日未签到"
    }

    var chipText: String {
        let rows = accountRows
        if rows.count > 1 {
            let valid = rows.filter { $0.tokenInvalid != true }
            if valid.isEmpty { return "需 Token" }
            let signed = valid.filter { $0.signedToday == true }.count
            return "\(signed)/\(rows.count)"
        }
        if tokenInvalid == true || hasToken == false { return "需 Token" }
        return signedToday == true ? "已签到" : "未签到"
    }

    static func aggregate(_ rows: [AccountSignin], now: Date) -> SigninStatus {
        if rows.isEmpty { return .missingToken(now: now) }
        let valid = rows.filter { $0.tokenInvalid != true }
        let signed = valid.filter { $0.signedToday == true }
        let primary = valid.first ?? rows[0]
        var status = SigninStatus()
        status.accounts = rows
        status.hasToken = true
        status.today = ZeehoClock.todayString(now)
        status.updatedAt = ZeehoClock.nowString(now)
        status.updatedAtUnix = now.timeIntervalSince1970
        status.lastAttemptUnix = now.timeIntervalSince1970
        status.tokenInvalid = valid.isEmpty
        status.signedToday = !valid.isEmpty && signed.count == valid.count
        status.posted = rows.contains { $0.posted == true }
        status.nickName = primary.nickName
        status.avatar = primary.avatar
        status.continueDays = primary.continueDays
        status.lastTime = primary.lastTime
        status.vehicle = VehicleRoster.distinct(rows.flatMap(\.shownVehicles)).first
        status.vehicles = VehicleRoster.distinct(rows.flatMap(\.shownVehicles))
        if rows.count > 1 {
            let totals = valid.compactMap(\.totalIntegral)
            status.totalIntegral = totals.isEmpty ? nil : totals.reduce(0, +)
        } else {
            status.totalIntegral = primary.totalIntegral
        }
        status.integral = status.totalIntegral
        let lines = rows.map { "\($0.displayName)：\($0.message ?? $0.chip)" }
        status.message = lines.joined(separator: "\n")
        if valid.isEmpty {
            status.ok = false
            status.title = "Token 失效"
            status.error = status.message
        } else if signed.count == valid.count {
            status.ok = true
            status.error = nil
            status.title = rows.count == 1
                ? (primary.posted == true ? "签到成功" : "今日已签到")
                : "全部已签到 \(signed.count)/\(rows.count)"
        } else if signed.isEmpty {
            status.ok = false
            status.title = rows.count == 1
                ? (primary.ok == false ? "签到失败" : "今日未签到")
                : "今日未签到 0/\(rows.count)"
            status.error = status.message
        } else {
            status.ok = false
            status.title = "部分已签到 \(signed.count)/\(rows.count)"
            status.error = rows
                .filter { $0.tokenInvalid == true || $0.signedToday != true }
                .map { "\($0.displayName)：\($0.message ?? "未签到")" }
                .joined(separator: "\n")
        }
        return status
    }

    var pointsText: String {
        if let value = totalIntegral ?? integral { return String(value) }
        return "—"
    }

    var continueText: String {
        guard let continueDays else { return "—" }
        return "\(continueDays) 天"
    }

    var lastTimeText: String {
        guard let lastTime, !lastTime.isEmpty else { return "—" }
        let parts = lastTime.split(separator: " ")
        if parts.count >= 2 { return String(parts[1].prefix(5)) }
        return lastTime
    }

    var updatedText: String {
        guard let updatedAt, updatedAt.count >= 16 else { return updatedAt ?? "" }
        let monthDay = updatedAt.dropFirst(5).prefix(5)
        let hourMinute = updatedAt.dropFirst(11).prefix(5)
        return "\(monthDay) \(hourMinute)"
    }

    var pointsCaption: String {
        accountRows.count > 1 ? "积分合计" : "总积分"
    }

    var problemText: String? {
        if hasToken == false {
            return "先粘贴 Token，小组件才能自动打卡"
        }
        if accountRows.count > 1, ok != true {
            let text = error ?? message ?? ""
            return text.isEmpty ? nil : text
        }
        if tokenInvalid == true {
            return message ?? "Token 失效，请重新粘贴 Authorization"
        }
        if ok == false {
            let text = error ?? message ?? ""
            return text.isEmpty ? nil : text
        }
        return nil
    }

    func markedUnsigned(at midnight: Date) -> SigninStatus {
        var pending = self
        pending.signedToday = false
        pending.ok = true
        pending.posted = false
        pending.error = nil
        pending.tokenInvalid = false
        pending.title = accountRows.count > 1 ? "今日未签到 0/\(accountRows.count)" : "今日未签到"
        pending.message = "等待今日自动签到"
        pending.today = ZeehoClock.todayString(midnight)
        pending.accounts = accountRows.map { row in
            var row = row
            row.signedToday = false
            row.ok = true
            row.posted = false
            row.message = "等待今日自动签到"
            return row
        }
        return pending
    }
}

enum VehicleAction: String, Identifiable, Sendable {
    case find
    case horn
    case seat
    case unlock
    case lock
    case charge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .find: return "寻车"
        case .horn: return "鸣笛"
        case .seat: return "开坐垫"
        case .unlock: return "开锁"
        case .lock: return "关锁"
        case .charge: return "充电功率"
        }
    }

    var confirmText: String {
        switch self {
        case .find: return "车辆会闪灯。"
        case .horn: return "车辆会鸣笛并闪灯。"
        case .seat: return "坐垫锁会弹开。"
        case .unlock: return "车辆会云端开锁。"
        case .lock: return "车辆会云端关锁。"
        case .charge: return "会修改这辆车的充电功率。"
        }
    }
}

struct ZeehoWidgetFields: Equatable, Sendable {
    var battery = true
    var range = true
    var mileage = false
    var lock = true
    var charge = false
    var pressure = false
    var address = false
    var signal = false
    var voltage = false
    var power = false
    var eta = false
    var ride = false

    func lines(for vehicle: VehicleStatus) -> [(String, String)] {
        var rows: [(String, String)] = []
        func add(_ title: String, _ value: String?, enabled: Bool) {
            guard enabled else { return }
            let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append((title, text.isEmpty ? "—" : text))
        }
        add("电量", vehicle.batteryText, enabled: battery)
        add("续航", vehicle.rangeText, enabled: range)
        add("里程", vehicle.mileageText, enabled: mileage)
        add("车锁", vehicle.lockText, enabled: lock)
        add("充电", vehicle.chargeDisplay, enabled: charge)
        add("胎压", vehicle.pressureText, enabled: pressure)
        add("电压", vehicle.voltageText, enabled: voltage)
        add("功率", vehicle.powerText, enabled: power)
        add("充满", vehicle.etaText, enabled: eta)
        add("信号", vehicle.signal, enabled: signal)
        add("今日骑行", vehicle.todayRideText, enabled: ride)
        add("地址", vehicle.address, enabled: address)
        return rows
    }
}

enum ZeehoClock {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func todayString(_ date: Date = Date()) -> String {
        format(date, "yyyy-MM-dd")
    }

    static func nowString(_ date: Date = Date()) -> String {
        format(date, "yyyy-MM-dd HH:mm:ss")
    }

    static func monthQuery(from today: String) -> String {
        let parts = today.split(separator: "-")
        guard parts.count >= 2, let month = Int(parts[1]) else { return today }
        return "\(parts[0])-\(month)"
    }

    /// 下一个 08:30（上海）。还没到就是今天，过了就是明天。
    static func nextSignSlot(after date: Date) -> Date {
        let calendar = calendar
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = 8
        parts.minute = 30
        parts.second = 0
        parts.timeZone = timeZone
        let slot = calendar.date(from: parts) ?? date
        if slot > date { return slot }
        return calendar.date(byAdding: .day, value: 1, to: slot) ?? date.addingTimeInterval(24 * 3600)
    }

    /// 骑行月报用 `yyyy.MM`。
    static func rideMonth(_ date: Date = Date()) -> String {
        format(date, "yyyy.MM")
    }

    static func nextMidnight(after date: Date) -> Date? {
        let calendar = calendar
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start)
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.calendar = calendar
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

enum ZeehoScheduler {
    /// 签到仍赶 08:30 和午夜。车况按用户选的间隔更新，最短 15 分钟，最长 24 小时。
    static func nextRefresh(after now: Date, status: SigninStatus) -> Date {
        let interval = TimeInterval(ZeehoFiles.loadRefreshMinutes() * 60)
        if status.hasToken == false || status.tokenInvalid == true {
            return now.addingTimeInterval(max(interval, 6 * 3600))
        }
        let morning = ZeehoClock.nextSignSlot(after: now)
        var soon = min(morning, now.addingTimeInterval(interval))
        if status.signedToday == true, status.today == ZeehoClock.todayString(now), let midnight = ZeehoClock.nextMidnight(after: now) {
            soon = min(soon, midnight.addingTimeInterval(5 * 60))
        }
        return soon
    }
}
