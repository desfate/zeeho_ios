import CoreLocation
import Foundation
import os

private let apiLog = Logger(subsystem: "com.jieyu.zeeho.signin", category: "api")

private struct HTTPResult {
    var status: Int
    var json: [String: Any]?
    var error: String?
}

enum ZeehoJSON {
    static func object(_ any: Any?) -> [String: Any] {
        any as? [String: Any] ?? [:]
    }

    static func firstObject(_ any: Any?) -> [String: Any]? {
        if let dict = any as? [String: Any] { return dict }
        if let list = any as? [Any] { return list.first as? [String: Any] }
        return nil
    }

    static func string(_ any: Any?) -> String {
        switch any {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    static func int(_ any: Any?) -> Int? {
        switch any {
        case let number as NSNumber:
            return number.intValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" { return nil }
            return Int(trimmed)
        default:
            return nil
        }
    }

    static func double(_ any: Any?) -> Double? {
        switch any {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" { return nil }
            return Double(trimmed)
        default:
            return nil
        }
    }

    static func isOK(_ json: [String: Any]?) -> Bool {
        let code = code(json)
        return code == "10000" || code == "0" || code == "200"
    }

    static func code(_ json: [String: Any]?) -> String {
        guard let json else { return "" }
        let primary = string(json["code"])
        return primary.isEmpty ? string(json["status"]) : primary
    }

    static func message(_ json: [String: Any]?) -> String {
        guard let json else { return "" }
        let message = string(json["message"])
        return message.isEmpty ? string(json["msg"]) : message
    }
}

struct ZeehoClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func run(token: String, secrets: ZeehoSecrets, now: Date) async -> SigninStatus {
        defer { session.finishTasksAndInvalidate() }
        var status = SigninStatus()
        status.hasToken = true
        status.today = ZeehoClock.todayString(now)
        await warmup(secrets)
        if Task.isCancelled { return status }

        let base = await request(method: "GET", path: "/cfmotoservermine/baseInfo", token: token, secrets: secrets, query: "")
        if base.json == nil {
            return failure(status, now: now, message: base.error ?? "请求发不出去 HTTP \(base.status)")
        }
        if isTokenInvalid(base) {
            return invalidToken(status, now: now)
        }
        if ZeehoJSON.isOK(base.json) {
            let data = ZeehoJSON.object(base.json?["data"])
            let name = ZeehoJSON.string(data["nickName"])
            let avatar = ZeehoJSON.string(data["avatar"])
            if !name.isEmpty { status.nickName = name }
            if !avatar.isEmpty { status.avatar = avatar }
        }

        let summary = await request(method: "GET", path: "/cfmotoservermine/H5/signin", token: token, secrets: secrets, query: "")
        if isTokenInvalid(summary) {
            return invalidToken(status, now: now)
        }
        if ZeehoJSON.isOK(summary.json) {
            applySummary(summary.json, to: &status)
        }

        let month = ZeehoClock.monthQuery(from: ZeehoClock.todayString(now))
        let info = await request(
            method: "GET",
            path: "/cfmotoservermine/H5/signin/info",
            token: token,
            secrets: secrets,
            query: "month=\(month)"
        )
        if ZeehoJSON.isOK(info.json) {
            status.signinIntegral = ZeehoJSON.int(ZeehoJSON.object(info.json?["data"])["integral"])
        }

        let total = await request(
            method: "GET",
            path: "/cfmotoservermine/integral/totalIntegral",
            token: token,
            secrets: secrets,
            query: ""
        )
        if ZeehoJSON.isOK(total.json) {
            status.totalIntegral = ZeehoJSON.int(ZeehoJSON.object(total.json?["data"])["integralTotal"])
            status.integral = status.totalIntegral
        }

        if status.lastTime?.hasPrefix(ZeehoClock.todayString(now)) == true {
            return await alreadySigned(status, now: now, secrets: secrets, token: token)
        }

        let post = await request(method: "POST", path: "/cfmotoservermine/H5/signin", token: token, secrets: secrets, query: "")
        status.posted = true
        if isTokenInvalid(post) {
            return invalidToken(status, now: now)
        }
        if post.json == nil {
            return failure(status, now: now, message: "HTTP \(post.status) 返回非 JSON")
        }

        let confirm = await request(method: "GET", path: "/cfmotoservermine/H5/signin", token: token, secrets: secrets, query: "")
        if ZeehoJSON.isOK(confirm.json) {
            applySummary(confirm.json, to: &status)
        }
        let today = ZeehoClock.todayString(now)
        if status.lastTime?.hasPrefix(today) == true {
            status.ok = true
            status.signedToday = true
            status.error = nil
            let days = status.continueDays ?? 0
            let postCode = ZeehoJSON.code(post.json)
            if postCode == "10000" || postCode == "0" || postCode == "200" || postCode.isEmpty {
                status.title = "签到成功"
                status.message = "签到成功（连续 \(days) 天）"
            } else {
                status.title = "今日已签到"
                status.message = "今日已签到（连续 \(days) 天）"
            }
            let vehicles = await fetchVehicles(token: token, secrets: secrets)
            if !vehicles.isEmpty {
                status.vehicles = vehicles
                status.vehicle = vehicles[0]
            }
            stamp(&status, now: Date())
            return status
        }

        let postCode = ZeehoJSON.code(post.json)
        var why = ZeehoJSON.message(post.json)
        if why.isEmpty { why = "未知" }
        if postCode == "30125" {
            why += "（签名未通过，H5 密钥可能已更换）"
        } else if !postCode.isEmpty {
            why += " (code \(postCode))"
        }
        return failure(status, now: now, message: "签到未生效：\(why)")
    }

    private func alreadySigned(_ status: SigninStatus, now: Date, secrets: ZeehoSecrets, token: String) async -> SigninStatus {
        var status = status
        status.ok = true
        status.signedToday = true
        status.posted = false
        status.error = nil
        status.title = "今日已签到"
        status.message = "今日已签到（连续 \(status.continueDays ?? 0) 天）"
        let vehicles = await fetchVehicles(token: token, secrets: secrets)
        if !vehicles.isEmpty {
            status.vehicles = vehicles
            status.vehicle = vehicles[0]
        }
        stamp(&status, now: Date())
        return status
    }

    private func invalidToken(_ status: SigninStatus, now: Date) -> SigninStatus {
        var status = status
        status.ok = false
        status.tokenInvalid = true
        status.signedToday = false
        status.hasToken = true
        status.title = "Token 失效"
        status.message = "Token 失效，请从极核 App 重新复制 Authorization"
        status.error = status.message
        stamp(&status, now: now)
        return status
    }

    private func failure(_ status: SigninStatus, now: Date, message: String) -> SigninStatus {
        var status = status
        status.ok = false
        status.signedToday = false
        status.hasToken = true
        status.title = "签到失败"
        status.message = message
        status.error = message
        stamp(&status, now: now)
        return status
    }

    private func stamp(_ status: inout SigninStatus, now: Date) {
        status.today = ZeehoClock.todayString(now)
        status.updatedAt = ZeehoClock.nowString(now)
        status.updatedAtUnix = now.timeIntervalSince1970
        status.lastAttemptUnix = now.timeIntervalSince1970
        status.hasToken = true
    }

    private func applySummary(_ json: [String: Any]?, to status: inout SigninStatus) {
        let data = ZeehoJSON.object(json?["data"])
        let last = ZeehoJSON.string(data["lastTime"])
        if !last.isEmpty { status.lastTime = last }
        if let days = ZeehoJSON.int(data["continueDays"]) {
            status.continueDays = days
        }
    }

    private func warmup(_ secrets: ZeehoSecrets) async {
        guard let url = URL(string: secrets.baseURL + "/activity/signin") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(ZeehoConfig.webUA, forHTTPHeaderField: "User-Agent")
        _ = try? await session.data(for: request)
    }

    private func request(method: String, path: String, token: String, secrets: ZeehoSecrets, query: String) async -> HTTPResult {
        var last = HTTPResult(status: 0, json: nil, error: "未请求")
        for attempt in 0...1 {
            last = await once(method: method, path: path, token: token, secrets: secrets, query: query)
            let retryable = last.status == 0 || last.status >= 500 || (last.json == nil && last.status < 400)
            if !retryable || attempt == 1 || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return last
    }

    private func once(method: String, path: String, token: String, secrets: ZeehoSecrets, query: String) async -> HTTPResult {
        let signed = ZeehoCrypto.h5Sign(appId: secrets.h5AppId, appSecret: secrets.h5AppSecret, query: query, body: "")
        var urlText = secrets.baseURL + path
        if !query.isEmpty { urlText += "?\(query)" }
        guard let url = URL(string: urlText) else {
            return HTTPResult(status: 0, json: nil, error: "URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if method != "GET" && method != "DELETE" {
            request.httpBody = Data()
        }
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(ZeehoConfig.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue(ZeehoConfig.zeehoUA, forHTTPHeaderField: "Zeeho-User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(signed.sign, forHTTPHeaderField: "Cfmoto-X-Sign")
        request.setValue("0", forHTTPHeaderField: "Cfmoto-X-Sign-Type")
        request.setValue(signed.param, forHTTPHeaderField: "Cfmoto-X-Param")
        request.setValue(secrets.baseURL + "/activity/signin", forHTTPHeaderField: "Referer")
        request.setValue(secrets.baseURL, forHTTPHeaderField: "Origin")
        return await send(request, method: method, path: path)
    }

    func command(
        _ action: VehicleAction,
        token: String,
        vin: String,
        secrets: ZeehoSecrets,
        chargeValue: String? = nil
    ) async -> String {
        defer { session.finishTasksAndInvalidate() }
        let base = "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp"
        switch action {
        case .find:
            let result = await appRequest(
                method: "PUT",
                urlText: "\(base)/vehicleInfo/control/\(vin)",
                token: token,
                secrets: secrets
            )
            return commandMessage(result, success: "寻车指令已下发，车辆应闪灯")
        case .horn:
            let body = "{\"param\":\"4\",\"vin\":\"\(vin)\"}"
            let result = await appRequest(
                method: "POST",
                urlText: "\(base)/vehicleInfo/controlV2",
                token: token,
                secrets: secrets,
                body: body
            )
            return commandMessage(result, success: "鸣笛闪灯指令已下发")
        case .seat:
            let body = "{\"commond\":\"28\",\"commondParam\":\"1\",\"vcu\":\"\(vin)\",\"version\":\"v2\"}"
            let result = await appRequest(
                method: "PUT",
                urlText: "\(base)/vehicleSet/propertyTwo/one",
                token: token,
                secrets: secrets,
                body: body
            )
            return commandMessage(result, success: "开坐垫指令已下发")
        case .unlock, .lock:
            let flag = action == .unlock ? "1" : "0"
            let plain = "{\n  \"lockFlag\" : \"\(flag)\",\n  \"vinNo\" : \"\(vin)\"\n}"
            guard let secret = ZeehoCrypto.aes256ECBBase64(plain: plain, key: secrets.vehicleAesKey) else {
                return "云端控车密钥需要 32 位，请在签名密钥里检查"
            }
            let result = await appRequest(
                method: "POST",
                urlText: "\(base)/vehicleSet/network/unlock",
                token: token,
                secrets: secrets,
                body: "{\"secret\":\"\(secret)\"}",
                signBody: plain
            )
            return commandMessage(result, success: action == .unlock ? "云端开锁指令已下发" : "云端关锁指令已下发")
        case .charge:
            let value = chargeValue ?? ""
            guard !value.isEmpty else { return "先选择充电功率" }
            let body = "{\"serviceCode\":603980102,\"commandParam\":\"\(value)\",\"flag\":true,\"vin\":\"\(vin)\",\"vehicleSetEnum\":\"CHARGING_POWER_STANDARD\",\"message\":0}"
            let result = await appRequest(
                method: "POST",
                urlText: "\(base)/vehicleSet/addVehicleSet",
                token: token,
                secrets: secrets,
                body: body
            )
            return commandMessage(result, success: "充电功率已设为 \(value)")
        }
    }

    func chargeOptions(token: String, vin: String, secrets: ZeehoSecrets) async -> [String] {
        defer { session.finishTasksAndInvalidate() }
        let query = "vinNo=\(percent(vin))&flag=1"
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/vehicleSet/chargePower/options?\(query)",
            token: token,
            secrets: secrets,
            query: query
        )
        return parseChargeOptions(result.json)
    }

    private func fetchVehicles(token: String, secrets: ZeehoSecrets) async -> [VehicleStatus] {
        let listed = await fetchVehicleList(token: token, secrets: secrets)
        let seeds = listed.isEmpty ? parseVehicles(await tapiGet(ZeehoConfig.vehicleURL, token: token, secrets: secrets).json) : listed
        guard !seeds.isEmpty else { return [] }
        var enriched: [VehicleStatus] = []
        for seed in seeds.prefix(3) {
            var vehicle = seed
            if let vin = vehicle.vin, !vin.isEmpty {
                if let detail = parseVehicles(await appRequest(
                    method: "GET",
                    urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/vehicle/widgets/\(percent(vin))",
                    token: token,
                    secrets: secrets
                ).json).first {
                    vehicle = mergeVehicle(vehicle, detail)
                    vehicle.vin = vin
                }
                applyTire(await tireStatus(token: token, vin: vin, secrets: secrets), to: &vehicle)
                applyCharge(await batteryStatus(token: token, vin: vin, secrets: secrets), to: &vehicle)
                let home = await rideStatus(token: token, vin: vin, secrets: secrets)
                let month = await monthRide(token: token, vin: vin, secrets: secrets)
                applyRide(home: home, month: month, to: &vehicle)
                if (vehicle.address ?? "").isEmpty || vehicle.latitude == nil {
                    applyLocation(await homePage(token: token, vin: vin, secrets: secrets), to: &vehicle)
                }
                if (vehicle.address ?? "").isEmpty, let latitude = vehicle.latitude, let longitude = vehicle.longitude {
                    vehicle.address = await placeName(latitude: latitude, longitude: longitude)
                }
                await cachePicture(vehicle)
            }
            enriched.append(vehicle)
        }
        return enriched
    }

    private func fetchVehicleList(token: String, secrets: ZeehoSecrets) async -> [VehicleStatus] {
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/vehicle/list",
            token: token,
            secrets: secrets
        )
        guard ZeehoJSON.isOK(result.json) else { return [] }
        let data = result.json?["data"]
        let rows: [[String: Any]]
        if let list = data as? [Any] {
            rows = list.compactMap { $0 as? [String: Any] }
        } else if let dict = data as? [String: Any] {
            let nested = (dict["list"] as? [Any]) ?? (dict["records"] as? [Any]) ?? (dict["rows"] as? [Any]) ?? []
            rows = nested.compactMap { $0 as? [String: Any] }
        } else {
            return []
        }
        return rows.compactMap { row in
            let vin = nonempty(row["vinNo"]) ?? nonempty(row["vin"]) ?? nonempty(row["frameNo"])
            guard let vin else { return nil }
            return VehicleStatus(
                vehicleName: nonempty(row["vehicleName"]) ?? nonempty(row["vehicleType"]) ?? nonempty(row["deviceName"]),
                vehiclePicUrl: nonempty(row["vehiclePicUrl"]) ?? nonempty(row["vehicleScalePicUrl"]) ?? nonempty(row["pic"]),
                vin: vin
            )
        }
    }

    private func tireStatus(token: String, vin: String, secrets: ZeehoSecrets) async -> [String: Any]? {
        let query = "vinNo=\(percent(vin))&timePeriodType=1"
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/app/vehicle/tire/monitoring?\(query)",
            token: token,
            secrets: secrets,
            query: query
        )
        guard ZeehoJSON.isOK(result.json) else { return nil }
        return ZeehoJSON.object(result.json?["data"])
    }

    private func rideStatus(token: String, vin: String, secrets: ZeehoSecrets) async -> [String: Any]? {
        let query = "vinNo=\(percent(vin))"
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/homeRideInfo?\(query)",
            token: token,
            secrets: secrets,
            query: query
        )
        guard ZeehoJSON.isOK(result.json) else { return nil }
        return ZeehoJSON.object(result.json?["data"])
    }

    private func applyTire(_ data: [String: Any]?, to vehicle: inout VehicleStatus) {
        guard let data else { return }
        let list = (data["realTimeData"] as? [Any]) ?? (data["list"] as? [Any]) ?? []
        let rows = list.compactMap { $0 as? [String: Any] }
        func value(_ row: [String: Any]) -> String? {
            if let number = ZeehoJSON.double(row["pressure"] ?? row["tirePressure"] ?? row["value"]), number > 0 {
                return String(format: "%.1f", number)
            }
            return nonempty(row["pressureValue"])
        }
        func bar(_ row: [String: Any]) -> Double? {
            ZeehoJSON.double(row["pressure"] ?? row["tirePressure"] ?? row["value"]).flatMap { $0 > 0 ? $0 : nil }
        }
        let front = rows.first { ZeehoJSON.int($0["sensorPosition"]) == 1 }
        let rear = rows.first { ZeehoJSON.int($0["sensorPosition"]) == 2 }
        if let front, let rear, let a = value(front), let b = value(rear) {
            vehicle.pressureText = "\(a)/\(b)"
        } else if vehicle.pressureText == nil, let first = rows.first, let text = value(first) {
            vehicle.pressureText = text
        }
        // 解析前后轮 bar 数值，用于告警判断
        if let front { vehicle.frontBar = bar(front) }
        if let rear { vehicle.rearBar = bar(rear) }
        // 接口直接给的胎压异常标志
        if let warn = nonempty(data["tireWarn"] ?? data["tireWarning"] ?? data["warnState"])?.lowercased() {
            if warn == "1" || warn == "true" || warn == "warn" || warn == "warning" {
                vehicle.tireWarn = true
            }
        } else if let front, let rear, let fBar = bar(front), let rBar = bar(rear) {
            if fBar < VehicleWatchConsts.TIRE_BAR || rBar < VehicleWatchConsts.TIRE_BAR {
                vehicle.tireWarn = true
            }
        }
        let temps = rows.compactMap { ZeehoJSON.double($0["temperature"] ?? $0["tireTemp"]) }.filter { $0 > 0 }
        if let low = temps.min(), let high = temps.max(), vehicle.pressureText != nil {
            let temp = low == high ? String(format: "%.0f°C", low) : String(format: "%.0f–%.0f°C", low, high)
            vehicle.pressureText = "\(vehicle.pressureText!) · \(temp)"
        }
    }

    private func batteryStatus(token: String, vin: String, secrets: ZeehoSecrets) async -> [String: Any]? {
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/batteryInfo/\(percent(vin))",
            token: token,
            secrets: secrets
        )
        guard ZeehoJSON.isOK(result.json) else { return nil }
        return ZeehoJSON.object(result.json?["data"])
    }

    private func applyCharge(_ data: [String: Any]?, to vehicle: inout VehicleStatus) {
        guard let data else { return }
        // 充电状态
        let raw = nonempty(data["chargeStateStr"]) ?? nonempty(data["chargeState"]) ?? ""
        let label = chargeLabel(raw)
        if label != "未知" { vehicle.chargeText = label }
        // 电量兜底
        if let soc = ZeehoJSON.int(data["bmssoc"] ?? data["soc"] ?? data["batteryLevel"]) {
            vehicle.battery = soc
        }
        // 电压（data + nested batteryInfoList[0]）
        let nested = (data["batteryInfoList"] as? [Any])?.first as? [String: Any]
        let volts = ZeehoJSON.double(data["voltage"] ?? data["batteryVoltage"] ?? data["bmsVoltage"] ?? data["totalVoltage"])
            ?? ZeehoJSON.double(nested?["voltage"] ?? nested?["bmsVoltage"])
        if let volts, volts > 0 { vehicle.voltageText = String(format: "%.1f V", volts) }
        // 电流
        if let amps = ZeehoJSON.double(data["current"]), abs(amps) >= 0.05 {
            vehicle.currentText = String(format: "%.1f A", abs(amps))
        }
        // 功率：优先接口给的 power，否则 V*A 估算
        if let watts = ZeehoJSON.double(data["power"]) {
            if watts >= 1.0 { vehicle.powerText = "\(Int((watts * 10).rounded() / 10)) W" }
        } else if let volts, let amps = ZeehoJSON.double(data["current"]) {
            let w = volts * abs(amps)
            if w >= 1.0 { vehicle.powerText = "\(Int((w * 10).rounded() / 10)) W" }
        }
        // 预计充满时间
        if let eta = nonempty(data["expectFullTimeDescribe"]) {
            vehicle.etaText = eta
        } else if let minutes = fullMinutes(data) {
            vehicle.etaText = Self.minutesLabel(minutes)
        }
        // 已充电时长
        if let charged = nonempty(data["chargeTimeString"]) {
            vehicle.chargedText = charged
        }
    }

    private func fullMinutes(_ data: [String: Any]) -> Int? {
        if let minutes = ZeehoJSON.double(data["fullChargeTime"]), minutes > 0 {
            return Int((minutes * 10).rounded() / 10)
        }
        guard let seconds = ZeehoJSON.double(data["fullChargeTimeSecond"]), seconds > 0 else { return nil }
        return Int((seconds / 60 * 10).rounded() / 10)
    }

    static func minutesLabel(_ minutes: Int) -> String {
        if minutes <= 0 { return "—" }
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return m > 0 ? "\(h) 时 \(m) 分" : "\(h) 时" }
        return "\(m) 分"
    }

    private func chargeLabel(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = text.split(separator: ".").first.map(String.init) ?? text
        switch code {
        case "0", "未充电":
            return "未充电"
        case "1", "充电中":
            return "充电中"
        case "2", "充电完成", "已充满":
            return "充电完成"
        case "":
            return "未知"
        default:
            if text.contains("充电完成") || text.contains("已充满") { return "充电完成" }
            if text.contains("充电中") { return "充电中" }
            if text.contains("未充电") { return "未充电" }
            return "未知"
        }
    }

    private func monthRide(token: String, vin: String, secrets: ZeehoSecrets) async -> [String: Any]? {
        let query = "vinNo=\(percent(vin))&month=\(ZeehoClock.rideMonth())"
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/myRideInfo?\(query)",
            token: token,
            secrets: secrets,
            query: query
        )
        guard ZeehoJSON.isOK(result.json) else { return nil }
        return ZeehoJSON.object(result.json?["data"])
    }

    private func homePage(token: String, vin: String, secrets: ZeehoSecrets) async -> [String: Any]? {
        let identify = "zeehoios00000001"
        let query = "uniqueIdentify=\(identify)&phoneDeviceName=ios_\(identify)"
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/vehicleHomePageV2/\(percent(vin))?\(query)",
            token: token,
            secrets: secrets,
            query: query
        )
        guard ZeehoJSON.isOK(result.json) else { return nil }
        return ZeehoJSON.object(result.json?["data"])
    }

    private func applyRide(home: [String: Any]?, month: [String: Any]?, to vehicle: inout VehicleStatus) {
        let todayKey = ZeehoClock.todayString()
        let records = (month?["rideRecordList"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let today = records.first { dayKey($0["date"]) == todayKey }
        let todayKm = ZeehoJSON.double(today?["rideMileage"] ?? today?["mileage"])
        let todayMinutes = ZeehoJSON.int(today?["ridingTimeDayUnitMinute"] ?? today?["ridingTime"] ?? today?["rideTime"])
        let todaySpeed = ZeehoJSON.double(today?["maxSpeed"])
        var todayParts = [String(format: "%.1f km", todayKm ?? 0), "\(todayMinutes ?? 0) 分钟"]
        if let todaySpeed, todaySpeed > 0 { todayParts.append(String(format: "极速 %.0f", todaySpeed)) }
        vehicle.todayRideText = todayParts.joined(separator: " · ")

        var lastParts: [String] = []
        if let distance = ZeehoJSON.double(home?["lastRideMileage"]) {
            lastParts.append(String(format: "%.1f km", distance))
        }
        if let minutes = ZeehoJSON.int(home?["lastRidingTimeUnitMinute"]) {
            lastParts.append("\(minutes) 分钟")
        }
        if !lastParts.isEmpty { vehicle.lastRideText = lastParts.joined(separator: " · ") }
        if vehicle.mileageKm == nil, let total = ZeehoJSON.double(month?["rideMileageTotal"]) {
            vehicle.mileageKm = total
        }
    }

    private func dayKey(_ any: Any?) -> String {
        nonempty(any)?
            .replacingOccurrences(of: ".", with: "-")
            .prefix(10)
            .description ?? ""
    }

    private func appRequest(
        method: String,
        urlText: String,
        token: String,
        secrets: ZeehoSecrets,
        query: String = "",
        body: String = "",
        signBody: String? = nil
    ) async -> HTTPResult {
        let signed = ZeehoCrypto.appSign(
            appId: secrets.appId,
            appSecret: secrets.appSecret,
            query: query,
            body: signBody ?? body
        )
        guard let url = URL(string: urlText) else {
            return HTTPResult(status: 0, json: nil, error: "URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = actionTimeout(urlText)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if method != "GET" && method != "HEAD" {
            request.httpBody = Data(body.utf8)
        }
        request.setValue(secrets.appId, forHTTPHeaderField: "appId")
        request.setValue("2", forHTTPHeaderField: "interfaceversion")
        request.setValue(signed.nonce, forHTTPHeaderField: "nonce")
        request.setValue(signed.timestamp, forHTTPHeaderField: "timestamp")
        request.setValue(signed.sign, forHTTPHeaderField: "signature")
        request.setValue(signed.param, forHTTPHeaderField: "Cfmoto-X-Param")
        request.setValue(signed.sign, forHTTPHeaderField: "Cfmoto-X-Sign")
        request.setValue("0", forHTTPHeaderField: "Cfmoto-X-Sign-Type")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(ZeehoConfig.zeehoUA, forHTTPHeaderField: "User-Agent")
        request.setValue(ZeehoConfig.zeehoUA, forHTTPHeaderField: "x-app-info")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return await send(request, method: method, path: url.path)
    }

    private func actionTimeout(_ urlText: String) -> TimeInterval {
        urlText.contains("network/unlock") ? 25 : 15
    }

    private func commandMessage(_ result: HTTPResult, success: String) -> String {
        if ZeehoJSON.isOK(result.json) { return success }
        let message = ZeehoJSON.message(result.json)
        if !message.isEmpty { return message }
        if let error = result.error, !error.isEmpty { return error }
        if result.status == 0 { return "指令没有发出去" }
        return "指令失败 HTTP \(result.status)"
    }

    private func parseChargeOptions(_ json: [String: Any]?) -> [String] {
        guard ZeehoJSON.isOK(json) else { return [] }
        let data = json?["data"]
        let rows: [Any]
        if let list = data as? [Any] {
            rows = list
        } else if let dict = data as? [String: Any] {
            rows = (dict["list"] as? [Any]) ?? (dict["options"] as? [Any]) ?? []
        } else {
            return []
        }
        var values: [String] = []
        for row in rows {
            if let text = nonempty(row) {
                values.append(text)
            } else if let dict = row as? [String: Any] {
                let text = nonempty(dict["commandParam"]) ?? nonempty(dict["value"]) ?? nonempty(dict["power"]) ?? nonempty(dict["name"])
                if let text { values.append(text) }
            }
        }
        return Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    private func percent(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private func tapiGet(_ urlText: String, token: String, secrets: ZeehoSecrets) async -> HTTPResult {
        var last = HTTPResult(status: 0, json: nil, error: "未请求")
        for attempt in 0...1 {
            last = await tapiOnce(urlText, token: token, secrets: secrets)
            let retryable = last.status == 0 || last.status >= 500 || last.json == nil
            if !retryable || attempt == 1 || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return last
    }

    private func tapiOnce(_ urlText: String, token: String, secrets: ZeehoSecrets) async -> HTTPResult {
        let signed = ZeehoCrypto.tapiSign(url: urlText, appId: secrets.appId, appSecret: secrets.appSecret)
        guard let url = URL(string: urlText) else {
            return HTTPResult(status: 0, json: nil, error: "URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(secrets.appId, forHTTPHeaderField: "appId")
        request.setValue(signed.nonce, forHTTPHeaderField: "nonce")
        request.setValue(signed.timestamp, forHTTPHeaderField: "timestamp")
        request.setValue(signed.sign, forHTTPHeaderField: "signature")
        request.setValue(signed.param, forHTTPHeaderField: "Cfmoto-X-Param")
        request.setValue(signed.sign, forHTTPHeaderField: "Cfmoto-X-Sign")
        request.setValue("0", forHTTPHeaderField: "Cfmoto-X-Sign-Type")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("okhttp/4.9.2", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let path = url.path.isEmpty ? urlText : url.path
        return await send(request, method: "GET", path: path)
    }

    private func send(_ request: URLRequest, method: String, path: String) async -> HTTPResult {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            apiLog.info("\(method, privacy: .public) \(path, privacy: .public) -> \(status) \(ZeehoJSON.code(json), privacy: .public)")
            return HTTPResult(status: status, json: json, error: nil)
        } catch {
            apiLog.error("\(method, privacy: .public) \(path, privacy: .public) \(error.localizedDescription, privacy: .public)")
            return HTTPResult(status: 0, json: nil, error: error.localizedDescription)
        }
    }

    private func isTokenInvalid(_ result: HTTPResult) -> Bool {
        if result.status == 401 || result.status == 403 { return true }
        return ZeehoJSON.string(result.json?["error"]) == "invalid_token"
    }

    private func parseVehicles(_ json: [String: Any]?) -> [VehicleStatus] {
        guard ZeehoJSON.isOK(json) else { return [] }
        let data = json?["data"]
        let rows: [[String: Any]]
        if let list = data as? [Any] {
            rows = list.compactMap { $0 as? [String: Any] }
        } else if let dict = data as? [String: Any] {
            rows = [dict]
        } else {
            return []
        }
        return rows.map(parseVehicle)
    }

    private func mergeVehicle(_ base: VehicleStatus, _ extra: VehicleStatus) -> VehicleStatus {
        var merged = base
        if merged.address == nil { merged.address = extra.address }
        if merged.pressureText == nil { merged.pressureText = extra.pressureText }
        if merged.otaVersion == nil { merged.otaVersion = extra.otaVersion }
        if merged.signal == nil { merged.signal = extra.signal }
        if merged.locationTime == nil { merged.locationTime = extra.locationTime }
        if merged.battery == nil { merged.battery = extra.battery }
        if merged.rangeKm == nil { merged.rangeKm = extra.rangeKm }
        if merged.lockText == nil || merged.lockText == "未知" { merged.lockText = extra.lockText }
        if merged.chargeText == nil || merged.chargeText == "未知" { merged.chargeText = extra.chargeText }
        if merged.voltageText == nil { merged.voltageText = extra.voltageText }
        if merged.cushionText == nil { merged.cushionText = extra.cushionText }
        if merged.onlineText == nil { merged.onlineText = extra.onlineText }
        if merged.todayRideText == nil { merged.todayRideText = extra.todayRideText }
        if merged.lastRideText == nil { merged.lastRideText = extra.lastRideText }
        if merged.latitude == nil { merged.latitude = extra.latitude }
        if merged.longitude == nil { merged.longitude = extra.longitude }
        if merged.vehiclePicUrl == nil { merged.vehiclePicUrl = extra.vehiclePicUrl }
        return merged
    }

    private func parseVehicle(_ vehicle: [String: Any]) -> VehicleStatus {
        let lock = ZeehoJSON.string(vehicle["headLockState"])
        let charge = ZeehoJSON.string(vehicle["chargeState"])
        let location = ZeehoJSON.object(vehicle["location"])
        let battery = ZeehoJSON.double(vehicle["bmssoc"])
        let range = ZeehoJSON.double(vehicle["hmiRidableMile"])
        return VehicleStatus(
            vehicleName: nonempty(vehicle["vehicleName"]) ?? nonempty(vehicle["vehicleType"]),
            vehiclePicUrl: nonempty(vehicle["vehiclePicUrl"]) ?? nonempty(vehicle["vehicleScalePicUrl"]) ?? nonempty(vehicle["pic"]),
            battery: battery.map { Int($0) },
            rangeKm: range.map { Int($0) },
            mileageKm: ZeehoJSON.double(vehicle["totalRideMile"]),
            lockText: lock == "1" ? "已锁" : lock == "0" ? "未锁" : "未知",
            chargeText: chargeLabel(charge),
            rideState: nonempty(vehicle["rideState"]) ?? nonempty(vehicle["onlineStatus"]),
            signal: nonempty(vehicle["gsmRxLevValue"]),
            locationTime: nonempty(location["locationTime"]),
            address: nonempty(vehicle["address"]) ?? nonempty(location["address"]) ?? nonempty(location["formattedAddress"]) ?? deepString(vehicle, keys: ["address", "formattedAddress", "locationAddress"]),
            pressureText: pressureText(vehicle),
            otaVersion: nonempty(vehicle["otaVersion"]) ?? nonempty(vehicle["softwareVersion"]),
            vin: nonempty(vehicle["vin"]) ?? nonempty(vehicle["vehicleVin"]) ?? nonempty(vehicle["vinNo"]),
            voltageText: voltageText(vehicle),
            cushionText: cushionText(vehicle),
            onlineText: nonempty(vehicle["onlineStatus"]) ?? nonempty(vehicle["online"]) ?? nonempty(vehicle["netStatus"]),
            latitude: coordinate(vehicle, keys: ["latitude", "lat", "gpsY", "latitudeValue"], limit: 90),
            longitude: coordinate(vehicle, keys: ["longitude", "lng", "lon", "gpsX", "longitudeValue"], limit: 180)
        )
    }

    private func applyLocation(_ data: [String: Any]?, to vehicle: inout VehicleStatus) {
        guard let data else { return }
        if (vehicle.address ?? "").isEmpty {
            vehicle.address = nonempty(data["address"]) ?? deepString(data, keys: ["address", "formattedAddress", "locationAddress"])
        }
        if vehicle.latitude == nil {
            vehicle.latitude = coordinate(data, keys: ["latitude", "lat", "gpsY", "latitudeValue"], limit: 90)
        }
        if vehicle.longitude == nil {
            vehicle.longitude = coordinate(data, keys: ["longitude", "lng", "lon", "gpsX", "longitudeValue"], limit: 180)
        }
        if (vehicle.vehiclePicUrl ?? "").isEmpty {
            vehicle.vehiclePicUrl = nonempty(data["vehicleScalePicUrl"]) ?? nonempty(data["vehiclePicUrl"])
        }
    }

    private func placeName(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        var parts: [String] = []
        for piece in [mark.locality, mark.subLocality, mark.thoroughfare, mark.name] {
            guard let piece, !piece.isEmpty, !parts.contains(piece) else { continue }
            parts.append(piece)
        }
        let text = parts.joined()
        return text.isEmpty ? nil : text
    }

    private func cachePicture(_ vehicle: VehicleStatus) async {
        guard let vin = vehicle.vin, !vin.isEmpty,
              let raw = vehicle.vehiclePicUrl, let url = URL(string: raw), !raw.isEmpty else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count > 32 else { return }
        ZeehoFiles.saveVehicleImage(vin: vin, data: data)
    }

    private func coordinate(_ any: Any?, keys: [String], limit: Double) -> Double? {
        guard let text = deepString(any, keys: Set(keys)), let value = Double(text) else { return nil }
        guard value != 0, abs(value) <= limit else { return nil }
        return value
    }

    private func deepString(_ any: Any?, keys: Set<String>, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        if let dict = any as? [String: Any] {
            for key in keys {
                if let text = nonempty(dict[key]) { return text }
            }
            for value in dict.values {
                if let found = deepString(value, keys: keys, depth: depth + 1) { return found }
            }
        } else if let list = any as? [Any] {
            for item in list {
                if let found = deepString(item, keys: keys, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private func voltageText(_ vehicle: [String: Any]) -> String? {
        let value = ZeehoJSON.double(vehicle["voltage"] ?? vehicle["batteryVoltage"] ?? vehicle["bmsVoltage"] ?? vehicle["totalVoltage"])
        guard let value, value > 0 else { return nil }
        return String(format: "%.1f V", value)
    }

    private func cushionText(_ vehicle: [String: Any]) -> String? {
        let raw = nonempty(vehicle["cushionState"]) ?? nonempty(vehicle["cushionLockState"]) ?? nonempty(vehicle["seatLockState"])
        guard let raw else { return nil }
        if raw == "1" || raw == "已锁" { return "已锁" }
        if raw == "0" || raw == "未锁" { return "未锁" }
        return raw
    }

    private func pressureText(_ vehicle: [String: Any]) -> String? {
        let front = ZeehoJSON.double(vehicle["frontTirePressure"]) ?? ZeehoJSON.double(vehicle["frontPressure"])
        let rear = ZeehoJSON.double(vehicle["rearTirePressure"]) ?? ZeehoJSON.double(vehicle["rearPressure"])
        if let front, let rear, front > 0, rear > 0 {
            return String(format: "%.1f/%.1f", front, rear)
        }
        if let pressure = ZeehoJSON.double(vehicle["pressure"]), pressure > 0 {
            return String(format: "%.1f", pressure)
        }
        return nonempty(vehicle["pressureValue"])
    }

    private func nonempty(_ any: Any?) -> String? {
        let text = ZeehoJSON.string(any).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
