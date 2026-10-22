import AuthenticationServices
import CryptoKit
import Foundation
import PonyCore
import Security

/// Native sessions only. Tesla credentials and owner-admin authentication never enter the app.
enum NativeTeslaError: Error, LocalizedError, Sendable, Equatable {
    case randomUnavailable, keychainUnavailable, invalidCallback, invalidResponse
    case pairingRejected, pairingExpired, localPairingWindowEnded
    case cancelled, authenticationFailed, signInRequired, unavailable, rateLimited
    case responseTooLarge, networkUnavailable, accountDeletionUnavailable

    var errorDescription: String? {
        switch self {
        case .randomUnavailable: "无法安全启动登录，请重试。"
        case .keychainUnavailable: "无法访问安全登录凭据，请重试。"
        case .invalidCallback, .authenticationFailed: "无法验证登录，请重试。"
        case .invalidResponse: "服务器返回的数据异常。"
        case .pairingRejected: "后台已拒绝本次配对。"
        case .pairingExpired: "配对已过期，请手动重新开始。"
        case .localPairingWindowEnded: "本机确认时限已结束，请手动重新开始。"
        case .cancelled: "已返回应用；不代表后台请求已取消。"
        case .signInRequired: "请重新登录。"
        case .unavailable: "服务暂不可用，请稍后重试。"
        case .rateLimited: "操作频繁，请稍后重试。"
        case .responseTooLarge: "服务器返回的数据过大。"
        case .networkUnavailable: "无法连接服务器，请检查网络。"
        case .accountDeletionUnavailable: "暂不支持注销账号，服务器数据未删除。"
        }
    }
}

enum NativeTeslaPKCE {
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NativeTeslaError.randomUnavailable
        }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func isOpaque(_ text: String) -> Bool {
        text.utf8.count == 43 && text.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

enum NativeTeslaCallback {
    static let scheme = "pony-native"
    static let absolute = "pony-native://auth"

    static func grant(from url: URL, expectedState: String) throws -> String {
        guard NativeTeslaPKCE.isOpaque(expectedState), url.absoluteString.utf8.count <= 2048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == scheme, parts.host == "auth", parts.percentEncodedPath.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 2,
              items.filter({ $0.name == "state" }).count == 1,
              items.filter({ $0.name == "grant" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState,
              let grant = items.first(where: { $0.name == "grant" })?.value,
              NativeTeslaPKCE.isOpaque(grant) else { throw NativeTeslaError.invalidCallback }
        return grant
    }
}

/// Admission token for UI results. A lifecycle/privacy boundary permanently rejects older results.
struct NativePrivacyEpoch {
    private(set) var value: UInt64 = 0
    private(set) var active = true
    mutating func invalidate() { value &+= 1 }
    mutating func setActive(_ active: Bool) {
        if self.active != active { invalidate() }
        self.active = active
    }
    func admits(_ captured: UInt64) -> Bool { active && captured == value }
}

enum NativeOwnerPairing {
    static let origin = "https://tesla.ponypro.party"
    static func code() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NativeTeslaError.randomUnavailable
        }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
    static func grouped(_ code: String) -> String {
        String(code.prefix(4)) + " " + String(code.suffix(4))
    }
    static func spoken(_ code: String) -> String {
        code.prefix(4).map(String.init).joined(separator: " ") + "，" + code.suffix(4).map(String.init).joined(separator: " ")
    }
    static func authorizationURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 2048, let url = URL(string: raw),
              let p = URLComponents(url: url, resolvingAgainstBaseURL: false),
              p.scheme == "https", p.host == "tesla.ponypro.party", p.port == nil,
              p.user == nil, p.password == nil, p.fragment == nil,
              p.percentEncodedPath == "/owner/devices/pair",
              let items = p.queryItems, items.count == 1, items[0].name == "request",
              let request = items[0].value, NativeTeslaPKCE.isOpaque(request),
              raw == origin + "/owner/devices/pair?request=" + request else {
            throw NativeTeslaError.invalidResponse
        }
        return url
    }
    static func isDenial(_ url: URL, expectedState: String) -> Bool {
        guard NativeTeslaPKCE.isOpaque(expectedState),
              let p = URLComponents(url: url, resolvingAgainstBaseURL: false),
              p.scheme == NativeTeslaCallback.scheme, p.host == "auth", p.percentEncodedPath.isEmpty,
              p.user == nil, p.password == nil, p.port == nil, p.fragment == nil,
              let items = p.queryItems, items.count == 2,
              items.filter({ $0.name == "error" && $0.value == "pairing_rejected" }).count == 1,
              items.filter({ $0.name == "state" && $0.value == expectedState }).count == 1 else { return false }
        return url.absoluteString.utf8.count <= 2048
    }
}

/// Non-secret installation identity, excluded from backup. Never derive it from Keychain.
enum NativeInstallation {
    static func matches(stored: String, current: String) -> Bool {
        UUID(uuidString: stored) != nil && UUID(uuidString: current) != nil && stored == current
    }
    static func loadOrCreate(at url: URL) throws -> String {
        do {
            var file = url
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count == 36, let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil else {
                    throw NativeTeslaError.keychainUnavailable
                }
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try file.setResourceValues(values)
                return id
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let id = UUID().uuidString
            #if os(iOS)
            try Data(id.utf8).write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try Data(id.utf8).write(to: file, options: .atomic)
            #endif
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try file.setResourceValues(values)
            return id
        } catch { throw NativeTeslaError.keychainUnavailable }
    }
}

struct NativeStoredSession: Codable, Sendable {
    let access: String
    let refresh: String
    let expiresAt: Date
    let refreshExpiresAt: Date
    let accountID: String
    let installationID: String
    var refreshPending: Bool? = nil

    var valid: Bool {
        UUID(uuidString: installationID) != nil && NativeTeslaPKCE.isOpaque(access) && NativeTeslaPKCE.isOpaque(refresh)
            && UUID(uuidString: accountID) != nil && expiresAt.timeIntervalSince1970.isFinite
            && refreshExpiresAt.timeIntervalSince1970.isFinite && expiresAt <= refreshExpiresAt
    }
}

private enum NativeSessionKeychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "party.ponypro.owner.native-session.v2",
         kSecAttrAccount as String: "session",
         kSecAttrSynchronizable as String: false]
    }

    static func load() throws -> NativeStoredSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = item as? Data, bytes.count <= 4096,
              let session = try? JSONDecoder().decode(NativeStoredSession.self, from: bytes), session.valid else {
            throw NativeTeslaError.keychainUnavailable
        }
        return session
    }

    static func save(_ session: NativeStoredSession) throws {
        guard session.valid, let bytes = try? JSONEncoder().encode(session) else {
            throw NativeTeslaError.keychainUnavailable
        }
        let attributes: [String: Any] = [kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            attributes.forEach { addition[$0.key] = $0.value }
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
                throw NativeTeslaError.keychainUnavailable
            }
        } else if status != errSecSuccess { throw NativeTeslaError.keychainUnavailable }
    }

    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeTeslaError.keychainUnavailable
        }
    }
}

private final class NativeRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // JSON endpoints do not redirect, even within the approved host.
        completionHandler(nil)
    }
}

private enum NativeTransport {
    static let origin = NativeOwnerPairing.origin
    static let prefix = "/api/native/v1"

    static func approved(_ url: URL) -> Bool {
        guard let p = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return p.scheme == "https" && p.host == "tesla.ponypro.party" && p.port == nil
            && p.user == nil && p.password == nil && p.fragment == nil
    }

    static func send(path: String, method: String = "GET", body: Data? = nil,
                     bearer: String? = nil, queryItems: [URLQueryItem] = []) async throws -> Data {
        guard path.hasPrefix(prefix + "/"), !path.contains("?"), !path.contains("#"),
              var components = URLComponents(string: origin + path) else { throw NativeTeslaError.invalidResponse }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url, approved(url), components.percentEncodedPath == path else {
            throw NativeTeslaError.invalidResponse
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer {
            guard NativeTeslaPKCE.isOpaque(bearer) else { throw NativeTeslaError.signInRequired }
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: NativeRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.url == url else { throw NativeTeslaError.invalidResponse }
            switch http.statusCode {
            case 200: break
            case 401: throw NativeTeslaError.signInRequired
            case 429: throw NativeTeslaError.rateLimited
            default: throw NativeTeslaError.unavailable
            }
            guard http.mimeType == "application/json" else { throw NativeTeslaError.invalidResponse }
            let limit = 1_048_576
            guard response.expectedContentLength <= Int64(limit) else { throw NativeTeslaError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw NativeTeslaError.responseTooLarge }
                data.append(byte)
            }
            return data
        } catch let error as NativeTeslaError { throw error }
        catch is CancellationError { throw NativeTeslaError.cancelled }
        catch { throw Task.isCancelled ? NativeTeslaError.cancelled : NativeTeslaError.networkUnavailable }
    }
}

@MainActor
private final class NativeAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?

    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    func open(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.failure(NativeTeslaError.cancelled))
                    return
                }
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: NativeTeslaCallback.scheme) { [weak self] url, error in
                    Task { @MainActor in
                        if let url, error == nil { self?.finish(.success(url)) }
                        else { self?.finish(.failure(NativeTeslaError.cancelled)) }
                    }
                }
                browser.presentationContextProvider = self
                browser.prefersEphemeralWebBrowserSession = true
                session = browser
                if !browser.start() { finish(.failure(NativeTeslaError.authenticationFailed)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        let browser = session
        finish(.failure(NativeTeslaError.cancelled))
        browser?.cancel()
    }

    private func finish(_ result: Result<URL, any Error>) {
        let pending = continuation
        continuation = nil
        session = nil
        pending?.resume(with: result)
    }
}

struct NativeTeslaFeatures: Decodable, Sendable {
    let vehicles: Bool
    let probe: Bool
    let snapshot: Bool
    let commands: Bool
    let telemetry: Bool
    let charge_history: Bool
    let trips: Bool
    /// Server capability hints never enable control APIs in this client.
    var supportedQuickControls: Set<QuickControl> { [] }
}

struct NativeTeslaSessionInfo: Decodable, Sendable {
    let account_id: String
    let principal_type: String?
    let features: NativeTeslaFeatures
    let native_deployment_verified: Bool
}

struct NativeTeslaLogoutOutcome: Sendable {
    /// False means local sign-out only; server revocation remains unconfirmed.
    let serverSessionRevoked: Bool
    let teslaAuthorizationRevoked = false
    let serverDataDeleted = false
}

/// Internal construction seam for deterministic checks; app construction always uses live dependencies.
/// No runtime configuration, launch argument, alternate origin, browser bypass or UI fixture.
@MainActor
struct NativeTeslaDependencies {
    let load: @MainActor () throws -> NativeStoredSession?
    let save: @MainActor (NativeStoredSession) throws -> Void
    let clear: @MainActor () throws -> Void
    let installationID: @MainActor () throws -> String
    let send: @MainActor (String, String, Data?, String?, [URLQueryItem]) async throws -> Data

    static var live: Self {
        Self(load: { try NativeSessionKeychain.load() },
             save: { try NativeSessionKeychain.save($0) },
             clear: { try NativeSessionKeychain.clear() },
             installationID: {
                 let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                     in: .userDomainMask, appropriateFor: nil, create: true)
                 return try NativeInstallation.loadOrCreate(at: directory.appendingPathComponent("owner-installation-v1"))
             }, send: { path, method, body, bearer, query in
                 try await NativeTransport.send(path: path, method: method, body: body,
                                                bearer: bearer, queryItems: query)
             })
    }
}

@MainActor
final class NativeTeslaClient: NativeHistoryFetching {
    private let dependencies: NativeTeslaDependencies
    private struct StartReply: Decodable { let authorization_url: String; let expires_in: Int }
    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String
        let token_type: String
        let expires_in: Int
        let refresh_expires_in: Int
        let account_id: String

        func stored(at now: Date, installationID: String) throws -> NativeStoredSession {
            guard token_type == "Bearer", (1...900).contains(expires_in),
                  (1...2_592_000).contains(refresh_expires_in), expires_in <= refresh_expires_in else {
                throw NativeTeslaError.invalidResponse
            }
            let value = NativeStoredSession(access: access_token, refresh: refresh_token,
                expiresAt: now.addingTimeInterval(Double(expires_in)),
                refreshExpiresAt: now.addingTimeInterval(Double(refresh_expires_in)), accountID: account_id, installationID: installationID)
            guard value.valid else { throw NativeTeslaError.invalidResponse }
            return value
        }
    }
    private var credentials: NativeStoredSession?
    private var browser: NativeAuthBrowser?
    private var signingIn = false
    private var refreshTask: Task<NativeStoredSession, any Error>?
    private var generation = UUID()

    private let installationID: String
    private struct Pending {
        let verifier: String
        let state: String
        let code: String
        let url: URL
        let deadline: Date
        let started: ContinuousClock.Instant
        let ttl: Duration
    }
    private var pending: Pending?
    var pairingCode: String? { pending?.code }
    var pairingDeadline: Date? { pending?.deadline }

    init(dependencies: NativeTeslaDependencies = .live) throws {
        self.dependencies = dependencies
        // Read/validate first: unreadable evidence must not be overwritten or deleted.
        let stored = try dependencies.load()
        guard stored?.valid != false else { throw NativeTeslaError.keychainUnavailable }
        installationID = try dependencies.installationID()
        guard UUID(uuidString: installationID) != nil else { throw NativeTeslaError.keychainUnavailable }
        credentials = stored.flatMap { NativeInstallation.matches(stored: $0.installationID, current: installationID) ? $0 : nil }
    }
    var hasLocalSession: Bool { credentials != nil }
    var refreshRecoveryRequired: Bool { credentials?.refreshPending == true }

    func preparePairing() async throws {
        guard !signingIn, credentials == nil else { throw NativeTeslaError.unavailable }
        pending = nil; signingIn = true
        defer { signingIn = false }
        let attempt = generation
        let verifier = try NativeTeslaPKCE.random(), state = try NativeTeslaPKCE.random()
        let code = try NativeOwnerPairing.code()
        let started = ContinuousClock.now
        let date = Date()
        let reply: StartReply = try await post("/pair/start", [
            "code_challenge": NativeTeslaPKCE.challenge(for: verifier),
            "callback": NativeTeslaCallback.absolute, "state": state, "verification_code": code])
        guard generation == attempt else { throw NativeTeslaError.cancelled }
        guard (1...600).contains(reply.expires_in) else { throw NativeTeslaError.invalidResponse }
        let url = try NativeOwnerPairing.authorizationURL(reply.authorization_url)
        pending = Pending(verifier: verifier, state: state, code: code, url: url,
            deadline: date.addingTimeInterval(Double(reply.expires_in)), started: started, ttl: .seconds(reply.expires_in))
    }

    func cancelPairing() { generation = UUID(); pending = nil; browser?.cancel() }

    func openPairing(anchor: ASPresentationAnchor) async throws {
        guard !signingIn, credentials == nil, let pending else { throw NativeTeslaError.unavailable }
        guard pending.started.duration(to: .now) < pending.ttl else {
            self.pending = nil; throw NativeTeslaError.localPairingWindowEnded
        }
        signingIn = true
        defer { signingIn = false; browser = nil }
        let attempt = generation
        let browser = NativeAuthBrowser(anchor: anchor)
        self.browser = browser
        let callback = try await browser.open(pending.url)
        self.pending = nil
        guard attempt == generation else { throw NativeTeslaError.cancelled }
        if NativeOwnerPairing.isDenial(callback, expectedState: pending.state) { throw NativeTeslaError.pairingRejected }
        let grant = try NativeTeslaCallback.grant(from: callback, expectedState: pending.state)
        let tokens: Tokens = try await post("/pair/exchange", ["grant": grant,
            "code_verifier": pending.verifier, "callback": NativeTeslaCallback.absolute])
        guard attempt == generation else { throw NativeTeslaError.cancelled }
        let session = try tokens.stored(at: Date(), installationID: installationID)
        try dependencies.save(session)
        credentials = session
    }

    func sessionInfo() async throws -> NativeTeslaSessionInfo {
        let data = try await authenticated("/session")
        let info: NativeTeslaSessionInfo = try decode(data)
        guard info.account_id == credentials?.accountID, info.principal_type == "service_owner" else { throw NativeTeslaError.invalidResponse }
        return info
    }

    func vehicles() async throws -> [ReadOnlyVehicleIdentity] {
        struct Envelope: Decodable { let vehicles: [ReadOnlyVehicleIdentity] }
        let envelope: Envelope = try decode(await authenticated("/vehicles"))
        guard envelope.vehicles.count <= 100,
              Set(envelope.vehicles.map(\.vin)).count == envelope.vehicles.count else { throw NativeTeslaError.invalidResponse }
        for vehicle in envelope.vehicles { try validateVIN(vehicle.vin) }
        return envelope.vehicles
    }

    /// A single explicit user-requested read; no wake, timer, polling or retry loop.
    func probe(vin: String) async throws -> ReadOnlyVehicleData {
        try validateVIN(vin)
        let data = try await authenticated("/vehicles/\(vin)/probe", method: "POST")
        return try ReadOnlyVehicleDataDecoder.decodeProbe(data, expectedVIN: vin, receivedAt: Date())
    }

    func snapshot(vin: String) async throws -> ReadOnlyVehicleData {
        try validateVIN(vin)
        let data = try await authenticated("/vehicles/\(vin)/snapshot")
        return try ReadOnlyVehicleDataDecoder.decodeCache(data, expectedVIN: vin, receivedAt: Date())
    }

    /// Explicit, read-only history requests; capability admission belongs to the store.
    func historyList(vin: String, kind: NativeHistoryKind, before: String? = nil) async throws -> NativeHistoryPage {
        try validateVIN(vin)
        var items = [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "limit", value: "30")]
        if let before {
            guard !before.isEmpty, before.utf8.count <= 1024 else { throw NativeTeslaError.invalidResponse }
            items.append(URLQueryItem(name: "before", value: before))
        }
        let data = try await authenticated("/vehicles/\(vin)/history", queryItems: items)
        let page = try NativeHistoryDecoder.decode(NativeHistoryPage.self, from: data)
        try page.validate(expectedVIN: vin, now: Date())
        guard page.records.count <= 30, page.records.allSatisfy({ $0.kind == kind && $0.source == .telemetry }) else {
            throw NativeTeslaError.invalidResponse
        }
        return page
    }

    func historyDetail(vin: String, id: String) async throws -> NativeHistoryRecord {
        try validateVIN(vin)
        guard id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw NativeTeslaError.invalidResponse }
        let data = try await authenticated("/vehicles/\(vin)/history/\(id)")
        let record = try NativeHistoryDecoder.decode(NativeHistoryRecord.self, from: data)
        try record.validate(expectedVIN: vin, now: Date())
        guard record.id == id, record.source == .telemetry else { throw NativeTeslaError.invalidResponse }
        return record
    }

    /// Clears local credentials even when remote revocation cannot be confirmed.
    /// Keychain deletion failure throws and must not be presented as completed sign-out.
    func logout() async throws -> NativeTeslaLogoutOutcome {
        struct Reply: Decodable { let logged_out: Bool; let tesla_revoked: Bool; let data_deleted: Bool }
        generation = UUID()
        browser?.cancel()
        let refreshWasInFlight = refreshTask != nil
        refreshTask?.cancel()
        refreshTask = nil
        let old = credentials
        credentials = nil
        try dependencies.clear()
        var revoked = false
        if let old {
            // Never replay a credential whose in-flight rotation may already have reached the server.
            // A still-valid access token can revoke the family without another refresh.
            var access = old.access
            if !refreshWasInFlight, old.refreshPending != true, old.expiresAt <= Date(), old.refreshExpiresAt > Date() {
                if let tokens: Tokens = try? await post("/auth/refresh", ["refresh_token": old.refresh]),
                   let rotated = try? tokens.stored(at: Date(), installationID: installationID), rotated.accountID == old.accountID {
                    access = rotated.access
                }
            }
            if let data = try? await dependencies.send(NativeTransport.prefix + "/auth/logout",
                "POST", Data("{}".utf8), access, []),
               let reply: Reply = try? decode(data), reply.logged_out, !reply.tesla_revoked, !reply.data_deleted {
                revoked = true
            }
        }
        return NativeTeslaLogoutOutcome(serverSessionRevoked: revoked)
    }

    func deleteAccount() async throws {
        // The backend currently has no account/data deletion contract.
        throw NativeTeslaError.accountDeletionUnavailable
    }

    private func authenticated(_ path: String, method: String = "GET", queryItems: [URLQueryItem] = []) async throws -> Data {
        let attempt = generation
        let session = try await validSession()
        guard generation == attempt else { throw NativeTeslaError.cancelled }
        do {
            let data = try await dependencies.send(NativeTransport.prefix + path, method,
                method == "POST" ? Data("{}".utf8) : nil, session.access, queryItems)
            guard generation == attempt else { throw NativeTeslaError.cancelled }
            return data
        } catch NativeTeslaError.signInRequired {
            if generation == attempt {
                try invalidateSession()
            }
            throw NativeTeslaError.signInRequired
        }
    }

    private func validSession() async throws -> NativeStoredSession {
        guard let old = credentials else { throw NativeTeslaError.signInRequired }
        if old.expiresAt.timeIntervalSinceNow > 30 { return old }
        guard old.refreshExpiresAt > Date() else {
            try invalidateSession()
            throw NativeTeslaError.signInRequired
        }
        if let refreshTask { return try await refreshTask.value }
        // Persist ambiguity before rotating: never replay an uncertain rotating refresh after restart.
        guard old.refreshPending != true else { throw NativeTeslaError.authenticationFailed }
        var marked = old; marked.refreshPending = true
        try dependencies.save(marked)
        credentials = marked
        let attempt = generation
        let task = Task { @MainActor () async throws -> NativeStoredSession in
            let tokens: Tokens = try await self.post("/auth/refresh", ["refresh_token": old.refresh])
            try Task.checkCancellation()
            guard self.generation == attempt else { throw NativeTeslaError.cancelled }
            let updated = try tokens.stored(at: Date(), installationID: self.installationID)
            guard updated.accountID == old.accountID else { throw NativeTeslaError.invalidResponse }
            try self.dependencies.save(updated)
            self.credentials = updated
            return updated
        }
        refreshTask = task
        defer { if generation == attempt { refreshTask = nil } }
        do { return try await task.value }
        catch {
            // An ambiguous refresh failure cannot safely replay the old rotating credential.
            if generation == attempt, error as? NativeTeslaError == .signInRequired { try invalidateSession() }
            throw error
        }
    }

    private func invalidateSession() throws {
        // Supersede every already-bound read, including successful responses racing a 401.
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        credentials = nil
        try dependencies.clear()
    }

    private func post<T: Decodable>(_ path: String, _ fields: [String: String]) async throws -> T {
        let body = try JSONEncoder().encode(fields)
        do {
            return try decode(await dependencies.send(NativeTransport.prefix + path, "POST", body, nil, []))
        } catch NativeTeslaError.signInRequired {
            switch path {
            case "/pair/start": throw NativeTeslaError.unavailable
            case "/pair/exchange": throw NativeTeslaError.authenticationFailed
            default: throw NativeTeslaError.signInRequired
            }
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NativeTeslaError.invalidResponse }
    }

    private func validateVIN(_ vin: String) throws {
        guard vin.range(of: "^[A-HJ-NPR-Z0-9]{17}$", options: .regularExpression) != nil else {
            throw NativeTeslaError.invalidResponse
        }
    }
}
