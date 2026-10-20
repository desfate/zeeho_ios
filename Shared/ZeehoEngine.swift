import Darwin
import Foundation

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
            return cached
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
            return latest
        }
        return await execute(generation: ZeehoGate.currentGeneration)
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
            rows.append(AccountSignin.make(account: account, status: status, previous: previous))
        }
        if Task.isCancelled {
            return cached ?? SigninStatus.aggregate(rows, now: Date())
        }
        let board = SigninStatus.aggregate(rows, now: Date())
        guard ZeehoGate.currentGeneration == generation else {
            return ZeehoFiles.loadStatus() ?? board
        }
        ZeehoFiles.saveStatus(board)
        return board
    }
}
