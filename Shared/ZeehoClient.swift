import CoreLocation
import Foundation
import os

private let apiLog = Logger(subsystem: "com.jieyu.zeeho.signin", category: "api")

struct HTTPResult {
    var status: Int
    var json: [String: Any]?
    var error: String?
}

enum ZeehoJSON {
    static func object(_ any: Any?) -> [String: Any] {
        any as? [String: Any] ?? [:]
    }

    static func dictionary(_ any: Any?) -> [String: Any]? {
        if let dict = any as? [String: Any] { return dict }
        guard let raw = any as? NSDictionary else { return nil }
        var dict: [String: Any] = [:]
        for (key, value) in raw {
            guard let key = key as? String else { continue }
            dict[key] = value
        }
        return dict
    }

    static func list(_ any: Any?) -> [Any]? {
        if let list = any as? [Any] { return list }
        if let list = any as? NSArray { return list.map { $0 } }
        return nil
    }

    static func firstObject(_ any: Any?) -> [String: Any]? {
        if let dict = dictionary(any), any as? [Any] == nil, any as? NSArray == nil { return dict }
        return list(any)?.compactMap { dictionary($0) }.first
    }

    static func payload(_ any: Any?) -> [String: Any]? {
        if let text = any as? String,
           let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            return payload(parsed)
        }
        if let dict = dictionary(any) { return dict }
        return list(any)?.compactMap { dictionary($0) }.first
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
            let uid = nonempty(data["userId"])
                ?? nonempty(data["bindingUserId"])
                ?? nonempty(data["uid"])
                ?? nonempty(data["memberId"])
                ?? nonempty(data["accountId"])
                ?? nonempty(data["id"])
            if !name.isEmpty { status.nickName = name }
            if !avatar.isEmpty { status.avatar = avatar }
            if let uid { status.userId = uid }
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
            await attachInbox(token: token, secrets: secrets, status: &status)
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
        await attachInbox(token: token, secrets: secrets, status: &status)
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
            let point = await dbpoint(token: token, vin: vin, secrets: secrets, functionCode: "LOUDLY_SEARCH_CAR", type: "LOW")
            let control = await appRequest(
                method: "PUT",
                urlText: "\(base)/vehicleInfo/control/\(vin)",
                token: token,
                secrets: secrets
            )
            let chosen = ZeehoJSON.isOK(point.json) ? point : control
            return commandMessage(chosen, success: "鸣笛闪灯指令已下发")
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
            let mode = action == .unlock ? "ON" : "OFF"
            let point = await dbpoint(token: token, vin: vin, secrets: secrets, functionCode: "ON_AND_OFF", type: mode)
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
            let chosen = ZeehoJSON.isOK(point.json) ? result : point
            return commandMessage(chosen, success: action == .unlock ? "云端开锁指令已下发" : "云端关锁指令已下发")
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

    func runCommunityTasks(token: String, userId: String, secrets: ZeehoSecrets, prefs: ZeehoPointsPrefs) async -> (ok: Bool, text: String) {
        defer { session.finishTasksAndInvalidate() }
        guard !userId.isEmpty else { return (false, "没有账号 ID，积分任务未执行") }
        let tasks = await tapi(
            method: "GET",
            path: "/v1.0/mine/cfmotoservermine/integral/getByUserId",
            token: token,
            secrets: secrets,
            query: "userId=\(percent(userId))"
        )
        if isTokenInvalid(tasks) { return (false, "登录态已失效") }
        guard ZeehoJSON.isOK(tasks.json) else { return (false, "任务列表读取失败：\(failureText(tasks))") }
        let list = (ZeehoJSON.object(tasks.json?["data"])["ps0003_01_002_VOList"] as? [Any]) ?? []
        var notes = ""
        var postId = ""
        var published = false
        var done = 0
        var failed = 0
        var authFailed = false
        for item in list {
            if authFailed { break }
            let row = item as? [String: Any] ?? [:]
            let action = pointsAction(ZeehoJSON.string(row["code"]))
            if action.isEmpty || ZeehoJSON.string(row["completeFlag"]) == "0" { continue }
            var target = postId
            if action == "post" {
                target = await publishPost(token: token, secrets: secrets, content: prefs.content, userId: userId, notes: &notes)
                if target.isEmpty { failed += 1 } else {
                    postId = target
                    published = true
                    done += 1
                }
            } else {
                if target.isEmpty { target = await myFirstPost(token: token, userId: userId, secrets: secrets) }
                if target.isEmpty {
                    target = await publishPost(token: token, secrets: secrets, content: prefs.content, userId: userId, notes: &notes)
                    if !target.isEmpty {
                        postId = target
                        published = true
                    }
                } else {
                    postId = target
                }
                if target.isEmpty {
                    failed += 1
                } else if action == "like" {
                    let liked = await tapi(
                        method: "POST",
                        path: "/v1.0/social/cfmotoserversocial/socialCommu/likeFavoriteInfo",
                        token: token,
                        secrets: secrets,
                        body: "{\"postId\":\(jsonQuote(target)),\"kindFlag\":\"0\"}"
                    )
                    if isTokenInvalid(liked) {
                        authFailed = true
                        notes += "；登录态失效"
                    } else if ZeehoJSON.isOK(liked.json) {
                        done += 1
                    } else {
                        failed += 1
                        notes += "；点赞失败：\(failureText(liked))"
                    }
                } else {
                    let shared = await tapi(
                        method: "PUT",
                        path: "/v1.0/social/cfmotoserversocial/article/share/\(percent(target))",
                        token: token,
                        secrets: secrets
                    )
                    if isTokenInvalid(shared) {
                        authFailed = true
                        notes += "；登录态失效"
                    } else if ZeehoJSON.isOK(shared.json) {
                        done += 1
                        _ = await tapi(method: "GET", path: "/v1.0/mine/cfmotoservermine/integral/adjustByShare", token: token, secrets: secrets)
                    } else {
                        failed += 1
                        notes += "；分享失败：\(failureText(shared))"
                    }
                }
            }
            if prefs.gapMs > 0 {
                let gap = min(max(prefs.gapMs, 0), 5_000)
                try? await Task.sleep(nanoseconds: UInt64(gap) * 1_000_000)
            }
        }
        if published, prefs.deleteAfter, !postId.isEmpty {
            let query = "articleId=\(percent(postId))&postType=1"
            let removed = await tapi(
                method: "DELETE",
                path: "/v1.0/social/cfmotoserversocial/commonArticle/deleteArticle",
                token: token,
                secrets: secrets,
                query: query
            )
            if !ZeehoJSON.isOK(removed.json) { notes += "；删除动态失败" }
        }
        let summary: String
        if notes.isEmpty, done == 0, failed == 0 {
            summary = "积分任务已完成"
        } else {
            var text = notes
            text += " · 完成 \(done) 项"
            if failed > 0 { text += "，失败 \(failed) 项" }
            summary = text.trimmingCharacters(in: CharacterSet(charactersIn: "· ")).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (!authFailed && failed == 0, summary)
    }

    func loadVehicles(token: String, secrets: ZeehoSecrets) async -> [VehicleStatus] {
        defer { session.finishTasksAndInvalidate() }
        return await fetchVehicles(token: token, secrets: secrets)
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
                let home = await homePage(token: token, vin: vin, secrets: secrets)
                applyHome(home, to: &vehicle)
                applyCharge(await batteryStatus(token: token, vin: vin, secrets: secrets), to: &vehicle)
                if (vehicle.voltageText ?? "").isEmpty {
                    await fillVoltage(token: token, vin: vin, secrets: secrets, vehicle: &vehicle)
                }
                applyTire(await tireStatus(token: token, vin: vin, secrets: secrets), to: &vehicle)
                let ride = await rideStatus(token: token, vin: vin, secrets: secrets)
                let month = await monthRide(token: token, vin: vin, secrets: secrets)
                applyRide(home: home, ride: ride, month: month, to: &vehicle)
                if (vehicle.address ?? "").isEmpty, let latitude = vehicle.latitude, let longitude = vehicle.longitude {
                    vehicle.address = await placeName(latitude: latitude, longitude: longitude)
                }
                vehicle.vin = vin
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
        let query = "sensorType=EXTERNAL&vinNo=\(percent(vin))"
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
        let front = rows.first { ZeehoJSON.int($0["sensorPosition"]) == 1 }
        let rear = rows.first { ZeehoJSON.int($0["sensorPosition"]) == 2 }
        if let front, let rear, let a = value(front), let b = value(rear) {
            vehicle.pressureText = "\(a)/\(b)"
        } else if vehicle.pressureText == nil, let first = rows.first, let text = value(first) {
            vehicle.pressureText = text
        }
        let temps = rows.compactMap { ZeehoJSON.double($0["temperature"] ?? $0["tireTemp"]) }.filter { $0 > 0 }
        if let low = temps.min(), let high = temps.max(), vehicle.pressureText != nil {
            let temp = low == high ? String(format: "%.0f°C", low) : String(format: "%.0f–%.0f°C", low, high)
            vehicle.pressureText = "\(vehicle.pressureText!) · \(temp)"
        }
        func bar(_ row: [String: Any]?) -> Double? {
            guard let row else { return nil }
            return ZeehoJSON.double(row["tirePressure"] ?? row["pressure"] ?? row["value"]).flatMap { $0 > 0 ? $0 : nil }
        }
        vehicle.frontBar = bar(front)
        vehicle.rearBar = bar(rear)
        let warned = rows.contains { row in
            guard let flag = ZeehoJSON.int(row["warningType"]) else { return false }
            return flag != 0
        }
        let lowBar = [vehicle.frontBar, vehicle.rearBar].compactMap { $0 }.contains { $0 > 0 && $0 < 1.9 }
        vehicle.tireWarn = warned || lowBar
    }

    private func batteryStatus(token: String, vin: String, secrets: ZeehoSecrets) async -> [String: Any]? {
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/batteryInfo/\(percent(vin))",
            token: token,
            secrets: secrets
        )
        guard ZeehoJSON.isOK(result.json) else { return nil }
        return ZeehoJSON.payload(result.json?["data"])
    }

    private func widgetStatus(token: String, vin: String, secrets: ZeehoSecrets) async -> [String: Any]? {
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/vehicle/widgets/\(percent(vin))",
            token: token,
            secrets: secrets
        )
        guard ZeehoJSON.isOK(result.json) else { return nil }
        return ZeehoJSON.payload(result.json?["data"])
    }

    private func snapshotStatus(token: String, vin: String, secrets: ZeehoSecrets) async -> [String: Any]? {
        let query = "vinNo=\(percent(vin))"
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/app/vehicles/properties/snapshots?\(query)",
            token: token,
            secrets: secrets,
            query: query
        )
        guard ZeehoJSON.isOK(result.json) else { return nil }
        return ZeehoJSON.payload(result.json?["data"])
    }

    private func fillVoltage(token: String, vin: String, secrets: ZeehoSecrets, vehicle: inout VehicleStatus) async {
        let sources = [
            await widgetStatus(token: token, vin: vin, secrets: secrets),
            await snapshotStatus(token: token, vin: vin, secrets: secrets),
        ]
        for source in sources {
            guard let source, let volts = chargeVolts(source), volts > 0 else { continue }
            vehicle.voltageText = String(format: "%.1f V", volts)
            return
        }
    }

    private func applyCharge(_ data: [String: Any]?, to vehicle: inout VehicleStatus) {
        guard let data else { return }
        let raw = nonempty(data["chargeStateStr"]) ?? nonempty(data["chargeState"]) ?? ""
        let label = chargeLabel(raw)
        if label != "未知" {
            vehicle.chargeText = label
        } else if VehicleRoster.flagOn(data["whetherChargeState"]) {
            vehicle.chargeText = "充电中"
        }
        if let soc = ZeehoJSON.int(data["bmssoc"] ?? data["soc"] ?? data["batteryLevel"]) {
            vehicle.battery = soc
        }
        let volts = chargeVolts(data)
        if let volts, volts > 0 {
            vehicle.voltageText = String(format: "%.1f V", volts)
        }
        if let amps = ZeehoJSON.double(data["current"]), abs(amps) >= 0.05 {
            vehicle.currentText = String(format: "%.1f A", abs(amps))
        }
        let amps = ZeehoJSON.double(data["current"])
        let watts = ZeehoJSON.double(data["power"]) ?? volts.flatMap { v in amps.map { v * abs($0) } }
        if let watts, watts >= 1 {
            vehicle.powerText = "\(Int(watts.rounded())) W"
        }
        if let eta = nonempty(data["expectFullTimeDescribe"]) {
            vehicle.etaText = eta
        } else if let minutes = fullMinutes(data) {
            vehicle.etaText = VehicleRoster.minutesLabel(minutes)
        }
        if let charged = nonempty(data["chargeTimeString"]) {
            vehicle.chargedText = charged
        }
    }

    private func chargeVolts(_ data: [String: Any]) -> Double? {
        let keys = ["voltage", "batteryVoltage", "bmsVoltage", "totalVoltage", "batteryTotalVoltage", "batVoltage", "batteryVol"]
        if let value = positive(data, keys: keys) { return value }
        if let nested = ZeehoJSON.firstObject(data["batteryInfoList"]) ?? ZeehoJSON.dictionary(data["batteryInfo"]),
           let value = positive(nested, keys: keys) {
            return value
        }
        if let value = deepVolt(data, keys: keys, depth: 0) { return value }
        return iotVolt(data)
    }

    private func deepVolt(_ any: Any?, keys: [String], depth: Int) -> Double? {
        guard depth < 6 else { return nil }
        if let dict = ZeehoJSON.dictionary(any) {
            if depth > 0, let value = positive(dict, keys: keys) { return value }
            if let value = iotVolt(dict) { return value }
            for key in dict.keys.sorted() where !keys.contains(key) {
                if let found = deepVolt(dict[key], keys: keys, depth: depth + 1) { return found }
            }
        } else if let list = ZeehoJSON.list(any) {
            for item in list {
                if let found = deepVolt(item, keys: keys, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private func iotVolt(_ data: [String: Any]) -> Double? {
        let lists = ["iotProperties", "properties", "propertyList", "vehicleProperties"]
        let rows = lists.compactMap { ZeehoJSON.list(data[$0]) }.flatMap { $0 }
        guard !rows.isEmpty else { return nil }
        for item in rows {
            guard let row = ZeehoJSON.dictionary(item) else { continue }
            let identify = ZeehoJSON.string(row["identify"] ?? row["propertyCode"] ?? row["code"] ?? row["key"]).lowercased()
            guard identify.contains("volt"), !identify.contains("status"), !identify.contains("flag") else { continue }
            let raw = row["value"] ?? row["propertyValue"] ?? row["propValue"] ?? row["val"]
            if let value = number(raw), let volts = packVolts(value) { return volts }
        }
        return nil
    }

    private func positive(_ data: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = number(data[key]), let volts = packVolts(value) { return volts }
        }
        for key in data.keys.sorted() {
            let name = key.lowercased()
            guard name.contains("volt"), !name.contains("status"), !name.contains("flag") else { continue }
            if let value = number(data[key]), let volts = packVolts(value) { return volts }
        }
        return nil
    }

    private func number(_ any: Any?) -> Double? {
        if let value = ZeehoJSON.double(any) { return value }
        let digits = ZeehoJSON.string(any).filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }

    private func packVolts(_ raw: Double) -> Double? {
        if raw >= 20, raw <= 200 { return raw }
        if raw > 200, raw < 2000 {
            let scaled = raw / 10
            if scaled >= 20, scaled <= 200 { return scaled }
        }
        if raw >= 2000, raw <= 200_000 {
            let scaled = raw / 1000
            if scaled >= 20, scaled <= 200 { return scaled }
        }
        return nil
    }

    private func fullMinutes(_ data: [String: Any]) -> Int? {
        if let minutes = ZeehoJSON.double(data["fullChargeTime"]), minutes > 0 {
            return Int(minutes.rounded())
        }
        guard let seconds = ZeehoJSON.double(data["fullChargeTimeSecond"]), seconds > 0 else { return nil }
        return Int((seconds / 60).rounded())
    }

    func fillInbox(token: String, secrets: ZeehoSecrets, status: inout SigninStatus) async {
        defer { session.finishTasksAndInvalidate() }
        await attachInbox(token: token, secrets: secrets, status: &status)
    }

    // MARK: - Inbox

    private func attachInbox(token: String, secrets: ZeehoSecrets, status: inout SigninStatus) async {
        guard let uid = status.userId, !uid.isEmpty else { return }
        let query = "messageKind=3&page=1&pageSize=1&userId=\(percent(uid))"
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/mine/cfmotoservermine/app/Message/list_v2?\(query)",
            token: token,
            secrets: secrets,
            query: query
        )
        guard ZeehoJSON.isOK(result.json) else { return }
        let data = ZeehoJSON.object(result.json?["data"])
        let list = data["messageVOList"] as? [Any]
        let first = list?.first as? [String: Any]
        status.unread = ZeehoJSON.int(data["noRead"]) ?? 0
        status.latestMessage = nonempty(first?["content"]) ?? nonempty(first?["msgTitle"])
        status.latestMessageId = nonempty(first?["messageId"]) ?? nonempty(first?["id"])
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
        return ZeehoJSON.payload(result.json?["data"])
    }

    private func homePage(token: String, vin: String, secrets: ZeehoSecrets) async -> [String: Any]? {
        let result = await appRequest(
            method: "GET",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/vehicleHomePageV2/\(percent(vin))",
            token: token,
            secrets: secrets
        )
        guard ZeehoJSON.isOK(result.json) else { return nil }
        return ZeehoJSON.payload(result.json?["data"])
    }

    private func applyHome(_ data: [String: Any]?, to vehicle: inout VehicleStatus) {
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
        if (vehicle.lockText ?? "").isEmpty || vehicle.lockText == "未知", data["headLockState"] != nil {
            vehicle.lockText = VehicleRoster.flagOn(data["headLockState"]) ? "已锁" : "未锁"
        }
        if (vehicle.cushionText ?? "").isEmpty { vehicle.cushionText = cushionText(data) }
        if (vehicle.onlineText ?? "").isEmpty {
            vehicle.onlineText = nonempty(data["onlineStatus"]) ?? nonempty(data["online"])
        }
        if let label = VehicleRoster.onlineLabel(vehicle.onlineText) { vehicle.onlineText = label }
        if (vehicle.rideState ?? "").isEmpty { vehicle.rideState = nonempty(data["rideState"]) }
        if (vehicle.signal ?? "").isEmpty { vehicle.signal = nonempty(data["gsmRxLevValue"]) }
        if (vehicle.otaVersion ?? "").isEmpty {
            vehicle.otaVersion = nonempty(data["otaVersion"]) ?? nonempty(data["softwareVersion"])
        }
        if (vehicle.locationTime ?? "").isEmpty {
            let location = ZeehoJSON.object(data["location"])
            vehicle.locationTime = nonempty(location["locationTime"]) ?? nonempty(data["locationTime"])
        }
        if vehicle.mileageKm == nil { vehicle.mileageKm = ZeehoJSON.double(data["totalRideMile"]) }
        if vehicle.rangeKm == nil { vehicle.rangeKm = ZeehoJSON.int(data["hmiRidableMile"]) }
        applyCharge(data, to: &vehicle)
        if (vehicle.pressureText ?? "").isEmpty {
            if let bar = ZeehoJSON.double(data["pressure"] ?? data["frontTirePressure"]), bar > 0.05 {
                vehicle.pressureText = String(format: "%.1f", bar)
                vehicle.frontBar = bar
            }
        }
    }

    private func applyRide(home: [String: Any]?, ride: [String: Any]?, month: [String: Any]?, to vehicle: inout VehicleStatus) {
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
        for source in [home, ride].compactMap({ $0 }) {
            if !lastParts.isEmpty { break }
            if let distance = ZeehoJSON.double(source["lastRideMileage"] ?? source["rideMileage"]) {
                lastParts.append(String(format: "%.1f km", distance))
            }
            if let minutes = ZeehoJSON.int(source["lastRidingTimeUnitMinute"] ?? source["ridingTimeUnitMinute"]) {
                lastParts.append("\(minutes) 分钟")
            }
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

    func appRequest(
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

    /// 几何面板 dbpoint/send：控车埋点后再发正式指令。
    private func dbpoint(
        token: String,
        vin: String,
        secrets: ZeehoSecrets,
        functionCode: String,
        type: String? = nil
    ) async -> HTTPResult {
        var paramDict: [String: Any] = ["vinNo": vin, "functionCode": functionCode]
        if let type, !type.isEmpty { paramDict["type"] = type }
        let paramStr = paramDict.map { "\"\($0)\":\"\($1)\"" }.joined(separator: ",")
        let body = "{\"eventId\":\(0x2d6f),\"param\":\"\(paramStr)\",\"uuid\":\"\",\"zeehoParamTypeBO\":null}"
        return await appRequest(
            method: "POST",
            urlText: "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/dbpoint/send",
            token: token,
            secrets: secrets,
            body: body
        )
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

    private func tapi(
        method: String,
        path: String,
        token: String,
        secrets: ZeehoSecrets,
        query: String = "",
        body: String = ""
    ) async -> HTTPResult {
        let url = query.isEmpty ? "https://tapi.zeehoev.com\(path)" : "https://tapi.zeehoev.com\(path)?\(query)"
        return await appRequest(method: method, urlText: url, token: token, secrets: secrets, query: query, body: body)
    }

    private func publishPost(token: String, secrets: ZeehoSecrets, content: String, userId: String, notes: inout String) async -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "今日打卡" : content.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = "{\"postSubInfo\":{\"topicList\":[]},\"topicid\":\"\",\"postcontent\":\(jsonQuote(text))}"
        let posted = await tapi(method: "POST", path: "/v1.0/social/cfmotoserversocial/commonArticle", token: token, secrets: secrets, body: body)
        guard ZeehoJSON.isOK(posted.json) else {
            notes += "；发帖失败：\(failureText(posted))"
            return ""
        }
        let id = await myFirstPost(token: token, userId: userId, secrets: secrets)
        if id.isEmpty { notes += "；发帖成功但取不到动态 ID" }
        return id
    }

    private func myFirstPost(token: String, userId: String, secrets: ZeehoSecrets) async -> String {
        let listed = await tapi(
            method: "GET",
            path: "/v1.0/social/cfmotoserversocial/community/mineArticleInfo",
            token: token,
            secrets: secrets,
            query: "userId=\(percent(userId))"
        )
        guard ZeehoJSON.isOK(listed.json) else { return "" }
        let data = listed.json?["data"]
        var first: [String: Any]?
        if let list = data as? [Any] {
            first = list.first as? [String: Any]
        } else if let dict = data as? [String: Any] {
            let nested = (dict["list"] as? [Any]) ?? (dict["records"] as? [Any]) ?? []
            first = nested.first as? [String: Any]
        } else {
            first = nil
        }
        guard let first else { return "" }
        return nonempty(first["tuuid"]) ?? nonempty(first["id"]) ?? nonempty(first["articleId"]) ?? ""
    }

    private func pointsAction(_ code: String) -> String {
        switch code {
        case "1023": return "post"
        case "1026": return "like"
        case "1024": return "share"
        default: return ""
        }
    }

    private func jsonQuote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x5C: out += "\\\\"
            case 0x22: out += "\\\""
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    private func failureText(_ result: HTTPResult) -> String {
        let message = ZeehoJSON.message(result.json)
        if !message.isEmpty { return message }
        if let error = result.error, !error.isEmpty { return error }
        return "HTTP \(result.status)"
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
        if merged.currentText == nil { merged.currentText = extra.currentText }
        if merged.powerText == nil { merged.powerText = extra.powerText }
        if merged.etaText == nil { merged.etaText = extra.etaText }
        if merged.chargedText == nil { merged.chargedText = extra.chargedText }
        if merged.frontBar == nil { merged.frontBar = extra.frontBar }
        if merged.rearBar == nil { merged.rearBar = extra.rearBar }
        merged.tireWarn = merged.tireWarn || extra.tireWarn
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
        guard let value = chargeVolts(vehicle), value > 0 else { return nil }
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

// MARK: - 盲盒

/// 盲盒 / 补领结果
struct ZeehoBonusClaim: Equatable {
    var text: String
    var prizeName: String
    var integral: String
    var type: String
}

extension ZeehoClient {
    /// 签到之后的盲盒 + 补领。失败只记原因，不影响已经完成的签到。
    func claimBonus(token: String, secrets: ZeehoSecrets) async -> ZeehoBonusClaim {
        async let lottery = appRequest(
            method: "POST",
            urlText: "https://tapi.zeehoev.com/cfmotoservermine/H5/signin/lottery",
            token: token,
            secrets: secrets,
            body: ""
        )
        async let extra = appRequest(
            method: "POST",
            urlText: "https://tapi.zeehoev.com/cfmotoservermine/H5/signin/supplementPrize",
            token: token,
            secrets: secrets,
            body: ""
        )
        let (lotteryResult, extraResult) = await (lottery, extra)

        func line(_ name: String, _ result: HTTPResult) -> String {
            if ZeehoJSON.isOK(result.json) { return "\(name)：\(ZeehoJSON.message(result.json).isEmpty ? "已请求" : ZeehoJSON.message(result.json))" }
            let why = ZeehoJSON.message(result.json).isEmpty ? (result.error ?? "HTTP \(result.status)") : ZeehoJSON.message(result.json)
            return "\(name) 失败：\(why)"
        }

        let prize = prizeOf(lotteryResult.json)
        return ZeehoBonusClaim(
            text: "\(line("盲盒", lotteryResult))\n\(line("补领", extraResult))",
            prizeName: prize?.0 ?? "",
            integral: prize?.1 ?? "",
            type: prize?.2 ?? ""
        )
    }
}

private func prizeOf(_ json: [String: Any]?) -> (String, String, String)? {
    guard ZeehoJSON.isOK(json), let data = ZeehoJSON.object(json?["data"]) as [String: Any]? else { return nil }
    func pick(_ keys: String...) -> String {
        for k in keys {
            let s = ZeehoJSON.string(data[k]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        return ""
    }
    let name = pick("prizeName", "name", "awardName", "goodsName", "title")
    guard !name.isEmpty else { return nil }
    return (name, pick("integral", "score", "points"), pick("type", "prizeType"))
}
