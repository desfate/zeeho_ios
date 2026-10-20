import CommonCrypto
import CryptoKit
import Foundation

enum ZeehoCrypto {
    /// H5：`md5(hex(sha1(query + body + appId=…&nonce=…&timestamp=… + secret)))`
    static func h5Sign(
        appId: String,
        appSecret: String,
        query: String,
        body: String,
        nonce: String = UUID().uuidString.lowercased(),
        timestamp: String = millis()
    ) -> (sign: String, param: String) {
        let param = "appId=\(appId)&nonce=\(nonce)&timestamp=\(timestamp)"
        let raw = "\(query)\(body)\(param)\(appSecret)"
        return (md5Hex(of: sha1Hex(of: raw)), param)
    }

    /// 2026 年车辆列表、车控和带 query 的读取：`md5(hex(sha1(query + body + param + secret)))`。
    static func appSign(
        appId: String,
        appSecret: String,
        query: String = "",
        body: String = ""
    ) -> (sign: String, param: String, nonce: String, timestamp: String) {
        let timestamp = millis()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let nonce = timestamp + String((0..<16).map { _ in alphabet.randomElement()! })
        let param = "appId=\(appId)&nonce=\(nonce)&timestamp=\(timestamp)"
        let raw = query + body + param + appSecret
        return (md5Hex(of: sha1Hex(of: raw)), param, nonce, timestamp)
    }

    /// 云端开关锁：AES-256-ECB，密钥是 32 位 ASCII。
    static func aes256ECBBase64(plain: String, key: String) -> String? {
        let keyBytes = Array(key.utf8)
        let plainBytes = Array(plain.utf8)
        guard keyBytes.count == 32 else { return nil }
        let capacity = plainBytes.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: capacity)
        var written = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
            keyBytes, keyBytes.count,
            nil,
            plainBytes, plainBytes.count,
            &output, capacity,
            &written
        )
        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(written)).base64EncodedString()
    }

    /// 原生 tapi：签名串是完整 URL（query 按 key 排序）接 param 和 secret，不含 body。
    static func tapiSign(url: String, appId: String, appSecret: String) -> (sign: String, param: String, nonce: String, timestamp: String) {
        let timestamp = millis()
        let compact = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let nonce = String(compact.prefix(16)) + timestamp
        let param = "appId=\(appId)&nonce=\(nonce)&timestamp=\(timestamp)"
        let pre = canonicalURL(url) + param + appSecret
        return (md5Hex(of: sha1Hex(of: pre)), param, nonce, timestamp)
    }

    static func sha1Hex(of string: String) -> String {
        Insecure.SHA1.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(of string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func selfCheck() {
        let raw = "appId=Sw5F9uJi&nonce=1d2763be-d699-4a72-bab0-3ab3203b34e4&timestamp=178944158960646870a8f678a09109468f5b0168818b91c292845"
        let sign = md5Hex(of: sha1Hex(of: raw))
        precondition(sign == "c8e32e6b71797aec98aeef67dfc7f5f4")
    }

    private static func millis() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1000))
    }

    private static func canonicalURL(_ url: String) -> String {
        guard let parts = URLComponents(string: url) else { return url }
        let scheme = parts.scheme ?? "https"
        let host = parts.host ?? ""
        var text = "\(scheme)://\(host)\(parts.path)"
        let items = parts.queryItems ?? []
        if !items.isEmpty {
            let pairs = items.map { ($0.name, $0.value ?? "") }.sorted { $0.0 < $1.0 }
            let query = pairs.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
            text += "?\(query)"
        }
        return text
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
