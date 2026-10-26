import SwiftUI
import WidgetKit

struct PendingCommand: Identifiable, Equatable {
    var action: VehicleAction
    var vin: String
    var accountId: String
    var name: String
    var chargeValue: String?
    var id: String { "\(action.rawValue)-\(vin)-\(chargeValue ?? "")" }
}

@MainActor
@Observable
final class ZeehoModel {
    var status: SigninStatus = .missingToken()
    var refreshing = false
    var tokenDraft = ""
    var editingToken = false
    var notice = ""
    var banner = ""
    var acceptedDisclaimer = false
    var secretDraft = ZeehoSecrets.builtIn
    var allowsNetwork = true
    var pendingCommand: PendingCommand?
    var chargeChoices: [String: [String]] = [:]
    var controlling = false
    var watch = ZeehoWatchPrefs()
    var refreshMinutes = 15
    var notificationsAllowed = true
    var widgetConfig = ZeehoWidgetConfig()
    var points = ZeehoPointsPrefs()
    var pointsNote = ""
    var skin = ZeehoSkin()

    static let disclaimerKey = "zeeho.disclaimer.accepted"

    init(preview: Bool = false) {
        if preview {
            status = .sample
            acceptedDisclaimer = true
            secretDraft = .builtIn
            allowsNetwork = false
            return
        }
        status = ZeehoFiles.loadStatus() ?? .missingToken()
        watch = ZeehoFiles.loadWatchPrefs()
        refreshMinutes = ZeehoFiles.loadRefreshMinutes()
        widgetConfig = ZeehoFiles.loadWidgetConfig()
        points = ZeehoFiles.loadPoints()
        skin = ZeehoSkinStore.current()
        acceptedDisclaimer = UserDefaults.standard.bool(forKey: Self.disclaimerKey)
        secretDraft = ZeehoConfig.current()
        allowsNetwork = true
        if ZeehoFiles.loadAccounts().isEmpty && (status.hasToken == false || status.tokenInvalid == true) {
            editingToken = true
        }
    }

    func acceptDisclaimer() {
        acceptedDisclaimer = true
        UserDefaults.standard.set(true, forKey: Self.disclaimerKey)
    }

    func onForeground() async {
        consumeStagedCommand()
        await prepareWatch()
        guard allowsNetwork, !refreshing else { return }
        let cached = ZeehoFiles.loadStatus() ?? .missingToken()
        status = cached
        if cached.hasToken == false || cached.tokenInvalid == true {
            editingToken = true
        }
        let fresh = cached.signedToday == true
            && cached.today == ZeehoClock.todayString()
            && (cached.updatedAtUnix).map { Date().timeIntervalSince1970 - $0 < 10 * 60 } == true
        if fresh {
            let filled = await ZeehoEngine.refillVoltageIfNeeded(cached)
            status = filled
            await ZeehoFiles.ensureAvatars(filled)
            WidgetCenter.shared.reloadAllTimelines()
            ZeehoBackground.schedule(status: filled, replace: false)
            return
        }
        await refresh(ignoreGate: true)
    }

    func consumeStagedCommand() {
        guard pendingCommand == nil, let staged = ZeehoFiles.takeStagedCommand(),
              let action = VehicleAction(rawValue: staged.action) else { return }
        pendingCommand = PendingCommand(action: action, vin: staged.vin, accountId: staged.accountId, name: staged.name)
    }

    func refresh(ignoreGate: Bool) async {
        guard allowsNetwork, !refreshing else { return }
        refreshing = true
        notice = ""
        banner = ""
        defer { refreshing = false }
        let status = await ZeehoEngine.refresh(ignoreGate: ignoreGate)
        apply(status)
        WidgetCenter.shared.reloadAllTimelines()
        ZeehoBackground.schedule(status: status, replace: true)
    }

    func saveToken() async {
        guard allowsNetwork else { return }
        guard !refreshing else {
            banner = "正在处理上一个请求"
            return
        }
        refreshing = true
        notice = ""
        banner = ""
        defer { refreshing = false }
        do {
            let status = try await ZeehoEngine.addAccount(tokenDraft)
            tokenDraft = ""
            if status.tokenInvalid != true && status.hasToken != false {
                editingToken = false
            }
            apply(status)
            if status.ok == true && status.posted != true && status.tokenInvalid != true {
                notice = "Token 已保存"
            }
            WidgetCenter.shared.reloadAllTimelines()
            ZeehoBackground.schedule(status: status, replace: true)
        } catch {
            banner = error.localizedDescription
        }
    }

    func removeAccount(id: String) {
        let status = ZeehoEngine.removeAccount(id: id)
        tokenDraft = ""
        notice = ""
        banner = ""
        apply(status)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func ask(_ action: VehicleAction, vehicle: VehicleStatus, chargeValue: String? = nil) {
        guard let vin = vehicle.vin, !vin.isEmpty, let accountId = vehicle.accountId, !accountId.isEmpty else {
            banner = "还没有读到这辆车的车架号，先下拉刷新"
            return
        }
        pendingCommand = PendingCommand(action: action, vin: vin, accountId: accountId, name: vehicle.titleText, chargeValue: chargeValue)
    }

    func runPendingCommand() async {
        guard allowsNetwork, let command = pendingCommand else { return }
        pendingCommand = nil
        controlling = true
        notice = ""
        banner = ""
        defer { controlling = false }
        let message = await ZeehoEngine.command(command.action, accountId: command.accountId, vin: command.vin, chargeValue: command.chargeValue)
        await refresh(ignoreGate: true)
        notice = message
    }

    func applySkin(_ next: ZeehoSkin) {
        var stored = next
        if stored.useImage, ZeehoSkinStore.imageData() == nil {
            stored.useImage = false
        }
        skin = stored
        ZeehoSkinStore.save(stored)
        skin = ZeehoSkinStore.current()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func saveSkinImage(_ image: UIImage) {
        ZeehoSkinStore.saveImage(image)
        skin = ZeehoSkinStore.current()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func clearSkinImage() {
        ZeehoSkinStore.clearImage()
        skin = ZeehoSkinStore.current()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func setRefreshMinutes(_ minutes: Int) {
        refreshMinutes = minutes
        ZeehoFiles.saveRefreshMinutes(minutes)
        WidgetCenter.shared.reloadAllTimelines()
        ZeehoBackground.schedule(status: status, replace: true)
    }

    func saveWidget(_ next: ZeehoWidgetConfig) {
        widgetConfig = next
        ZeehoFiles.saveWidgetConfig(next)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func savePoints(_ next: ZeehoPointsPrefs) {
        var stored = next
        if stored.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stored.content = ""
        }
        points = stored
        ZeehoFiles.savePoints(stored)
    }

    func runPointsNow() async {
        guard allowsNetwork, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        pointsNote = await ZeehoEngine.runPoints()
        points = ZeehoFiles.loadPoints()
    }

    func prepareWatch() async {
        let on = watch.charge || watch.messages || watch.low || watch.offline || watch.tire
        guard on else { return }
        let allowed = await ZeehoWatch.requestAccess()
        notificationsAllowed = allowed
        if !allowed {
            banner = "系统没有允许通知，车况提醒发不出去。"
        }
    }

    func setWatch(_ next: ZeehoWatchPrefs) {
        watch = next
        ZeehoFiles.saveWatchPrefs(next)
        let on = next.charge || next.messages || next.low || next.offline || next.tire
        guard on else { return }
        Task {
            let allowed = await ZeehoWatch.requestAccess()
            notificationsAllowed = allowed
            if !allowed {
                banner = "系统没有允许通知，车况提醒发不出去。"
            }
        }
    }

    func loadChargeChoices(vehicle: VehicleStatus) async {
        guard allowsNetwork, let vin = vehicle.vin, let accountId = vehicle.accountId else { return }
        if chargeChoices[vin]?.isEmpty == false { return }
        let options = await ZeehoEngine.chargeOptions(accountId: accountId, vin: vin)
        if !options.isEmpty { chargeChoices[vin] = options }
    }

    func clearToken() {
        ZeehoEngine.clearToken()
        tokenDraft = ""
        editingToken = true
        notice = ""
        banner = ""
        status = ZeehoFiles.loadStatus() ?? .missingToken()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func saveSecrets() {
        ZeehoConfig.save(secretDraft)
        secretDraft = ZeehoConfig.current()
        notice = "密钥已保存，下次签到生效"
        banner = ""
    }

    func resetSecrets() {
        secretDraft = .builtIn
        ZeehoConfig.save(.builtIn)
        notice = "已恢复默认密钥"
        banner = ""
    }

    private func apply(_ status: SigninStatus) {
        self.status = status
        if status.tokenInvalid == true || status.hasToken == false {
            editingToken = true
        } else if tokenDraft.isEmpty {
            editingToken = false
        }
        if status.ok == false {
            notice = ""
            banner = status.problemText ?? ""
        } else if status.posted == true {
            banner = ""
            notice = status.message ?? "签到成功"
        } else {
            banner = ""
            notice = ""
        }
    }
}
