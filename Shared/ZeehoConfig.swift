import Foundation

/// 公开客户端的接口签名参数，不是登录 Token。
/// 与 Mac 版 `config/local.example.json` 相同。2026-10-11 起 H5 签到改走
/// `/cfmotoservermine/H5/`，密钥也换成了 `h5AppId` 这一套；车辆接口仍用 tapi 密钥。
struct ZeehoSecrets: Codable, Equatable, Sendable {
    var baseURL: String
    var h5AppId: String
    var h5AppSecret: String
    var appId: String
    var appSecret: String
    var vehicleAesKey: String

    static let builtIn = ZeehoSecrets(
        baseURL: "https://h5.zeehoev.com",
        h5AppId: "AiTXmBrm",
        h5AppSecret: "70c2c7458ab88ca9504ad0521f170075bc91f2f7",
        appId: "Sw5F9uJi",
        appSecret: "46870a8f678a09109468f5b0168818b91c292845",
        vehicleAesKey: "ce2cd7cb57124c1349dd8543bf6fd31d"
    )

    init(baseURL: String, h5AppId: String, h5AppSecret: String, appId: String, appSecret: String, vehicleAesKey: String) {
        self.baseURL = baseURL
        self.h5AppId = h5AppId
        self.h5AppSecret = h5AppSecret
        self.appId = appId
        self.appSecret = appSecret
        self.vehicleAesKey = vehicleAesKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self.builtIn
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? base.baseURL
        h5AppId = try container.decodeIfPresent(String.self, forKey: .h5AppId) ?? base.h5AppId
        h5AppSecret = try container.decodeIfPresent(String.self, forKey: .h5AppSecret) ?? base.h5AppSecret
        appId = try container.decodeIfPresent(String.self, forKey: .appId) ?? base.appId
        appSecret = try container.decodeIfPresent(String.self, forKey: .appSecret) ?? base.appSecret
        vehicleAesKey = try container.decodeIfPresent(String.self, forKey: .vehicleAesKey) ?? base.vehicleAesKey
    }

    func filled() -> ZeehoSecrets {
        let base = Self.builtIn
        func pick(_ value: String, _ fallback: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }
        return ZeehoSecrets(
            baseURL: pick(baseURL, base.baseURL),
            h5AppId: pick(h5AppId, base.h5AppId),
            h5AppSecret: pick(h5AppSecret, base.h5AppSecret),
            appId: pick(appId, base.appId),
            appSecret: pick(appSecret, base.appSecret),
            vehicleAesKey: pick(vehicleAesKey, base.vehicleAesKey)
        )
    }
}

enum ZeehoConfig {
    /// 界面最下方显示的构建号。每次需要确认手机是否装上新代码时改这里。
    static let build = "2026-10-22.5"
    static let vehicleURL = "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/vehicleHomePage/"
    static let webUA = "Mozilla/5.0 (Linux; Android 9; SM-G9500 Build/PPR1.180610.011; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/136.0.7103.125 Mobile Safari/537.36 Zeeho/3.0.4 (samsung SM-G9500 Build/9)"
    static let zeehoUA = "MOBILE|Android|9|ZEEHO_APP|3.0.4|samsung SM-G9500|360*740|34cd9884-8171-41e8-a965-b10d042cae4f|4g|AndroidOS"

    static func current() -> ZeehoSecrets {
        let url = ZeehoFiles.directory().appendingPathComponent("secrets.json")
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(ZeehoSecrets.self, from: data) else {
            return .builtIn
        }
        return saved.filled()
    }

    static func save(_ secrets: ZeehoSecrets) {
        let url = ZeehoFiles.directory().appendingPathComponent("secrets.json")
        let normalized = secrets.filled()
        if normalized == .builtIn {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder.zeeho.encode(normalized) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var zeeho: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
