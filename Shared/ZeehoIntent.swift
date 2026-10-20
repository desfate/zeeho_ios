import AppIntents
import WidgetKit

struct ZeehoStageControlIntent: AppIntent {
    static var title: LocalizedStringResource = "准备车辆操作"
    static var description = IntentDescription("打开 App，确认后再操作车辆。")
    static var openAppWhenRun = true
    static var isDiscoverable: Bool = false

    @Parameter(title: "操作") var action: String
    @Parameter(title: "车架号") var vin: String
    @Parameter(title: "账号") var accountId: String
    @Parameter(title: "名称") var vehicleName: String

    init() {}

    init(action: VehicleAction, vin: String, accountId: String, name: String) {
        self.action = action.rawValue
        self.vin = vin
        self.accountId = accountId
        self.vehicleName = name
    }

    func perform() async throws -> some IntentResult {
        guard VehicleAction(rawValue: action) != nil, !vin.isEmpty, !accountId.isEmpty else {
            return .result()
        }
        ZeehoFiles.stageCommand(action: action, vin: vin, accountId: accountId, name: vehicleName)
        return .result()
    }
}

struct ZeehoSignInIntent: AppIntent {
    static var title: LocalizedStringResource = "极核签到"
    static var description = IntentDescription("还没签到就为极核账号签到，并刷新小组件。")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = await ZeehoEngine.refresh(ignoreGate: true)
        WidgetCenter.shared.reloadAllTimelines()
        let text = status.message ?? status.displayTitle
        return .result(dialog: "\(text)")
    }
}
