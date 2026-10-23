import Foundation
import UIKit

enum ZeehoToken {
    private static let uuid = try! NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )

    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = text.removingPercentEncoding {
            text = decoded
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if text.lowercased().hasPrefix("authorization:") {
            text = String(text.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let found = firstUUID(in: text) {
            return found
        }
        for part in text.split(whereSeparator: { $0 == "?" || $0 == "&" || $0 == "#" }) {
            let piece = String(part)
            guard piece.lowercased().hasPrefix("token=") else { continue }
            var value = String(piece.dropFirst("token=".count))
            if let decoded = value.removingPercentEncoding {
                value = decoded
            }
            if value.lowercased().hasPrefix("bearer ") {
                value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return firstUUID(in: value) ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return firstUUID(in: text) ?? text
    }

    static func isUUID(_ text: String) -> Bool {
        firstUUID(in: text) == text
    }

    private static func firstUUID(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = uuid.firstMatch(in: text, range: range),
              let hit = Range(match.range, in: text) else { return nil }
        return String(text[hit])
    }
}

struct ZeehoStagedCommand: Codable, Equatable, Sendable {
    var action: String
    var vin: String
    var accountId: String
    var name: String
}

struct ZeehoStoredAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var token: String
}

enum ZeehoFiles {
    static let appGroupID = "group.com.jieyu.zeeho.signin"

    static var usesAppGroup: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    static func directory() -> URL {
        let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZeehoSignin", isDirectory: true)
        let url: URL
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            url = group
            mergeAccounts(from: local, into: group)
        } else {
            url = local
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// App 和小组件原先各存一份账号。共享容器可用后，按 Token 合并，避免小组件只看到第一个账号。
    private static func mergeAccounts(from local: URL, into group: URL) {
        try? FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let source = decodeAccounts(local.appendingPathComponent("accounts.json"))
        let destination = decodeAccounts(group.appendingPathComponent("accounts.json"))
        var merged = destination
        for account in source where !merged.contains(where: { $0.token == account.token }) {
            merged.append(account)
        }
        if merged.count > destination.count {
            if let data = try? JSONEncoder.zeeho.encode(merged) {
                try? data.write(
                    to: group.appendingPathComponent("accounts.json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }
        }
        for name in ["status.json", "secrets.json", "token.seeded"] {
            let dest = group.appendingPathComponent(name)
            let src = local.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path),
               FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }
    }

    private static func decodeAccounts(_ url: URL) -> [ZeehoStoredAccount] {
        guard let data = try? Data(contentsOf: url),
              let accounts = try? JSONDecoder().decode([ZeehoStoredAccount].self, from: data) else {
            return []
        }
        return accounts.filter { ZeehoToken.isUUID($0.token) }
    }

    static func loadStatus() -> SigninStatus? {
        let url = directory().appendingPathComponent("status.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SigninStatus.self, from: data)
    }

    static func saveStatus(_ status: SigninStatus) {
        let url = directory().appendingPathComponent("status.json")
        guard let data = try? JSONEncoder.zeeho.encode(status) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func loadAccounts() -> [ZeehoStoredAccount] {
        var accounts = storedAccounts()
        let stampURL = directory().appendingPathComponent("token.bundle")
        let applied = (try? String(contentsOf: stampURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if applied != ZeehoLocalToken.stamp {
            var changed = false
            for item in ZeehoLocalToken.accounts.reversed() {
                let token = item.token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard ZeehoToken.isUUID(token), !accounts.contains(where: { $0.token == token }) else { continue }
                accounts.insert(
                    ZeehoStoredAccount(id: UUID().uuidString.lowercased(), label: item.label, token: token),
                    at: 0
                )
                changed = true
            }
            if changed { try? saveAccounts(accounts) }
            try? Data(ZeehoLocalToken.stamp.utf8).write(to: stampURL, options: .atomic)
        }
        return accounts
    }

    private static func storedAccounts() -> [ZeehoStoredAccount] {
        let url = directory().appendingPathComponent("accounts.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ZeehoStoredAccount].self, from: data) {
            return decoded.filter { ZeehoToken.isUUID($0.token) }
        }
        if let token = readStoredToken(), ZeehoToken.isUUID(token) {
            let account = ZeehoStoredAccount(id: UUID().uuidString.lowercased(), label: "", token: token)
            try? saveAccounts([account])
            try? FileManager.default.removeItem(at: directory().appendingPathComponent("token"))
            return [account]
        }
        let marker = directory().appendingPathComponent("token.seeded")
        if FileManager.default.fileExists(atPath: marker.path) { return [] }
        let seeded = ZeehoLocalToken.accounts.compactMap { item -> ZeehoStoredAccount? in
            let token = item.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ZeehoToken.isUUID(token) else { return nil }
            return ZeehoStoredAccount(id: UUID().uuidString.lowercased(), label: item.label, token: token)
        }
        guard !seeded.isEmpty else { return [] }
        try? saveAccounts(seeded)
        return seeded
    }

    static func saveAccounts(_ accounts: [ZeehoStoredAccount]) throws {
        let url = directory().appendingPathComponent("accounts.json")
        let data = try JSONEncoder.zeeho.encode(accounts)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var copy = url
        try? copy.setResourceValues(values)
        FileManager.default.createFile(atPath: directory().appendingPathComponent("token.seeded").path, contents: Data())
    }

    static func loadToken() -> String? {
        loadAccounts().first?.token
    }

    private static func readStoredToken() -> String? {
        let url = directory().appendingPathComponent("token")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func saveToken(_ token: String) throws {
        let url = directory().appendingPathComponent("token")
        try Data(token.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var copy = url
        try? copy.setResourceValues(values)
    }

    static func vehicleImageData(vin: String) -> Data? {
        let url = pictureURL(vin)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func saveVehicleImage(vin: String, data: Data) {
        let url = pictureURL(vin)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func avatarData(id: String) -> Data? {
        let url = avatarURL(id)
        guard let data = try? Data(contentsOf: url), data.count > 32 else { return nil }
        return data
    }

    @discardableResult
    static func ensureAvatars(_ status: SigninStatus) async -> [String: Data] {
        var pairs = status.accountRows.map { ($0.id, $0.avatar) }
        if pairs.isEmpty, let avatar = status.avatar, !avatar.isEmpty {
            pairs = [(status.userId ?? "primary", avatar)]
        }
        var map: [String: Data] = [:]
        for (id, url) in pairs {
            await cacheAvatar(id: id, url: url)
            if let data = avatarData(id: id) {
                map[id] = data
            }
        }
        return map
    }

    static func cacheAvatar(id: String, url: String?) async {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let remote = avatarRemote(url) else { return }
        let file = avatarURL(clean)
        if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(modified) < 12 * 3600,
           (try? Data(contentsOf: file))?.count ?? 0 > 32 {
            return
        }
        var request = URLRequest(url: remote)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count > 32,
              let image = UIImage(data: data) else { return }
        let png = circlePNG(image, side: 128) ?? image.pngData()
        guard let png, png.count > 32 else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func avatarRemote(_ url: String?) -> URL? {
        var raw = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.hasPrefix("//") { raw = "https:" + raw }
        if raw.hasPrefix("http://") { raw = "https://" + raw.dropFirst("http://".count) }
        raw = raw.replacingOccurrences(of: " ", with: "%20")
        guard raw.hasPrefix("https://") else { return nil }
        return URL(string: raw)
    }

    private static func avatarURL(_ id: String) -> URL {
        let name = String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }.prefix(64))
        return directory().appendingPathComponent("pics", isDirectory: true).appendingPathComponent("avatar-\(name)")
    }

    private static func circlePNG(_ image: UIImage, side: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let drawn = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            context.cgContext.addEllipse(in: rect)
            context.cgContext.clip()
            let scale = max(side / image.size.width, side / image.size.height)
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        }
        return drawn.pngData()
    }

    private static func pictureURL(_ vin: String) -> URL {
        let name = vin.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return directory().appendingPathComponent("pics", isDirectory: true).appendingPathComponent(name)
    }

    static func stageCommand(action: String, vin: String, accountId: String, name: String) {
        let command = ZeehoStagedCommand(action: action, vin: vin, accountId: accountId, name: name)
        guard let data = try? JSONEncoder().encode(command) else { return }
        try? data.write(to: directory().appendingPathComponent("pending-command.json"), options: .atomic)
    }

    static func loadWatchPrefs() -> ZeehoWatchPrefs {
        let url = directory().appendingPathComponent("watch-prefs.json")
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(ZeehoWatchPrefs.self, from: data) else {
            return ZeehoWatchPrefs()
        }
        return prefs
    }

    static func saveWatchPrefs(_ prefs: ZeehoWatchPrefs) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        try? data.write(to: directory().appendingPathComponent("watch-prefs.json"), options: .atomic)
    }

    static func loadWatchSlots() -> [String: ZeehoWatchSlot] {
        let url = directory().appendingPathComponent("watch-slots.json")
        guard let data = try? Data(contentsOf: url),
              let slots = try? JSONDecoder().decode([String: ZeehoWatchSlot].self, from: data) else {
            return [:]
        }
        return slots
    }

    static func saveWatchSlots(_ slots: [String: ZeehoWatchSlot]) {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        try? data.write(to: directory().appendingPathComponent("watch-slots.json"), options: .atomic)
    }

    static func loadWatchAt() -> TimeInterval {
        let url = directory().appendingPathComponent("watch-at")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return TimeInterval(text) ?? 0
    }

    static func saveWatchAt(_ time: TimeInterval = Date().timeIntervalSince1970) {
        try? String(time).write(to: directory().appendingPathComponent("watch-at"), atomically: true, encoding: .utf8)
    }

    static let refreshChoices = [15, 30, 60, 120, 240, 360, 720, 1440]

    static func loadRefreshMinutes() -> Int {
        let url = directory().appendingPathComponent("refresh-minutes")
        let raw = Int((try? String(contentsOf: url, encoding: .utf8)) ?? "") ?? 15
        return refreshChoices.contains(raw) ? raw : 15
    }

    static func saveRefreshMinutes(_ minutes: Int) {
        let value = refreshChoices.contains(minutes) ? minutes : 15
        try? String(value).write(to: directory().appendingPathComponent("refresh-minutes"), atomically: true, encoding: .utf8)
    }

    static func refreshLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    static func loadWidgetConfig() -> ZeehoWidgetConfig {
        let url = directory().appendingPathComponent("widget-config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ZeehoWidgetConfig.self, from: data) else {
            return ZeehoWidgetConfig()
        }
        return config
    }

    static func saveWidgetConfig(_ config: ZeehoWidgetConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: directory().appendingPathComponent("widget-config.json"), options: .atomic)
    }

    static func pointsHint(_ status: SigninStatus) -> (title: String, done: Bool)? {
        let prefs = loadPoints()
        guard prefs.enabled else { return nil }
        let today = ZeehoClock.todayString()
        let rows = status.accountRows.filter { $0.tokenInvalid != true }
        let total = max(rows.count, 1)
        let done = rows.filter { prefs.days[$0.id] == today }.count
        return ("积分 \(done)/\(total)", !rows.isEmpty && done == rows.count)
    }

    static func loadPoints() -> ZeehoPointsPrefs {
        let url = directory().appendingPathComponent("points.json")
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(ZeehoPointsPrefs.self, from: data) else {
            return ZeehoPointsPrefs()
        }
        return prefs
    }

    static func savePoints(_ prefs: ZeehoPointsPrefs) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        try? data.write(to: directory().appendingPathComponent("points.json"), options: .atomic)
    }

    static func recentBatteries(limit: Int = 3) -> [ZeehoBatterySample] {
        Array(loadBatteries().suffix(limit).reversed())
    }

    static func recordBatteries(_ vehicles: [VehicleStatus]) {
        let now = Date().timeIntervalSince1970
        var current = loadBatteries()
        for vehicle in vehicles {
            let vin = vehicle.vin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !vin.isEmpty, vehicle.battery != nil else { continue }
            if let last = current.last(where: { $0.vin == vin }),
               now - last.at < 10 * 60,
               last.soc == vehicle.battery,
               last.charge == vehicle.chargeDisplay {
                continue
            }
            current.append(ZeehoBatterySample(
                vin: vin,
                name: vehicle.titleText,
                at: now,
                soc: vehicle.battery,
                voltage: vehicle.voltageText,
                power: vehicle.powerText,
                charge: vehicle.chargeDisplay
            ))
        }
        let trimmed = Array(current.suffix(240))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: directory().appendingPathComponent("battery.json"), options: .atomic)
    }

    private static func loadBatteries() -> [ZeehoBatterySample] {
        let url = directory().appendingPathComponent("battery.json")
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([ZeehoBatterySample].self, from: data) else {
            return []
        }
        return rows
    }

    static func takeStagedCommand() -> ZeehoStagedCommand? {
        let url = directory().appendingPathComponent("pending-command.json")
        guard let data = try? Data(contentsOf: url),
              let command = try? JSONDecoder().decode(ZeehoStagedCommand.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return command
    }

    static func deleteToken() {
        let dir = directory()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("token"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("accounts.json"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("token.seeded").path, contents: Data())
    }
}
