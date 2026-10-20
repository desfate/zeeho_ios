import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(ZeehoModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
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
                    autoSection
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
        HStack(spacing: 12) {
            avatar
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

    private var avatar: some View {
        Group {
            if let raw = model.status.avatar, let url = URL(string: raw), !raw.isEmpty {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private var avatarFallback: some View {
        ZStack {
            Circle().fill(ZeehoTheme.secondaryContainer)
            Image(systemName: "person.fill")
                .foregroundStyle(ZeehoTheme.onSecondaryContainer)
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
        let rows = model.status.accountRows.flatMap(\.shownVehicles)
        if !rows.isEmpty { return rows }
        return singleVehicles
    }

    private var singleVehicles: [VehicleStatus] {
        if let vehicles = model.status.vehicles, !vehicles.isEmpty { return vehicles }
        if let vehicle = model.status.vehicle { return [vehicle] }
        return []
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
                    vehicleCard(item)
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
                }
                .padding(10)
                .background(ZeehoTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func vehicleCard(_ vehicle: VehicleStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                vehicleThumb(vehicle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vehicle.vehicleName?.isEmpty == false ? vehicle.vehicleName! : "车辆")
                        .font(ZeehoFont.title)
                        .foregroundStyle(ZeehoTheme.onSurface)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 6) {
                        if let state = vehicle.rideState, !state.isEmpty {
                            Text(state)
                                .lineLimit(1)
                        }
                        if !vehicle.locationText.isEmpty {
                            Text(vehicle.locationText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .font(ZeehoFont.bodySmall)
                    .foregroundStyle(ZeehoTheme.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                metric("电量", vehicle.batteryText)
                metric("续航", vehicle.rangeText)
            }
            metric("总里程", vehicle.mileageText)
            HStack(spacing: 8) {
                metric("车锁", vehicle.lockText ?? "—")
                metric("充电", vehicle.chargeDisplay)
                metric("信号", vehicle.signal ?? "—")
            }
            HStack(spacing: 8) {
                metric("胎压", vehicle.pressureText ?? "—", lines: 2)
                metric("电压", vehicle.voltageText ?? "—")
                metric("固件", vehicle.otaVersion ?? "—", lines: 2)
            }
            HStack(spacing: 8) {
                metric("坐垫", vehicle.cushionText ?? "—")
                metric("在线", vehicle.onlineText ?? "—", lines: 2)
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
            Text("下次尝试 \(ZeehoClock.format(ZeehoScheduler.nextRefresh(after: Date(), status: model.status), "MM-dd HH:mm"))")
                .font(ZeehoFont.label)
                .foregroundStyle(ZeehoTheme.outline)
                .monospacedDigit()
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

    private var footer: some View {
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
