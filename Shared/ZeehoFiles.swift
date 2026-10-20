import Foundation

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
