import SwiftUI
import PhotosUI
import UIKit

struct ContentView: View {
    @Environment(ZeehoModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        let _ = model.skin
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    identity
                    hero
                    if model.status.accountRows.isEmpty {
                        HStack(spacing: 8) {
                            metric("连签", model.status.continueText)
                            metric("上次", model.status.lastTimeText)
                        }
                    } else {
                        accountSection
                    }
                    if model.status.hasToken == true {
                        vehicleBoard
                        pointsSection
                        watchSection
                    }
                    if !model.notice.isEmpty {
                        banner(model.notice, fill: ZeehoTheme.primaryContainer, ink: ZeehoTheme.onPrimaryContainer)
                    }
                    if !model.banner.isEmpty {
                        banner(model.banner, fill: ZeehoTheme.errorContainer, ink: ZeehoTheme.onErrorContainer)
                    }
                    if model.editingToken || model.status.tokenInvalid == true || model.status.hasToken == false {
                        tokenEditor
                    }
                    appearanceSection
                    autoSection
                    captureSection
                    secretsSection
                    footer
                }
                .padding(20)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ZeehoTheme.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("极核签到")
                        .font(ZeehoFont.labelLarge)
                        .foregroundStyle(ZeehoTheme.onSurface)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refresh(ignoreGate: true) }
                    } label: {
                        if model.refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(model.refreshing)
                }
            }
            .toolbarBackground(ZeehoTheme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .tint(ZeehoTheme.primary)
        .preferredColorScheme(.dark)
        .refreshable {
            await model.refresh(ignoreGate: true)
        }
        .task {
            await model.onForeground()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.onForeground() }
        }
        .confirmationDialog(
            pendingTitle,
            isPresented: Binding(
                get: { model.pendingCommand != nil },
                set: { if !$0 { model.pendingCommand = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(model.pendingCommand?.action.title ?? "确认", role: destructiveCommand ? .destructive : nil) {
                Task { await model.runPendingCommand() }
            }
            Button("取消", role: .cancel) { model.pendingCommand = nil }
        } message: {
            Text(pendingMessage)
        }
        .sheet(isPresented: Binding(
            get: { !model.acceptedDisclaimer },
            set: { _ in }
        )) {
            DisclaimerView(accept: model.acceptDisclaimer)
                .interactiveDismissDisabled()
        }
        .sensoryFeedback(.success, trigger: model.notice) { old, new in
            !new.isEmpty && old != new
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("ZeehoMark")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("ZEEHO")
                .font(ZeehoFont.labelSmall)
                .tracking(1.6)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            Spacer()
            Text(model.status.chipText)
                .font(ZeehoFont.label)
                .foregroundStyle(chipInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(chipFill, in: Capsule())
        }
    }

    private var chipFill: Color {
        if model.status.tokenInvalid == true || model.status.hasToken == false {
            return ZeehoTheme.errorContainer
        }
        if model.status.signedToday == true { return ZeehoTheme.primaryContainer }
        return ZeehoTheme.tertiaryContainer
    }

    private var chipInk: Color {
        if model.status.tokenInvalid == true || model.status.hasToken == false {
            return ZeehoTheme.onErrorContainer
        }
        if model.status.signedToday == true { return ZeehoTheme.onPrimaryContainer }
        return ZeehoTheme.onTertiaryContainer
    }

    private var identity: some View {
        let rows = model.status.accountRows
        return HStack(spacing: 12) {
            avatarStack(rows)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status.displayTitle)
                    .font(ZeehoFont.headline)
                    .foregroundStyle(ZeehoTheme.onSurface)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if model.status.accountRows.count <= 1, let name = model.status.nickName, !name.isEmpty {
                    Text(name)
                        .font(ZeehoFont.body)
                        .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func avatarStack(_ rows: [AccountSignin]) -> some View {
        let shown = Array(rows.prefix(4))
        return Group {
            if shown.isEmpty {
                AccountAvatar(id: nil, url: model.status.avatar, side: 52)
            } else {
                ZStack(alignment: .leading) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                        AccountAvatar(id: row.id, url: row.avatar, side: 52)
                            .overlay(Circle().stroke(ZeehoTheme.surface, lineWidth: 2))
                            .offset(x: CGFloat(index) * 18)
                    }
                }
                .frame(width: 52 + 18 * CGFloat(shown.count - 1), height: 52, alignment: .leading)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.status.pointsCaption)
                .font(ZeehoFont.label)
                .foregroundStyle(ZeehoTheme.onPrimaryContainer.opacity(0.82))
            Text(model.status.pointsText)
                .font(ZeehoFont.display)
                .monospacedDigit()
                .foregroundStyle(ZeehoTheme.onPrimaryContainer)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(ZeehoTheme.primaryContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func metric(_ label: String, _ value: String, lines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(ZeehoFont.label)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                .lineLimit(1)
            Text(value)
                .font(lines > 1 ? ZeehoFont.body : ZeehoFont.title)
                .monospacedDigit()
                .foregroundStyle(ZeehoTheme.onSurface)
                .lineLimit(lines)
                .minimumScaleFactor(lines > 1 ? 0.8 : 0.55)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ZeehoTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var pendingTitle: String {
        guard let command = model.pendingCommand else { return "确认操作" }
        return "\(command.action.title) · \(command.name)"
    }

    private var pendingMessage: String {
        guard let command = model.pendingCommand else { return "" }
        let extra = command.chargeValue.map { "档位 \($0)。" } ?? ""
        return extra + command.action.confirmText + "请确认人在车旁边。"
    }

    private var destructiveCommand: Bool {
        switch model.pendingCommand?.action {
        case .unlock, .lock, .seat: return true
        default: return false
        }
    }

    private var boardVehicles: [VehicleStatus] {
        VehicleRoster.all(model.status)
    }

    private var vehicleBoard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("车辆")
                .font(ZeehoFont.title)
                .foregroundStyle(ZeehoTheme.onSurface)
            if boardVehicles.isEmpty {
                Text("下拉刷新后会显示电量、续航、车锁、胎压和骑行。读到车架号后，下面的按钮才能控车。")
                    .font(ZeehoFont.bodySmall)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                controlButtons(VehicleStatus())
            } else {
                ForEach(Array(boardVehicles.enumerated()), id: \.offset) { _, item in
                    vehicleCard(item, showAccount: boardVehicles.count > 1)
                }
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账号")
                .font(ZeehoFont.title)
                .foregroundStyle(ZeehoTheme.onSurface)
            ForEach(model.status.accountRows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        AccountAvatar(id: row.id, url: row.avatar, side: 36)
                        Text(row.chip)
                            .font(ZeehoFont.label)
                            .foregroundStyle(row.signedToday == true ? ZeehoTheme.onPrimaryContainer : ZeehoTheme.onTertiaryContainer)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                row.signedToday == true ? ZeehoTheme.primaryContainer : ZeehoTheme.tertiaryContainer,
                                in: Capsule()
                            )
                        Text(row.displayName)
                            .font(ZeehoFont.title)
                            .foregroundStyle(ZeehoTheme.onSurface)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Spacer(minLength: 0)
                        Button("移除", role: .destructive) {
                            model.removeAccount(id: row.id)
                        }
                        .font(ZeehoFont.label)
                        .foregroundStyle(ZeehoTheme.onErrorContainer)
                    }
                    HStack(spacing: 8) {
                        metric("积分", row.pointsText)
                        metric("连签", row.continueText)
                    }
                    if let message = row.message, row.signedToday != true {
                        Text(message)
                            .font(ZeehoFont.bodySmall)
                            .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                            .lineLimit(2)
                    }
                    if let unread = row.unread, unread > 0, let text = row.latestMessage, !text.isEmpty {
                        Text("\(unread) 条未读 · \(text)")
                            .font(ZeehoFont.bodySmall)
                            .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .background(ZeehoTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func vehicleCard(_ vehicle: VehicleStatus, showAccount: Bool) -> some View {
        let title = showAccount ? VehicleRoster.caption(model.status, vehicle) : vehicle.titleText
        let meta = [vehicle.onlineDisplay == "—" ? nil : vehicle.onlineDisplay, vehicle.rideState.flatMap { state in
            state.isEmpty || state == vehicle.onlineText ? nil : state
        }, vehicle.locationText.isEmpty ? nil : vehicle.locationText].compactMap { $0 }.joined(separator: "  ")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                vehicleThumb(vehicle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ZeehoFont.title)
                        .foregroundStyle(ZeehoTheme.onSurface)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(ZeehoFont.bodySmall)
                            .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                Spacer(minLength: 0)
                if let owner = model.status.accountRows.first(where: { $0.id == vehicle.accountId }) {
                    AccountAvatar(id: owner.id, url: owner.avatar, side: 36)
                }
            }
            HStack(spacing: 8) {
                metric("电量", vehicle.batteryText)
                metric("续航", vehicle.rangeText)
                metric("总里程", vehicle.mileageText)
            }
            HStack(spacing: 8) {
                metric("车锁", vehicle.lockText ?? "—")
                metric("充电", vehicle.chargeDisplay)
                metric("信号", vehicle.signal ?? "—")
            }
            if vehicle.powerText != nil || vehicle.currentText != nil || vehicle.etaText != nil || vehicle.chargedText != nil {
                HStack(spacing: 8) {
                    metric("功率", vehicle.powerText ?? "—")
                    metric("电流", vehicle.currentText ?? "—")
                    metric("充满", vehicle.etaText ?? "—", lines: 2)
                }
                if let charged = vehicle.chargedText, !charged.isEmpty {
                    metric("已充", charged, lines: 2)
                }
            }
            HStack(spacing: 8) {
                metric("胎压", vehicle.pressureText ?? "—", lines: 2)
                metric("电压", vehicle.voltageText ?? "—")
                metric("固件", vehicle.otaVersion ?? "—", lines: 2)
            }
            HStack(spacing: 8) {
                metric("坐垫", vehicle.cushionText ?? "—")
                metric("在线", vehicle.onlineDisplay, lines: 2)
            }
            if let ride = vehicle.todayRideText, !ride.isEmpty {
                let place = vehicle.address?.isEmpty == false ? vehicle.address! : "暂无位置"
                if place.count > 16 {
                    metric("今日骑行", ride, lines: 2)
                    metric("位置", place, lines: 3)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        metric("今日骑行", ride, lines: 2)
                        metric("位置", place, lines: 2)
                    }
                }
            }
            if let last = vehicle.lastRideText, !last.isEmpty {
                metric("上次骑行", last, lines: 2)
            }
            controlButtons(vehicle)
        }
        .padding(10)
        .background(ZeehoTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func controlButtons(_ vehicle: VehicleStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("车辆控制")
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurface)
            Text("这些按钮会直接操作这辆车，点下去之前会再确认一次。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            HStack(spacing: 8) {
                controlButton(.find, vehicle)
                controlButton(.horn, vehicle)
                controlButton(.seat, vehicle)
            }
            HStack(spacing: 8) {
                controlButton(.unlock, vehicle)
                controlButton(.lock, vehicle)
                chargeMenu(vehicle)
            }
        }
        .padding(.top, 4)
        .task(id: vehicle.vin) {
            await model.loadChargeChoices(vehicle: vehicle)
        }
    }

    private func controlButton(_ action: VehicleAction, _ vehicle: VehicleStatus) -> some View {
        Button(action.title) { model.ask(action, vehicle: vehicle) }
            .buttonStyle(TonalButtonStyle(enabled: !model.controlling && !model.refreshing))
            .disabled(model.controlling || model.refreshing || (vehicle.vin ?? "").isEmpty)
    }

    private func chargeMenu(_ vehicle: VehicleStatus) -> some View {
        let options = vehicle.vin.flatMap { model.chargeChoices[$0] } ?? []
        return Menu {
            if options.isEmpty {
                Button("先刷新档位") {
                    Task { await model.loadChargeChoices(vehicle: vehicle) }
                }
            } else {
                ForEach(options, id: \.self) { option in
                    Button(option) { model.ask(.charge, vehicle: vehicle, chargeValue: option) }
                }
            }
        } label: {
            Text("充电功率")
                .font(ZeehoFont.labelLarge)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(ZeehoTheme.primaryContainer, in: Capsule())
                .foregroundStyle(ZeehoTheme.onPrimaryContainer)
        }
        .disabled((vehicle.vin ?? "").isEmpty || model.controlling || model.refreshing)
    }

    private func vehicleThumb(_ vehicle: VehicleStatus) -> some View {
        Group {
            if let vin = vehicle.vin, let data = ZeehoFiles.vehicleImageData(vin: vin), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let raw = vehicle.vehiclePicUrl, let url = URL(string: raw), !raw.isEmpty {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "scooter")
                            .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                    }
                }
            } else {
                Image(systemName: "scooter")
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            }
        }
        .frame(width: 72, height: 56)
        .padding(6)
        .background(ZeehoTheme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var tokenEditor: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            Text("再粘贴一个 Token 就多一个账号，已有账号不会被覆盖。Authorization 或签到页链接都可以。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            TextField("Bearer Token 或签到页链接", text: $model.tokenDraft, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(ZeehoTheme.onSurface)
                .padding(12)
                .background(ZeehoTheme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Button("粘贴") {
                    if let text = UIPasteboard.general.string {
                        model.tokenDraft = text
                    }
                }
                .foregroundStyle(ZeehoTheme.primary)
                Spacer()
                Button(model.refreshing ? "添加中" : "添加账号") {
                    Task { await model.saveToken() }
                }
                .buttonStyle(TonalButtonStyle(enabled: !model.refreshing))
                .disabled(model.refreshing)
            }
            .font(ZeehoFont.labelLarge)
            if model.status.hasToken == true && model.status.tokenInvalid != true {
                Button("取消") {
                    model.editingToken = false
                    model.tokenDraft = ""
                }
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            }
        }
    }

    private var pointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("积分任务")
                .font(ZeehoFont.title)
                .foregroundStyle(ZeehoTheme.onSurface)
            Text("打开后，每天签到时会把未完成的发帖、点赞、分享做完。帖子发到你自己的极核社区，做完可以删掉。默认关闭。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                watchChip("每天执行", model.points.enabled) {
                    var next = model.points
                    next.enabled.toggle()
                    model.savePoints(next)
                }
                watchChip("做完删除", model.points.deleteAfter) {
                    var next = model.points
                    next.deleteAfter.toggle()
                    model.savePoints(next)
                }
            }
            TextField("发帖内容", text: Binding(
                get: { model.points.content },
                set: { value in
                    var next = model.points
                    next.content = value
                    model.savePoints(next)
                }
            ))
            .font(ZeehoFont.body)
            .padding(10)
            .background(ZeehoTheme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button(model.refreshing ? "执行中" : "现在执行") {
                Task { await model.runPointsNow() }
            }
            .font(ZeehoFont.labelLarge)
            .foregroundStyle(ZeehoTheme.primary)
            .disabled(model.refreshing)
            let note = model.pointsNote.isEmpty ? model.points.result : model.pointsNote
            if !note.isEmpty {
                Text(note)
                    .font(ZeehoFont.bodySmall)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.points.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("内容空着时会用「今日打卡」。")
                    .font(ZeehoFont.label)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZeehoTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var widgetVehiclePicker: some View {
        let vehicles = VehicleRoster.all(model.status)
        return Group {
            if vehicles.count >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("小组件车辆")
                        .font(ZeehoFont.labelLarge)
                        .foregroundStyle(ZeehoTheme.onSurface)
                    Text("两台车不一样。桌面小组件只显示选中的这一台，车控也打到这台上。")
                        .font(ZeehoFont.bodySmall)
                        .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                    let active = vehicles.contains { VehicleRoster.key($0) == model.widgetConfig.vehicleKey }
                        ? model.widgetConfig.vehicleKey
                        : VehicleRoster.key(vehicles[0])
                    chipRows(vehicles.map { ($0, VehicleRoster.caption(model.status, $0)) }, selected: active) { vehicle in
                        var next = model.widgetConfig
                        next.vehicleKey = VehicleRoster.key(vehicle)
                        model.saveWidget(next)
                    }
                }
            }
        }
    }

    private var widgetFactPicker: some View {
        let selected = model.widgetConfig.shownFacts
        return VStack(alignment: .leading, spacing: 8) {
            Text("监控区")
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurface)
            Text(selected.count >= ZeehoWidgetFact.limit
                 ? "已选 \(selected.count) 项，排成 \(ZeehoWidgetFact.columns)×\(ZeehoWidgetFact.rows)。点掉一项再换。"
                 : "最多 \(ZeehoWidgetFact.columns)×\(ZeehoWidgetFact.rows)，已选 \(selected.count) 项。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            chipRows(ZeehoWidgetFact.allCases.map { ($0, $0.title) }, selected: "") { fact in
                var next = model.widgetConfig
                var facts = next.shownFacts
                if facts.contains(fact) {
                    facts.removeAll { $0 == fact }
                } else if facts.count < ZeehoWidgetFact.limit {
                    facts.append(fact)
                }
                guard !facts.isEmpty, facts != next.shownFacts else { return }
                next.facts = facts.map(\.rawValue)
                model.saveWidget(next)
            }
        }
    }

    private var widgetActionPicker: some View {
        let selected = model.widgetConfig.shownActions
        let options: [VehicleAction] = [.find, .horn, .seat, .unlock, .lock]
        return VStack(alignment: .leading, spacing: 8) {
            Text("功能按钮")
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurface)
            Text(selected.isEmpty
                 ? "点选最多 3 个，点下去会打开 App 再确认。"
                 : "已选 \(selected.map(\.title).joined(separator: "、"))。最多 3 个。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            chipRows(options.map { ($0, $0.title) }, selected: "") { action in
                var next = model.widgetConfig
                var actions = next.shownActions
                if actions.contains(action) {
                    actions.removeAll { $0 == action }
                } else if actions.count < 3 {
                    actions.append(action)
                } else {
                    return
                }
                next.actions = actions.map(\.rawValue)
                model.saveWidget(next)
            }
        }
    }

    private func chipRows<Item>(_ items: [(Item, String)], selected: String, onTap: @escaping (Item) -> Void) -> some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                        let on = chipOn(item.0, selected: selected)
                        Button {
                            onTap(item.0)
                        } label: {
                            Text(item.1)
                                .font(ZeehoFont.label)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(on ? ZeehoTheme.primaryContainer : ZeehoTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .foregroundStyle(on ? ZeehoTheme.onPrimaryContainer : ZeehoTheme.onSurface)
                        }
                        .buttonStyle(.plain)
                    }
                    if row.count < 3 {
                        ForEach(0..<(3 - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func chipOn<Item>(_ item: Item, selected: String) -> Bool {
        if let vehicle = item as? VehicleStatus { return VehicleRoster.key(vehicle) == selected }
        return isPicked(item)
    }

    private func isPicked<Item>(_ item: Item) -> Bool {
        if let fact = item as? ZeehoWidgetFact { return model.widgetConfig.shownFacts.contains(fact) }
        if let action = item as? VehicleAction { return model.widgetConfig.shownActions.contains(action) }
        return false
    }

    private var watchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("车况提醒")
                .font(ZeehoFont.title)
                .foregroundStyle(ZeehoTheme.onSurface)
            Text("充电开始、充满和中断会通知。新的车辆消息也会计入。低电量、离线和胎压默认关着。车况按你设的更新间隔拉取。小组件按钮会打开 App 再确认。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            if !model.notificationsAllowed {
                Text("通知被系统关掉了。到设置里允许通知后，充电、消息和车况才会弹出来。")
                    .font(ZeehoFont.bodySmall)
                    .foregroundStyle(ZeehoTheme.onErrorContainer)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                watchChip("充电", model.watch.charge) { model.setWatch(toggled(\.charge)) }
                watchChip("消息", model.watch.messages) { model.setWatch(toggled(\.messages)) }
            }
            HStack(spacing: 8) {
                watchChip("低电量", model.watch.low) { model.setWatch(toggled(\.low)) }
                watchChip("离线", model.watch.offline) { model.setWatch(toggled(\.offline)) }
                watchChip("胎压", model.watch.tire) { model.setWatch(toggled(\.tire)) }
            }
            let mail = model.status.accountRows.first { ($0.unread ?? 0) > 0 && !($0.latestMessage ?? "").isEmpty }
            if let mail {
                Text("\(mail.displayName) \(mail.unread ?? 0) 条未读 · \(mail.latestMessage ?? "")")
                    .font(ZeehoFont.bodySmall)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                    .lineLimit(2)
            }
            let samples = ZeehoFiles.recentBatteries()
            if !samples.isEmpty {
                Text("电量记录")
                    .font(ZeehoFont.labelLarge)
                    .foregroundStyle(ZeehoTheme.onSurface)
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    let whenText = ZeehoClock.format(Date(timeIntervalSince1970: sample.at), "MM-dd HH:mm")
                    let bits = [sample.soc.map { "\($0)%" }, sample.power, sample.voltage, sample.charge].compactMap { $0 }
                    Text("\(whenText)  \(sample.name)  \(bits.joined(separator: " · "))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZeehoTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func toggled(_ keyPath: WritableKeyPath<ZeehoWatchPrefs, Bool>) -> ZeehoWatchPrefs {
        var next = model.watch
        next[keyPath: keyPath].toggle()
        return next
    }

    private func watchChip(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(on ? "\(title) 开" : title)
                .font(ZeehoFont.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(on ? ZeehoTheme.primaryContainer : ZeehoTheme.surfaceContainerHigh, in: Capsule())
                .foregroundStyle(on ? ZeehoTheme.onPrimaryContainer : ZeehoTheme.onSurface)
        }
        .buttonStyle(.plain)
    }

    private var appearanceSection: some View {
        AppearanceEditor()
    }

    private var autoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自动打卡")
                .font(ZeehoFont.title)
                .foregroundStyle(ZeehoTheme.onSurface)
            Text("把小组件加到主屏幕。每个还没签到的账号，都会在小组件刷新时签到。iOS 不保证准点，下面两路用来补上。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            labeled("后台刷新", "打开过 App 就会预约，尽量在每天 08:30（上海）前后执行。")
            labeled("快捷指令", "自动化 → 特定时间 → 每天 08:30 → 运行「极核签到」。这一路最稳。")
            Text("更新间隔")
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurface)
            Text("从 15 分钟到 24 小时。小组件和车况按这个间隔刷新。08:30 的签到仍然会单独赶上。系统可以推迟，不保证准点。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            let choices = ZeehoFiles.refreshChoices
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: choices.count, by: 4)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(choices[start..<min(start + 4, choices.count)], id: \.self) { minutes in
                            let on = model.refreshMinutes == minutes
                            Button {
                                model.setRefreshMinutes(minutes)
                            } label: {
                                Text(ZeehoFiles.refreshLabel(minutes))
                                    .font(ZeehoFont.label)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(on ? ZeehoTheme.primaryContainer : ZeehoTheme.surfaceContainerHigh, in: Capsule())
                                    .foregroundStyle(on ? ZeehoTheme.onPrimaryContainer : ZeehoTheme.onSurface)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Text("下次尝试 \(ZeehoClock.format(ZeehoScheduler.nextRefresh(after: Date(), status: model.status), "MM-dd HH:mm"))")
                .font(ZeehoFont.label)
                .foregroundStyle(ZeehoTheme.outline)
                .monospacedDigit()
            widgetVehiclePicker
            widgetFactPicker
            widgetActionPicker
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZeehoTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func labeled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurface)
            Text(detail)
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var secretsSection: some View {
        @Bindable var model = model
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("来自公开客户端，不是登录 Token。接口返回 30125 时才需要改。")
                    .font(ZeehoFont.bodySmall)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                secretField("H5 App Id", text: $model.secretDraft.h5AppId)
                secretField("H5 Secret", text: $model.secretDraft.h5AppSecret)
                secretField("车辆 App Id", text: $model.secretDraft.appId)
                secretField("车辆 Secret", text: $model.secretDraft.appSecret)
                secretField("云端控车密钥", text: $model.secretDraft.vehicleAesKey)
                HStack {
                    Button("恢复默认") { model.resetSecrets() }
                        .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                    Spacer()
                    Button("保存密钥") { model.saveSecrets() }
                        .foregroundStyle(ZeehoTheme.primary)
                }
                .font(ZeehoFont.labelLarge)
                .padding(.top, 4)
            }
            .padding(.top, 8)
        } label: {
            Text("签名密钥")
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
        }
        .tint(ZeehoTheme.primary)
    }

    private func secretField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(ZeehoTheme.onSurface)
            .padding(10)
            .background(ZeehoTheme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var captureSection: some View {
        @Bindable var model = model
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("开 VPN 代理官方极核 App 的流量，自动抓到 Authorization Token 并导入。第一次要装自签 CA。")
                    .font(ZeehoFont.bodySmall)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Text("⚠️ 需先在 Xcode 里加 Network Extension target（ZeehoTunnel）。App Store 审核会查 VPN 用途，请如实描述。")
                    .font(ZeehoFont.labelSmall)
                    .foregroundStyle(ZeehoTheme.onErrorContainer)
                HStack {
                    Button("开始抓取") {
                        Task {
                            do {
                                try await ZeehoCaptureManager.shared.start()
                                model.notice = "VPN 已建立，去官方 App 登录"
                            } catch {
                                model.banner = error.localizedDescription
                            }
                        }
                    }
                    .disabled(ZeehoCaptureManager.shared.result.state == .requestingVPN || ZeehoCaptureManager.shared.result.state == .waiting || ZeehoCaptureManager.shared.result.state == .running)
                    if ZeehoCaptureManager.shared.result.state == .waiting || ZeehoCaptureManager.shared.result.state == .running {
                        ProgressView().controlSize(.small).tint(ZeehoTheme.onPrimaryContainer)
                        Button("停止") { ZeehoCaptureManager.shared.stop() }
                            .foregroundStyle(ZeehoTheme.onErrorContainer)
                    }
                }
                .font(ZeehoFont.labelLarge)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundStyle(ZeehoTheme.primary)
                Text("代理抓取 Token")
                    .font(ZeehoFont.labelLarge)
                    .foregroundStyle(ZeehoTheme.onSurface)
                Spacer()
                if ZeehoCaptureManager.shared.result.state == .waiting || ZeehoCaptureManager.shared.result.state == .running {
                    Text("运行中")
                        .font(ZeehoFont.labelSmall)
                        .foregroundStyle(ZeehoTheme.onPrimaryContainer)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZeehoTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .tint(ZeehoTheme.primary)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
            Text(model.status.updatedText.isEmpty ? "尚未刷新" : model.status.updatedText)
                .font(ZeehoFont.labelSmall)
                .foregroundStyle(ZeehoTheme.outline)
            Spacer()
            if model.status.hasToken == true && !model.editingToken {
                Button("添加账号") { model.editingToken = true }
                    .font(ZeehoFont.labelLarge)
                    .foregroundStyle(ZeehoTheme.primary)
            }
            if model.status.hasToken == true {
                Button("清除", role: .destructive) { model.clearToken() }
                    .font(ZeehoFont.labelLarge)
                    .foregroundStyle(ZeehoTheme.onErrorContainer)
            }
            Button {
                Task { await model.refresh(ignoreGate: true) }
            } label: {
                HStack(spacing: 6) {
                    if model.refreshing {
                        ProgressView().controlSize(.small).tint(ZeehoTheme.onPrimaryContainer)
                    }
                    Text(signButtonTitle)
                }
            }
            .buttonStyle(TonalButtonStyle(enabled: !model.refreshing))
            .disabled(model.refreshing)
        }
        Text("版本 \(ZeehoConfig.build)")
            .font(ZeehoFont.labelSmall)
            .foregroundStyle(ZeehoTheme.outline)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var signButtonTitle: String {
        if model.refreshing { return "处理中" }
        if model.status.signedToday == true { return "刷新" }
        return "签到"
    }

    private func banner(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text)
            .font(ZeehoFont.bodySmall)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TonalButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ZeehoFont.labelLarge)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(ZeehoTheme.primaryContainer, in: Capsule())
            .foregroundStyle(ZeehoTheme.onPrimaryContainer)
            .opacity(!enabled ? 0.38 : (configuration.isPressed ? 0.85 : 1))
    }
}

private struct AccountAvatar: View {
    var id: String?
    var url: String?
    var side: CGFloat

    var body: some View {
        Group {
            if let id, let data = ZeehoFiles.avatarData(id: id), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let raw = url, raw.hasPrefix("http"), let remote = URL(string: raw) {
                AsyncImage(url: remote) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        avatarFallback(side)
                    }
                }
            } else {
                avatarFallback(side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
    }
}

private func avatarFallback(_ side: CGFloat) -> some View {
    ZStack {
        Circle().fill(ZeehoTheme.secondaryContainer)
        Image(systemName: "person.fill")
            .font(.system(size: side * 0.42))
            .foregroundStyle(ZeehoTheme.onSecondaryContainer)
    }
}

private struct AppearanceEditor: View {
    @Environment(ZeehoModel.self) private var model
    @State private var hex = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var cropImage: UIImage?

    var body: some View {
        let skin = model.skin
        VStack(alignment: .leading, spacing: 8) {
            Text("外观")
                .font(ZeehoFont.title)
                .foregroundStyle(ZeehoTheme.onSurface)
            Text("主题色用在软件上。小组件的背景色和每个信息块的底色分开选，背景色可以选择纯黑。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            colorRow(ZeehoSkinStore.presets, selected: skin.accent) { color in
                var next = skin
                next.accent = color
                hex = String(format: "%06X", color & 0xFFFFFF)
                model.applySkin(next)
            }
            HStack(spacing: 8) {
                Text("#")
                    .font(ZeehoFont.labelLarge)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                TextField("主题色", text: $hex)
                    .font(ZeehoFont.body)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: hex) { _, value in
                        let filtered = String(value.prefix(6).filter { $0.isHexDigit })
                        if filtered != value { hex = filtered }
                    }
                Button("使用") {
                    guard let parsed = ZeehoSkinStore.parseHex(hex) else { return }
                    var next = model.skin
                    next.accent = parsed
                    model.applySkin(next)
                }
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.primary)
            }
            Text("小组件背景色")
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurface)
            colorRow(ZeehoSkinStore.backgroundPresets, selected: skin.widgetBackground & 0xFFFFFF) { color in
                var next = skin
                next.widgetBackground = color
                next.useImage = false
                model.applySkin(next)
            }
            Text("小组件信息块底色")
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurface)
            colorRow(ZeehoSkinStore.itemPresets, selected: skin.widgetItem & 0xFFFFFF) { color in
                var next = skin
                next.widgetItem = color
                model.applySkin(next)
            }
            Text("小组件背景图")
                .font(ZeehoFont.labelLarge)
                .foregroundStyle(ZeehoTheme.onSurface)
            HStack(spacing: 8) {
                choice("背景色", on: !skin.useImage) {
                    var next = model.skin
                    next.useImage = false
                    model.applySkin(next)
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text("图片")
                        .font(ZeehoFont.label)
                        .foregroundStyle(skin.useImage ? ZeehoTheme.onPrimaryContainer : ZeehoTheme.onSurface)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(skin.useImage ? ZeehoTheme.primaryContainer : ZeehoTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Text("选图后可以拖动、缩放再裁切。")
                .font(ZeehoFont.bodySmall)
                .foregroundStyle(ZeehoTheme.onSurfaceVariant)
            if skin.useImage {
                Button("去掉图片") { model.clearSkinImage() }
                    .font(ZeehoFont.labelLarge)
                    .foregroundStyle(ZeehoTheme.onErrorContainer)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZeehoTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            if hex.isEmpty { hex = String(format: "%06X", skin.accent & 0xFFFFFF) }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    cropImage = normalized(image)
                }
                pickerItem = nil
            }
        }
        .sheet(isPresented: Binding(get: { cropImage != nil }, set: { if !$0 { cropImage = nil } })) {
            if let cropImage {
                SkinCropper(image: cropImage) {
                    self.cropImage = nil
                } onCropped: { image in
                    model.saveSkinImage(image)
                    self.cropImage = nil
                }
            }
        }
    }

    private func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    private func colorRow(_ colors: [UInt32], selected: UInt32, onPick: @escaping (UInt32) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(colors, id: \.self) { color in
                let on = (color & 0xFFFFFF) == (selected & 0xFFFFFF)
                Button {
                    onPick(color)
                } label: {
                    Circle()
                        .fill(Color(hex: color))
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(on ? ZeehoTheme.onSurface : ZeehoTheme.outline, lineWidth: on ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func choice(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ZeehoFont.label)
                .foregroundStyle(on ? ZeehoTheme.onPrimaryContainer : ZeehoTheme.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(on ? ZeehoTheme.primaryContainer : ZeehoTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SkinCropper: View {
    var image: UIImage
    var onCancel: () -> Void
    var onCropped: (UIImage) -> Void
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let frame = cropFrame(in: geo.size)
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height)
                            }
                            .onEnded { _ in baseOffset = offset }
                            .simultaneously(with: MagnificationGesture()
                                .onChanged { value in scale = min(4, max(1, baseScale * value)) }
                                .onEnded { _ in baseScale = scale })
                    )
                VStack {
                    Spacer()
                    HStack {
                        Button("取消", action: onCancel)
                        Spacer()
                        Button("使用") { onCropped(cropped(frame: frame)) }
                    }
                    .font(ZeehoFont.labelLarge)
                    .foregroundStyle(.white)
                    .padding(24)
                }
            }
        }
    }

    private func cropFrame(in size: CGSize) -> CGSize {
        let aspect: CGFloat = 2
        let maxW = size.width - 56
        let maxH = size.height - 160
        if maxW / maxH > aspect {
            return CGSize(width: maxH * aspect, height: maxH)
        }
        return CGSize(width: maxW, height: maxW / aspect)
    }

    private func cropped(frame: CGSize) -> UIImage {
        let pixel = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let fill = max(frame.width / pixel.width, frame.height / pixel.height)
        let drawnW = pixel.width * fill * scale
        let drawnH = pixel.height * fill * scale
        let left = (frame.width - drawnW) / 2 + offset.width
        let top = (frame.height - drawnH) / 2 + offset.height
        let sx = max(0, -left / (fill * scale))
        let sy = max(0, -top / (fill * scale))
        let sw = min(pixel.width - sx, frame.width / (fill * scale))
        let sh = min(pixel.height - sy, frame.height / (fill * scale))
        let rect = CGRect(x: sx, y: sy, width: max(1, sw), height: max(1, sh))
        guard let cg = image.cgImage?.cropping(to: rect) else { return image }
        return UIImage(cgImage: cg, scale: 1, orientation: image.imageOrientation)
    }
}

private struct DisclaimerView: View {
    var accept: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("这是个人自用的非官方工具，和极核、春风动力没有关系。")
                    Text("Token 等于登录凭证，只保存在这台手机里，不要发到别处。")
                    Text("官方 App 是单会话。同一个 Token 在这里使用，可能把手机上的极核 App 挤下线。")
                    Text("这里不能用短信验证码登录。Token 过期后，需要你自己从已经登录的 App 里更新。")
                    Text("小组件刷新、后台刷新和快捷指令都会替你调用签到接口。")
                }
                .font(ZeehoFont.body)
                .foregroundStyle(ZeehoTheme.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(ZeehoTheme.surface)
            .navigationTitle("使用前")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("同意并继续", action: accept)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(ZeehoTheme.primary)
    }
}

#Preview {
    ContentView()
        .environment(ZeehoModel(preview: true))
}
