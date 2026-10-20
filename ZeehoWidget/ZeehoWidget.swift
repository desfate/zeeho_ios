import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct ZeehoWidgetActions: Equatable, Sendable {
    var find = false
    var horn = false
    var seat = true
    var unlock = false
    var lock = false

    var enabled: [VehicleAction] {
        var items: [VehicleAction] = []
        if find { items.append(.find) }
        if horn { items.append(.horn) }
        if seat { items.append(.seat) }
        if unlock { items.append(.unlock) }
        if lock { items.append(.lock) }
        return Array(items.prefix(3))
    }
}

struct ZeehoWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "车辆信息"
    static var description = IntentDescription("选择要显示的车辆数据和功能键。长按小组件，点编辑即可改。功能键会打开 App 再确认，不会在刷新时控车。")

    @Parameter(title: "电量", default: true) var battery: Bool
    @Parameter(title: "续航", default: true) var range: Bool
    @Parameter(title: "里程", default: false) var mileage: Bool
    @Parameter(title: "车锁", default: true) var lock: Bool
    @Parameter(title: "充电", default: false) var charge: Bool
    @Parameter(title: "胎压", default: false) var pressure: Bool
    @Parameter(title: "地址", default: false) var address: Bool
    @Parameter(title: "信号", default: false) var signal: Bool
    @Parameter(title: "电压", default: false) var voltage: Bool
    @Parameter(title: "今日骑行", default: false) var ride: Bool
    @Parameter(title: "寻车", default: true) var findButton: Bool
    @Parameter(title: "鸣笛", default: true) var hornButton: Bool
    @Parameter(title: "开坐垫", default: true) var seatButton: Bool
    @Parameter(title: "开锁", default: false) var unlockButton: Bool
    @Parameter(title: "关锁", default: false) var lockButton: Bool

    var fields: ZeehoWidgetFields {
        ZeehoWidgetFields(
            battery: battery,
            range: range,
            mileage: mileage,
            lock: lock,
            charge: charge,
            pressure: pressure,
            address: address,
            signal: signal,
            voltage: voltage,
            ride: ride
        )
    }

    var actions: ZeehoWidgetActions {
        ZeehoWidgetActions(
            find: findButton,
            horn: hornButton,
            seat: seatButton,
            unlock: unlockButton,
            lock: lockButton
        )
    }
}

struct ZeehoEntry: TimelineEntry {
    var date: Date
    var status: SigninStatus
    var fields: ZeehoWidgetFields = ZeehoWidgetFields()
    var actions: ZeehoWidgetActions = ZeehoWidgetActions()
}

struct ZeehoProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ZeehoEntry {
        ZeehoEntry(date: Date(), status: .sample)
    }

    func snapshot(for configuration: ZeehoWidgetIntent, in context: Context) async -> ZeehoEntry {
        ZeehoEntry(date: Date(), status: ZeehoFiles.loadStatus() ?? .missingToken(), fields: configuration.fields, actions: configuration.actions)
    }

    func timeline(for configuration: ZeehoWidgetIntent, in context: Context) async -> Timeline<ZeehoEntry> {
        let status = await ZeehoEngine.refresh(ignoreGate: false)
        return Self.timeline(status: status, fields: configuration.fields, actions: configuration.actions, now: Date())
    }

    static func timeline(status: SigninStatus, fields: ZeehoWidgetFields, actions: ZeehoWidgetActions = ZeehoWidgetActions(), now: Date) -> Timeline<ZeehoEntry> {
        var entries = [ZeehoEntry(date: now, status: status, fields: fields, actions: actions)]
        if status.signedToday == true,
           status.today == ZeehoClock.todayString(now),
           let midnight = ZeehoClock.nextMidnight(after: now) {
            entries.append(ZeehoEntry(date: midnight, status: status.markedUnsigned(at: midnight), fields: fields, actions: actions))
        }
        return Timeline(entries: entries, policy: .after(ZeehoScheduler.nextRefresh(after: now, status: status)))
    }
}

struct ZeehoSignInWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.jieyu.zeeho.signin.widget", intent: ZeehoWidgetIntent.self, provider: ZeehoProvider()) { entry in
            ZeehoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("极核签到")
        .description("显示签到和你勾选的车辆信息。长按小组件可以改显示项。还没签到时，刷新会自动打卡。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
        ])
        .contentMarginsDisabled()
    }
}

@main
struct ZeehoWidgetBundle: WidgetBundle {
    var body: some Widget {
        ZeehoSignInWidget()
    }
}

struct ZeehoWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: ZeehoEntry

    var body: some View {
        switch family {
        case .systemSmall:
            small.padding(14).containerBackground(ZeehoTheme.surface, for: .widget)
        case .systemMedium:
            medium.padding(14).containerBackground(ZeehoTheme.surface, for: .widget)
        case .systemLarge:
            large.padding(16).containerBackground(ZeehoTheme.surface, for: .widget)
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        default:
            Text("\(entry.status.chipText) \(entry.status.pointsText)分")
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(showsAction: false)
            Spacer(minLength: 0)
            if entry.status.accountRows.count > 1 {
                accountBlock(limit: 3, showsContinue: false, preferColumns: false)
                vehicleBlock(factLimit: 3, tiled: false)
            } else {
                Text(entry.status.pointsText)
                    .font(.system(size: 32, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(ZeehoTheme.onPrimaryContainer)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .widgetAccentable()
                Text(entry.status.pointsCaption)
                    .font(ZeehoFont.labelSmall)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                Text(entry.status.displayTitle)
                    .font(ZeehoFont.labelLarge)
                    .foregroundStyle(ZeehoTheme.onSurface)
                    .lineLimit(1)
                HStack(spacing: 6) {
                Text("连签 \(entry.status.continueText)")
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let time = signedAt(entry.status.lastTime) {
                    Text(time)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .font(ZeehoFont.bodySmall)
            .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            if let vehicle = factVehicles.first {
                ridePlace(vehicle)
            }
                factsView(limit: 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(showsAction: true)
            if entry.status.accountRows.count > 1 {
                accountBlock(limit: 3, showsContinue: true, preferColumns: true)
                vehicleBlock(factLimit: 3, tiled: true, roomy: false)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.status.pointsText)
                        .font(.system(size: 34, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(ZeehoTheme.onPrimaryContainer)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .widgetAccentable()
                    Text(entry.status.displayTitle)
                        .font(ZeehoFont.title)
                        .foregroundStyle(ZeehoTheme.onSurface)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    mini("连签", entry.status.continueText)
                    mini("上次", entry.status.lastTimeText)
                }
                if let vehicle = factVehicles.first {
                    vehiclePanel(vehicle, factLimit: 3, roomy: false)
                }
            }
            if let problem = entry.status.problemText {
                Text(problem)
                    .font(ZeehoFont.labelSmall)
                    .foregroundStyle(ZeehoTheme.onErrorContainer)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(showsAction: true)
            Text(entry.status.displayTitle)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ZeehoTheme.onSurface)
                .lineLimit(1)
            if entry.status.accountRows.count > 1 {
                accountBlock(limit: 4, showsContinue: true, preferColumns: true)
                vehicleBlock(factLimit: 6, tiled: true, roomy: true)
            } else {
                if let name = entry.status.nickName, !name.isEmpty {
                    Text(name)
                        .font(ZeehoFont.body)
                        .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
                Text(entry.status.pointsText)
                    .font(ZeehoFont.display)
                    .monospacedDigit()
                    .foregroundStyle(ZeehoTheme.onPrimaryContainer)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .widgetAccentable()
                Text(entry.status.pointsCaption)
                    .font(ZeehoFont.label)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                HStack(spacing: 8) {
                    mini("连签", entry.status.continueText)
                    mini("上次", entry.status.lastTimeText)
                }
                if let vehicle = factVehicles.first {
                    vehiclePanel(vehicle, factLimit: 3, roomy: true)
                }
            }
            if let problem = entry.status.problemText {
                Text(problem)
                    .font(ZeehoFont.bodySmall)
                    .foregroundStyle(ZeehoTheme.onErrorContainer)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var circular: some View {
        VStack(spacing: 2) {
            Text(entry.status.accountRows.count > 1 ? entry.status.chipText : entry.status.pointsText)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .widgetAccentable()
            Image(systemName: entry.status.signedToday == true ? "checkmark" : "circle")
                .font(.system(size: 11, weight: .bold))
            if let date = updatedDate {
                Text(date, style: .time)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(freshnessColor(date))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.status.displayTitle)
                .font(.headline)
                .widgetAccentable()
                .lineLimit(1)
            if entry.status.accountRows.count > 1 {
                Text(entry.status.accountRows.prefix(3).map { "\(accountTitle($0, among: entry.status.accountRows)) \($0.chip)" }.joined(separator: "  "))
                    .font(.caption)
                    .lineLimit(2)
            } else {
                Text("\(entry.status.pointsText) 分 · 连签 \(entry.status.continueText)")
                    .font(.caption)
            }
            freshness
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(showsAction: Bool) -> some View {
        HStack(spacing: 6) {
            freshness
            Spacer(minLength: 4)
            chip
            if showsAction {
                action
            }
        }
    }

    private var updatedDate: Date? {
        guard let unix = entry.status.updatedAtUnix, unix > 0 else { return nil }
        return Date(timeIntervalSince1970: unix)
    }

    private func freshnessColor(_ date: Date) -> Color {
        let age = Date().timeIntervalSince(date)
        if age < 20 * 60 { return ZeehoTheme.primary }
        if age < 3 * 3600 { return ZeehoTheme.onTertiaryContainer }
        return ZeehoTheme.onErrorContainer
    }

    private var freshness: some View {
        Group {
            if let date = updatedDate {
                HStack(spacing: 4) {
                    Circle()
                        .fill(freshnessColor(date))
                        .frame(width: 6, height: 6)
                    Text(date, style: .relative)
                    Text(date, style: .time)
                        .monospacedDigit()
                }
                .font(ZeehoFont.labelSmall)
                .foregroundStyle(freshnessColor(date))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            } else {
                Text("尚未更新")
                    .font(ZeehoFont.labelSmall)
                    .foregroundStyle(ZeehoTheme.onErrorContainer)
                    .lineLimit(1)
            }
        }
    }

    private var chip: some View {
        Text(entry.status.chipText)
            .font(ZeehoFont.labelSmall)
            .foregroundStyle(chipInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(chipFill, in: Capsule())
    }

    private var chipFill: Color {
        if entry.status.tokenInvalid == true || entry.status.hasToken == false {
            return ZeehoTheme.errorContainer
        }
        if entry.status.signedToday == true { return ZeehoTheme.primaryContainer }
        return ZeehoTheme.tertiaryContainer
    }

    private var chipInk: Color {
        if entry.status.tokenInvalid == true || entry.status.hasToken == false {
            return ZeehoTheme.onErrorContainer
        }
        if entry.status.signedToday == true { return ZeehoTheme.onPrimaryContainer }
        return ZeehoTheme.onTertiaryContainer
    }

    @ViewBuilder
    private var action: some View {
        if entry.status.hasToken != false && entry.status.tokenInvalid != true {
            Button(intent: ZeehoSignInIntent()) {
                Text(entry.status.signedToday == true ? "刷新" : "签到")
                    .font(ZeehoFont.label)
                    .foregroundStyle(ZeehoTheme.onPrimaryContainer)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ZeehoTheme.primaryContainer, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var factVehicles: [VehicleStatus] {
        let rows = entry.status.accountRows.flatMap(\.shownVehicles)
        let source: [VehicleStatus]
        if !rows.isEmpty {
            source = rows
        } else if let vehicle = entry.status.vehicle {
            source = [vehicle]
        } else {
            source = []
        }
        var unique: [VehicleStatus] = []
        for vehicle in source {
            if let index = unique.firstIndex(where: { sameVehicle($0, vehicle) }) {
                unique[index] = fill(unique[index], with: vehicle)
            } else {
                unique.append(vehicle)
            }
        }
        return unique
    }

    private func sameVehicle(_ lhs: VehicleStatus, _ rhs: VehicleStatus) -> Bool {
        let leftVin = normalized(lhs.vin)
        let rightVin = normalized(rhs.vin)
        if !leftVin.isEmpty, !rightVin.isEmpty { return leftVin == rightVin }
        let leftName = lhs.titleText
        let rightName = rhs.titleText
        return leftName != "车辆" && leftName == rightName
    }

    private func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func fill(_ base: VehicleStatus, with extra: VehicleStatus) -> VehicleStatus {
        var vehicle = base
        if normalized(vehicle.vehicleName).isEmpty { vehicle.vehicleName = extra.vehicleName }
        if vehicle.battery == nil { vehicle.battery = extra.battery }
        if vehicle.rangeKm == nil { vehicle.rangeKm = extra.rangeKm }
        if vehicle.mileageKm == nil { vehicle.mileageKm = extra.mileageKm }
        if normalized(vehicle.lockText).isEmpty { vehicle.lockText = extra.lockText }
        if normalized(vehicle.chargeText).isEmpty || vehicle.chargeText == "未知" { vehicle.chargeText = extra.chargeText }
        if normalized(vehicle.signal).isEmpty { vehicle.signal = extra.signal }
        if normalized(vehicle.address).isEmpty { vehicle.address = extra.address }
        if normalized(vehicle.pressureText).isEmpty { vehicle.pressureText = extra.pressureText }
        if normalized(vehicle.voltageText).isEmpty { vehicle.voltageText = extra.voltageText }
        if normalized(vehicle.todayRideText).isEmpty { vehicle.todayRideText = extra.todayRideText }
        if normalized(vehicle.lastRideText).isEmpty { vehicle.lastRideText = extra.lastRideText }
        if normalized(vehicle.vin).isEmpty { vehicle.vin = extra.vin }
        return vehicle
    }

    private func factsView(limit: Int) -> some View {
        let lines = factVehicles.flatMap { vehicle -> [(String, String)] in
            let rows = entry.fields.lines(for: vehicle).filter { $0.0 != "今日骑行" && $0.0 != "地址" && $0.0 != "充电" }
            if factVehicles.count > 1, !rows.isEmpty {
                return [(vehicle.titleText, rows.map(\.1).joined(separator: " · "))]
            }
            return rows
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Text(line.0)
                        .font(ZeehoFont.labelSmall)
                        .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                        .lineLimit(1)
                    Text(line.1)
                        .font(ZeehoFont.labelLarge)
                        .foregroundStyle(ZeehoTheme.onSurface)
                        .lineLimit(2)
                        .minimumScaleFactor(0.65)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func accountBlock(limit: Int, showsContinue: Bool, preferColumns: Bool) -> some View {
        let rows = Array(entry.status.accountRows.prefix(limit))
        if preferColumns, rows.count == 2 {
            HStack(alignment: .top, spacing: 8) {
                ForEach(rows) { row in
                    accountTile(row, showsContinue: showsContinue)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    accountLine(row, showsContinue: showsContinue)
                }
            }
        }
    }

    private func accountLine(_ row: AccountSignin, showsContinue: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                statusChip(row)
                Text(accountTitle(row, among: entry.status.accountRows))
                    .font(ZeehoFont.labelLarge)
                    .foregroundStyle(ZeehoTheme.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if showsContinue {
                    Text(row.continueText)
                        .font(ZeehoFont.labelSmall)
                        .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(row.pointsText)
                    .font(ZeehoFont.labelLarge)
                    .monospacedDigit()
                    .foregroundStyle(ZeehoTheme.onPrimaryContainer)
                    .lineLimit(1)
            }
            if let time = signedAt(row.lastTime) {
                Text(time)
                    .font(ZeehoFont.labelSmall)
                    .monospacedDigit()
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func accountTile(_ row: AccountSignin, showsContinue: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(accountTitle(row, among: entry.status.accountRows))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ZeehoTheme.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                statusChip(row)
            }
            Text(row.pointsText)
                .font(.system(size: 18, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(ZeehoTheme.onPrimaryContainer)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if showsContinue || signedAt(row.lastTime) != nil {
                HStack(spacing: 4) {
                    if showsContinue {
                        Text("连签 \(row.continueText)")
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let time = signedAt(row.lastTime) {
                        Text(time)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .font(ZeehoFont.labelSmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZeehoTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func signedAt(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count >= 2 else { return text }
        let time = String(parts[1].prefix(5))
        let day = String(parts[0])
        if day == ZeehoClock.todayString() { return time }
        return "\(day.suffix(5)) \(time)"
    }

    private func statusChip(_ row: AccountSignin) -> some View {
        let ink: Color
        let fill: Color
        if row.tokenInvalid == true {
            ink = ZeehoTheme.onErrorContainer
            fill = ZeehoTheme.errorContainer
        } else if row.signedToday == true {
            ink = ZeehoTheme.onPrimaryContainer
            fill = ZeehoTheme.primaryContainer
        } else {
            ink = ZeehoTheme.onTertiaryContainer
            fill = ZeehoTheme.tertiaryContainer
        }
        return Text(row.chip)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill, in: Capsule())
    }

    @ViewBuilder
    private func vehicleBlock(factLimit: Int, tiled: Bool, roomy: Bool = false) -> some View {
        let vehicles = factVehicles
        if vehicles.isEmpty {
            EmptyView()
        } else if tiled, vehicles.count == 1 {
            vehiclePanel(vehicles[0], factLimit: factLimit, roomy: roomy)
        } else if tiled {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(vehicles.enumerated()), id: \.offset) { _, vehicle in
                    vehiclePanel(vehicle, factLimit: max(3, factLimit / vehicles.count), roomy: roomy)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(vehicles.enumerated()), id: \.offset) { _, vehicle in
                    ridePlace(vehicle)
                }
            }
        }
    }

    private func vehiclePanel(_ vehicle: VehicleStatus, factLimit: Int, roomy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            vehicleHead(vehicle, roomy: roomy)
            todayLine(vehicle)
            placeLine(vehicle)
            let extra = Array(metricLines(for: vehicle).prefix(min(3, factLimit)))
            if !extra.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(extra.enumerated()), id: \.offset) { _, line in
                        mini(line.0, line.1)
                    }
                }
            }
            controlRow(vehicle, roomy: roomy)
        }
    }

    private func metricLines(for vehicle: VehicleStatus) -> [(String, String)] {
        entry.fields.lines(for: vehicle).filter { line in
            line.0 != "今日骑行" && line.0 != "地址" && line.0 != "充电" && line.0 != "电量" && line.0 != "续航" && line.0 != "车锁"
        }
    }

    private func vehicleHead(_ vehicle: VehicleStatus, roomy: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            vehiclePhoto(vehicle, side: roomy ? 40 : 32)
            Text(vehicle.titleText)
                .font(.system(size: roomy ? 15 : 13, weight: .medium))
                .foregroundStyle(ZeehoTheme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            lockMark(vehicle)
            chargeChip(vehicle)
            Spacer(minLength: 4)
            if entry.fields.battery {
                headStat(vehicle.batteryText, "电量")
            }
            if entry.fields.range {
                headStat(vehicle.rangeText, "续航")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZeehoTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func headStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ZeehoTheme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                .lineLimit(1)
        }
    }

    private func lockMark(_ vehicle: VehicleStatus) -> some View {
        let text = vehicle.lockText ?? "未知"
        let symbol = text == "已锁" ? "lock.fill" : (text == "未锁" ? "lock.open.fill" : "lock")
        let color = text == "未锁" ? ZeehoTheme.onTertiaryContainer : ZeehoTheme.onSurfaceVariant
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel(text == "未知" ? "车锁未知" : text)
    }

    private func vehiclePhoto(_ vehicle: VehicleStatus, side: CGFloat) -> some View {
        Group {
            if let vin = vehicle.vin, let data = ZeehoFiles.vehicleImageData(vin: vin), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "scooter")
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            }
        }
        .frame(width: side, height: side)
        .padding(4)
        .background(ZeehoTheme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func ridePlace(_ vehicle: VehicleStatus, roomy: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            todayLine(vehicle)
            placeLine(vehicle)
        }
    }

    private func todayLine(_ vehicle: VehicleStatus) -> some View {
        compactLine("今日", vehicle.todayRideText ?? "0 km · 0 分钟")
    }

    private func placeLine(_ vehicle: VehicleStatus) -> some View {
        let place = vehicle.address?.isEmpty == false ? vehicle.address! : "暂无位置"
        return compactLine("位置", place)
    }

    private func compactLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ZeehoTheme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZeehoTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func chargeChip(_ vehicle: VehicleStatus) -> some View {
        let text = vehicle.chargeDisplay
        let ink: Color
        let fill: Color
        if text == "充电中" {
            ink = ZeehoTheme.onChargeContainer
            fill = ZeehoTheme.chargeContainer
        } else if text == "充电完成" {
            ink = ZeehoTheme.onPrimaryContainer
            fill = ZeehoTheme.primaryContainer
        } else if text == "未充电" {
            ink = ZeehoTheme.onSurfaceVariant
            fill = ZeehoTheme.surfaceContainerHighest
        } else {
            ink = ZeehoTheme.onTertiaryContainer
            fill = ZeehoTheme.tertiaryContainer
        }
        return Text(text == "未知" ? "充电未知" : text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill, in: Capsule())
    }

    @ViewBuilder
    private func controlRow(_ vehicle: VehicleStatus, roomy: Bool) -> some View {
        let actions = entry.actions.enabled
        if !actions.isEmpty, let vin = vehicle.vin, !vin.isEmpty, let accountId = vehicle.accountId, !accountId.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(actions.prefix(3))) { action in
                    Button(intent: ZeehoStageControlIntent(action: action, vin: vin, accountId: accountId, name: vehicle.titleText)) {
                        Text(action.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(ZeehoTheme.secondaryContainer, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(ZeehoTheme.onSecondaryContainer)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func accountTitle(_ row: AccountSignin, among rows: [AccountSignin]) -> String {
        let name = row.displayName
        let same = rows.filter { $0.displayName == name }
        guard same.count > 1, let index = rows.firstIndex(where: { $0.id == row.id }) else { return name }
        let vehicle = row.shownVehicles.first?.titleText
        if let vehicle, vehicle != "车辆", vehicle != name {
            return "\(name) · \(vehicle)"
        }
        return "\(name) \(index + 1)"
    }

    private func mini(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(ZeehoFont.labelSmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ZeehoTheme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(ZeehoTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
