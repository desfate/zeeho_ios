//
//  ZeehoCapture.swift
//  ZeehoSignin
//
//  Token 自动抓取：自签 CA + NEPacketTunnelProvider 透明代理官方极核 App 流量。
//  与 Android ZeehoCapture + ZeehoCaptureProxy + ZeehoCaptureService 对齐。
//
//  ⚠️ 完整的 TLS MITM 逻辑需要 Network Extension 独立 target（ZeehoTunnel），
//     见同目录下 ZeehoTunnel.swift。本文件负责 App 端：生成自签 CA、发起 VPN、
//     轮询 Tunnel 消息、抓到 Token 后自动导入账号。
//

import Foundation
import NetworkExtension
import Security
import SecurityInterface

// MARK: - 状态机

/// 抓取生命周期状态，持久化到 UserDefaults，供 UI 展示当前引导步骤。
enum CaptureState: String, Codable, Sendable {
    case idle
    case requestingVPN     // 等待用户点"允许 VPN 配置"
    case waiting           // VPN 已建立，等待 Tunnel Extension 抓到 Token
    case running           // Tunnel Extension 正在抓
    case success
    case error
    case denied            // 用户拒绝了 VPN 或 CA 安装被取消
}

enum CaptureStep: Sendable {
    case installCA         // 需要用户先安装并信任自签 CA 证书（一次性）
    case requestVPN        // 点击"开始"触发系统 VPN 授权弹窗
    case waitingLogin      // VPN 已连上，打开官方极核 App 登录
    case done(String, String)  // 抓到 token + uid
    case failed(String)
    case idle
}

struct CaptureResult: Codable, Equatable, Sendable {
    var state: CaptureState = .idle
    var token: String? = nil
    var uid: String? = nil
    var error: String? = nil
    var updatedAtUnix: TimeInterval = 0
}

struct CaptureStats: Codable, Equatable, Sendable {
    var connections: Int = 0
    var mitmOK: Int = 0
    var mitmFail: Int = 0
    var captured: Int = 0

    var needsCAHint: Bool { connections > 0 && mitmOK == 0 && captured == 0 }
}

// MARK: - 常量

enum CaptureConsts {
    /// Tunnel Extension 的 bundle id，必须和 Network Extension target 的 Info.plist 里 NSExtension 的 bundle id 一致。
    static let tunnelBundleID = "com.jieyu.zeeho.signin.ZeehoTunnel"
    /// Tunnel Extension 在 Info.plist 的 NSExtension 里声明的 NEProvider 类名。
    static let providerClassName = "ZeehoTunnel.ZeehoTunnelProvider"
    /// VPN 名称（会显示在系统 VPN 设置里）。
    static let vpnTitle = "极核 Token 抓取"
    /// 只代理官方极核 App（iOS 用 App Store 沙箱，每个 App 有不同 bundle id）。
    static let officialBundleID = "com.cfmoto.zeehoev" // 可能因包名变化需要调整
    /// VPN 内网网段。
    static let vpnAddress = "10.99.99.1"
    static let vpnSubnet = "255.255.255.0"
    static let tunnelMTU = 1500
    /// 只给 h5.zeehoev.com 走隧道（MITM host）。
    static let mitmHost = "h5.zeehoev.com"
    /// Tunnel Extension 和 App 之间的通讯 App Group。
    static let appGroupID = "group.com.jieyu.zeeho.signin"
    /// 抓到的 Token 写入的文件。
    static let capturedFile = "capture-token.json"
    /// Tunnel Extension 输出的日志文件。
    static let logFile = "tunnel.log"
    /// Tunnel Extension 启动后 2 分钟内没抓到就算超时。
    static let timeoutSeconds = 180.0
}

// MARK: - CA 证书生成 + 持久化 + 安装引导

enum ZeehoCA {
    /// 生成或读取已存在的自签 CA，返回 DER 格式的证书数据（用于 MDM/描述文件安装）。
    static func certificateData() throws -> Data {
        // 先尝试从 Keychain 读已存在的 CA
        if let existing = try loadFromKeychain(), !existing.isEmpty {
            return existing
        }
        let (cert, _) = try generateCA()
        return cert
    }

    /// 生成 RSA-2048 自签 CA 根证书，有效期 10 年。
    private static func generateCA() throws -> (Data, SecKey) {
        let keyAttr: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        guard let privateKey = SecKeyCreateRandomKey(keyAttr as CFDictionary, nil) else {
            throw CaptureError.caKeyGenFailed
        }
        let publicKey = SecKeyCopyPublicKey(privateKey)!

        let subject = [
            kSecOIDCountry: "CN",
            kSecOIDOrganization: "Zeeho Signin",
            kSecOIDCommonName: "Zeeho Signin CA",
        ] as [CFString: Any]

        let validity: [CFString: Any] = [
            kSecAttrValidFrom: Date(),
            kSecAttrValidTo: Date().addingTimeInterval(10 * 365 * 24 * 3600),
        ] as [CFString: Any]

        let extensionDict: [CFString: Any] = [
            kSecOIDX509V1IsCA: true,
            kSecOIDX509V1BasicConstraints: [true, 0],
            kSecOIDX509V1KeyUsage: [true, [
                kSecOIDX509V1KeyUsageDigitalSignature,
                kSecOIDX509V1KeyUsageCertSign,
                kSecOIDX509V1KeyUsageCRLSign,
                kSecOIDX509V1KeyUsageKeyEncipherment,
            ] as [CFString]],
        ] as [CFString: Any]

        guard let cert = SecCertificateCreateWithPublicKey(
            publicKey,
            subject as CFDictionary,
            validity as CFDictionary,
            nil
        ) else {
            throw CaptureError.caCreateCertFailed
        }

        // 存私钥到 Keychain（需要 kSecAttrAccessGroup 匹配 App Group 才能和 Tunnel Extension 共享）
        let keySave: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyRef: privateKey,
            kSecAttrAccessGroup: CaptureConsts.appGroupID as CFString,
            kSecAttrLabel: "Zeeho CA Private Key",
            kSecReturnAttributes: false,
        ]
        SecItemAdd(keySave as CFDictionary, nil)

        guard let der = SecCertificateCopyData(cert) as Data? else {
            throw CaptureError.caDERFailed
        }
        try saveToKeychain(der)
        return (der, privateKey)
    }

    private static func loadFromKeychain() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: "Zeeho Signin CA",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return data
        }
        return nil
    }

    private static func saveToKeychain(_ data: Data) throws {
        let add: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: "Zeeho Signin CA",
            kSecValueData: data,
            kSecAttrAccessGroup: CaptureConsts.appGroupID as CFString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem { return }
        throw CaptureError.caKeychainSaveFailed(status: status)
    }
}

// MARK: - 错误

enum CaptureError: LocalizedError, Sendable {
    case caKeyGenFailed
    case caCreateCertFailed
    case caDERFailed
    case caKeychainSaveFailed(status: OSStatus)
    case tunnelLoadFailed
    case tunnelStartFailed(String)
    case tunnelStopFailed
    case timeout
    case vpnDenied
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .caKeyGenFailed: return "生成自签 CA 私钥失败"
        case .caCreateCertFailed: return "生成自签 CA 证书失败"
        case .caDERFailed: return "CA 证书编码失败"
        case .caKeychainSaveFailed(let s): return "CA 存 Keychain 失败 (OSStatus \(s))"
        case .tunnelLoadFailed: return "找不到 ZeehoTunnel Extension target，请检查 bundle id"
        case .tunnelStartFailed(let s): return "VPN 启动失败：\(s)"
        case .tunnelStopFailed: return "VPN 停止失败"
        case .timeout: return "超时未抓到 Token（2 分钟内没有流量）"
        case .vpnDenied: return "VPN 授权被取消"
        case .notConfigured: return "VPN 未配置"
        }
    }
}

// MARK: - 抓取管理器

@MainActor
final class ZeehoCaptureManager: ObservableObject, @unchecked Sendable {
    @Published private(set) var result: CaptureResult = CaptureResult()
    @Published private(set) var stats: CaptureStats = CaptureStats()

    private var tunnel: NETunnelProviderSession?
    private var pollTimer: Timer?
    private var startDate: Date?

    static let shared = ZeehoCaptureManager()

    // MARK: - 状态

    func saveResult() {
        ZeehoCaptureStore.save(result)
    }

    // MARK: - 启动流程

    /// 完整启动流程：1) 生成 CA → 2) 展示安装引导 → 3) 发起 VPN → 4) 等待 Token。
    func start() async throws {
        // 1) 自签 CA
        _ = try ZeehoCA.certificateData()
        // 2) Tunnel Extension 必须是独立 target；这里先检查配置
        let manager = NETunnelProviderManager()
        // 3) 配置 VPN
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = CaptureConsts.tunnelBundleID
        proto.serverAddress = CaptureConsts.vpnTitle
        proto.providerConfiguration = [
            "mitmHost": CaptureConsts.mitmHost,
            "officialBundleID": CaptureConsts.officialBundleID,
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = CaptureConsts.vpnTitle
        manager.isEnabled = true
        // 4) 让系统弹 VPN 授权
        try manager.saveToPreferences()
        tunnel = manager.connection as? NETunnelProviderSession
        guard let tunnel else { throw CaptureError.tunnelLoadFailed }

        result = CaptureResult(state: .requestingVPN)
        saveResult()

        // 5) 启动 Tunnel（这步之前会弹系统 VPN 授权）
        try tunnel.startVPNTunnel()

        result.state = .waiting
        result.updatedAtUnix = Date().timeIntervalSince1970
        saveResult()
        startDate = Date()
        startPolling()
    }

    /// 取消 / 停止。
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        tunnel?.stopVPNTunnel()
        tunnel = nil
    }

    // MARK: - Tunnel Extension 通讯

    /// Tunnel Extension 把抓到的 token 写入 App Group 目录。我们轮询这个文件。
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
    }

    private func pollOnce() {
        // 1) 抓 token
        let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: CaptureConsts.appGroupID)?
            .appendingPathComponent(CaptureConsts.capturedFile)
        if let url, let data = try? Data(contentsOf: url),
           let obj = try? JSONDecoder().decode(CaptureResult.self, from: data),
           let token = obj.token, !token.isEmpty {
            // 抓到了！
            result = obj
            result.state = .success
            result.updatedAtUnix = Date().timeIntervalSince1970
            saveResult()
            stop()
            Task { try await importToken(token: token, uid: obj.uid) }
            return
        }
        // 2) 超时
        if let start = startDate, Date().timeIntervalSince(start) > CaptureConsts.timeoutSeconds {
            result.state = .timeout
            saveResult()
            stop()
        }
    }

    private func importToken(token: String, uid: String?) async throws {
        // 直接调用 Engine.addAccount，自动完成签到并导入多账号
        _ = try await ZeehoEngine.addAccount(token)
        // 可选：如果有 uid，拼 label
        if let uid, !uid.isEmpty {
            ZeehoLog.info("captured uid=\(uid) token=\(token.prefix(8))…")
        }
    }
}

enum ZeehoLog {
    static func info(_ s: String) {
        #if DEBUG
        print("[ZeehoCapture] \(s)")
        #endif
    }
}

/// 非 Observable 的极简状态持久化。
enum ZeehoCaptureStore {
    private static let key = "zeeho.capture.result"

    static func load() -> CaptureResult {
        guard let data = UserDefaults.standard.data(forKey: key),
              let r = try? JSONDecoder().decode(CaptureResult.self, from: data) else {
            return CaptureResult()
        }
        return r
    }

    static func save(_ r: CaptureResult) {
        if let data = try? JSONEncoder().encode(r) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
