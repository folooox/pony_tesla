import CryptoKit
import Foundation

// Standalone macOS/iOS SDK check executable; compile with NativeTeslaClient.swift + PonyCore.
// Generates short-lived local values only. Does not use Keychain, UI or networking.
@main
struct NativeTeslaClientChecks {
    private enum Failure: Error { case checkFailed }

    @MainActor
    static func main() async throws {
        func check(_ condition: Bool) throws {
            guard condition else { throw Failure.checkFailed }
        }
        let verifier = try NativeTeslaPKCE.random()
        let state = try NativeTeslaPKCE.random()
        let grant = try NativeTeslaPKCE.random()
        try check(NativeTeslaPKCE.isOpaque(verifier))
        try check(NativeTeslaPKCE.isOpaque(state))
        try check(verifier != state && state != grant && verifier != grant)
        let challenge = NativeTeslaPKCE.challenge(for: verifier)
        try check(NativeTeslaPKCE.isOpaque(challenge) && challenge != verifier)
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        try check(NativeTeslaPKCE.base64URL(digest) == challenge)
        try check(!NativeTeslaPKCE.isOpaque(""))
        try check(!NativeTeslaPKCE.isOpaque(String(repeating: "+", count: 43)))

        let valid = NativeTeslaCallback.absolute + "?grant=\(grant)&state=\(state)"
        guard let validURL = URL(string: valid) else { throw Failure.checkFailed }
        try check(try NativeTeslaCallback.grant(from: validURL, expectedState: state) == grant)
        let invalid = [
            "other://auth?grant=\(grant)&state=\(state)",
            "pony-native://elsewhere?grant=\(grant)&state=\(state)",
            "pony-native://auth/?grant=\(grant)&state=\(state)",
            "pony-native://auth/extra?grant=\(grant)&state=\(state)",
            "pony-native://auth:443?grant=\(grant)&state=\(state)",
            "pony-native://user@auth?grant=\(grant)&state=\(state)",
            valid + "#extra", valid + "&extra=1", valid + "&state=\(state)",
            valid + "&grant=\(grant)",
            "pony-native://auth?grant=\(grant)",
            "pony-native://auth?grant=&state=\(state)",
            "pony-native://auth?grant=\(grant)&state=\(verifier)"
        ]
        for candidate in invalid {
            guard let url = URL(string: candidate) else { continue }
            do {
                _ = try NativeTeslaCallback.grant(from: url, expectedState: state)
                throw Failure.checkFailed
            } catch NativeTeslaError.invalidCallback { /* expected */ }
        }
        let code = try NativeOwnerPairing.code()
        try check(code.utf8.count == 8 && code.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) })
        try check(NativeOwnerPairing.grouped("01ABCDEF") == "01AB CDEF")
        try check(NativeOwnerPairing.spoken("01ABCDEF") == "0 1 A B，C D E F")
        let authorization = NativeOwnerPairing.origin + "/owner/devices/pair?request=" + grant
        try check(try NativeOwnerPairing.authorizationURL(authorization).absoluteString == authorization)
        for bad in [authorization + "&extra=1", authorization + "#fragment",
                    authorization.replacingOccurrences(of: "https:", with: "http:"),
                    authorization.replacingOccurrences(of: "tesla.ponypro.party", with: "tesla.ponypro.party.evil.test"),
                    authorization.replacingOccurrences(of: "/pair?", with: "/pair/?"),
                    authorization.replacingOccurrences(of: "request=", with: "request=%41"),
                    authorization.replacingOccurrences(of: "https://", with: "https://user@"),
                    authorization.replacingOccurrences(of: "/owner/", with: ":443/owner/")] {
            do { _ = try NativeOwnerPairing.authorizationURL(bad); throw Failure.checkFailed }
            catch NativeTeslaError.invalidResponse { }
        }
        let denial = "pony-native://auth?error=pairing_rejected&state=" + state
        try check(NativeOwnerPairing.isDenial(URL(string: denial)!, expectedState: state))
        for bad in [denial + "&grant=" + grant, denial + "&error=pairing_rejected", denial + "#x",
                    denial.replacingOccurrences(of: "pairing_rejected", with: "unknown"),
                    denial.replacingOccurrences(of: state, with: verifier),
                    denial.replacingOccurrences(of: "auth?", with: "auth/?")] {
            try check(!NativeOwnerPairing.isDenial(URL(string: bad)!, expectedState: state))
        }
        // Denial must never enter grant redemption.
        do { _ = try NativeTeslaCallback.grant(from: URL(string: denial)!, expectedState: state); throw Failure.checkFailed }
        catch NativeTeslaError.invalidCallback { }
        let install = UUID().uuidString
        try check(NativeInstallation.matches(stored: install, current: install))
        try check(!NativeInstallation.matches(stored: install, current: UUID().uuidString))
        try check(!NativeInstallation.matches(stored: install, current: ""))
        try check(!NativeInstallation.matches(stored: "", current: ""))
        // Synthetic sandbox only: restart preserves marker, reinstall cannot adopt old binding,
        // and unreadable marker evidence is neither erased nor replaced.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("installation")
        let originalInstallation = try NativeInstallation.loadOrCreate(at: marker)
        try check(try NativeInstallation.loadOrCreate(at: marker) == originalInstallation)
        try check(try marker.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try FileManager.default.removeItem(at: marker)
        let reinstalled = try NativeInstallation.loadOrCreate(at: marker)
        try check(!NativeInstallation.matches(stored: originalInstallation, current: reinstalled))
        let unreadable = Data("invalid installation evidence".utf8)
        try unreadable.write(to: marker)
        do { _ = try NativeInstallation.loadOrCreate(at: marker); throw Failure.checkFailed }
        catch NativeTeslaError.keychainUnavailable { }
        try check(try Data(contentsOf: marker) == unreadable)
        // Deterministic delayed-result lifecycle race: no network, credentials or UI bypass.
        var privacy = NativePrivacyEpoch()
        let readBeforeBackground = privacy.value
        try check(privacy.admits(readBeforeBackground))
        privacy.setActive(false)
        try check(!privacy.admits(readBeforeBackground))
        privacy.setActive(true)
        try check(!privacy.admits(readBeforeBackground))
        let foregroundValidation = privacy.value
        try check(privacy.admits(foregroundValidation))
        privacy.invalidate() // revoke/logout/network-unknown privacy boundary
        try check(!privacy.admits(foregroundValidation))
        let delayedSession = privacy.value
        privacy.setActive(false); privacy.setActive(true)
        try check(!privacy.admits(delayedSession))
        try await clientFailureChecks()
        print("PASS native security helpers and injected session/storage/refresh failure checks")
    }

    /// Synthetic store/transport only. Never constructs a browser, touches Keychain or supplies app UI state.
    @MainActor
    private final class SessionRig {
        let install = UUID().uuidString
        let account = UUID().uuidString
        var stored: NativeStoredSession?
        var loadFailure = false
        var installationFailure = false
        var markerReads = 0
        var saves = 0
        var clears = 0
        var failSaveNumber: Int?
        var requests: [String] = []
        var refreshSends = 0
        var sessionSends = 0
        var markedBeforeRefresh = false
        var networkFailure: NativeTeslaError?
        var refreshFailure: NativeTeslaError?
        var principal: String? = "service_owner"
        var returnedAccount: String?
        var pauseRefresh = false
        var refreshGate: CheckedContinuation<Void, Never>?
        var refreshEntered: CheckedContinuation<Void, Never>?
        let oldAccess = String(repeating: "A", count: 43)
        let oldRefresh = String(repeating: "B", count: 43)
        let newAccess = String(repeating: "C", count: 43)
        let newRefresh = String(repeating: "D", count: 43)

        func seed(expired: Bool = false) {
            stored = NativeStoredSession(access: oldAccess, refresh: oldRefresh,
                expiresAt: Date().addingTimeInterval(expired ? -60 : 600),
                refreshExpiresAt: Date().addingTimeInterval(86_400),
                accountID: account, installationID: install)
        }

        func dependencies() -> NativeTeslaDependencies {
            NativeTeslaDependencies(load: {
                if self.loadFailure { throw NativeTeslaError.keychainUnavailable }
                return self.stored
            }, save: { session in
                self.saves += 1
                if self.failSaveNumber == self.saves { throw NativeTeslaError.keychainUnavailable }
                self.stored = session
            }, clear: {
                self.clears += 1; self.stored = nil
            }, installationID: {
                self.markerReads += 1
                if self.installationFailure { throw NativeTeslaError.keychainUnavailable }
                return self.install
            }, send: { path, method, body, bearer, query in
                self.requests.append(path)
                guard query.isEmpty else { throw Failure.checkFailed }
                switch path {
                case "/api/native/v1/session":
                    self.sessionSends += 1
                    guard method == "GET", body == nil,
                          bearer == self.oldAccess || bearer == self.newAccess else { throw Failure.checkFailed }
                    if let error = self.networkFailure { throw error }
                    var object: [String: Any] = [
                        "account_id": self.returnedAccount ?? self.account,
                        "native_deployment_verified": true,
                        "features": ["vehicles": true, "probe": true, "snapshot": true,
                                     "commands": false, "telemetry": false, "charge_history": false, "trips": false]]
                    if let principal = self.principal { object["principal_type"] = principal }
                    return try JSONSerialization.data(withJSONObject: object)
                case "/api/native/v1/auth/refresh":
                    self.refreshSends += 1
                    guard method == "POST", bearer == nil, let body,
                          let fields = try JSONSerialization.jsonObject(with: body) as? [String: String],
                          fields == ["refresh_token": self.oldRefresh] else { throw Failure.checkFailed }
                    self.markedBeforeRefresh = self.stored?.refreshPending == true
                    self.refreshEntered?.resume(); self.refreshEntered = nil
                    if self.pauseRefresh {
                        await withCheckedContinuation { self.refreshGate = $0 }
                    }
                    if let error = self.refreshFailure { throw error }
                    return try JSONSerialization.data(withJSONObject: [
                        "access_token": self.newAccess, "refresh_token": self.newRefresh,
                        "token_type": "Bearer", "expires_in": 900,
                        "refresh_expires_in": 86_400, "account_id": self.account])
                default: throw Failure.checkFailed // In particular, no implicit vehicle request.
                }
            })
        }

        func waitForRefresh() async {
            if refreshSends > 0 { return }
            await withCheckedContinuation { refreshEntered = $0 }
        }
    }

    @MainActor
    private static func clientFailureChecks() async throws {
        func check(_ value: Bool) throws { if !value { throw Failure.checkFailed } }
        func expect(_ error: NativeTeslaError, _ operation: () async throws -> Void) async throws {
            do { try await operation(); throw Failure.checkFailed }
            catch let actual as NativeTeslaError { try check(actual == error) }
        }

        // Actual constructor: same-install restore is local-only; mismatched/missing marker cannot adopt.
        let restored = SessionRig(); restored.seed()
        let client = try NativeTeslaClient(dependencies: restored.dependencies())
        try check(client.hasLocalSession && restored.requests.isEmpty && restored.saves == 0)
        let mismatched = SessionRig(); mismatched.stored = restored.stored
        let otherClient = try NativeTeslaClient(dependencies: mismatched.dependencies())
        try check(!otherClient.hasLocalSession && mismatched.stored != nil && mismatched.clears == 0)
        let brokenMarker = SessionRig(); brokenMarker.seed(); brokenMarker.installationFailure = true
        try await expect(.keychainUnavailable) { _ = try NativeTeslaClient(dependencies: brokenMarker.dependencies()) }
        try check(brokenMarker.stored != nil && brokenMarker.saves == 0 && brokenMarker.clears == 0)
        let unreadable = SessionRig(); unreadable.seed(); unreadable.loadFailure = true
        try await expect(.keychainUnavailable) { _ = try NativeTeslaClient(dependencies: unreadable.dependencies()) }
        try check(unreadable.markerReads == 0 && unreadable.saves == 0 && unreadable.clears == 0 && unreadable.stored != nil)

        // Offline /session returns no validated result, preserves local evidence, and makes no vehicle call.
        restored.networkFailure = .networkUnavailable
        try await expect(.networkUnavailable) { _ = try await client.sessionInfo() }
        try check(client.hasLocalSession && restored.stored != nil && restored.clears == 0)
        try check(restored.requests == ["/api/native/v1/session"])
        restored.networkFailure = nil
        let active = try await client.sessionInfo()
        try check(active.principal_type == "service_owner" && active.account_id == restored.account)
        for mode in ["tesla", "unknown", nil] as [String?] {
            restored.principal = mode
            try await expect(.invalidResponse) { _ = try await client.sessionInfo() }
            try check(client.hasLocalSession)
        }
        restored.principal = "service_owner"; restored.returnedAccount = UUID().uuidString
        try await expect(.invalidResponse) { _ = try await client.sessionInfo() }
        restored.returnedAccount = nil; restored.networkFailure = .signInRequired
        try await expect(.signInRequired) { _ = try await client.sessionInfo() }
        try check(!client.hasLocalSession && restored.stored == nil && restored.clears == 1)

        // Actual refresh task single-flight; save ambiguity marker before first byte is sent.
        let rotating = SessionRig(); rotating.seed(expired: true); rotating.pauseRefresh = true
        let rotatingClient = try NativeTeslaClient(dependencies: rotating.dependencies())
        let first = Task { @MainActor in try await rotatingClient.sessionInfo() }
        let second = Task { @MainActor in try await rotatingClient.sessionInfo() }
        await rotating.waitForRefresh()
        try check(rotating.markedBeforeRefresh && rotating.stored?.refreshPending == true)
        rotating.refreshGate?.resume(); rotating.refreshGate = nil
        _ = try await first.value; _ = try await second.value
        try check(rotating.refreshSends == 1 && rotating.sessionSends == 2 && rotating.saves == 2)
        try check(rotating.stored?.refresh == rotating.newRefresh && rotating.stored?.refreshPending != true)
        let rotatedRestart = try NativeTeslaClient(dependencies: rotating.dependencies())
        _ = try await rotatedRestart.sessionInfo()
        try check(rotating.refreshSends == 1)

        // Lost refresh response: retain marked evidence, reject retries both now and after restart.
        let uncertain = SessionRig(); uncertain.seed(expired: true); uncertain.refreshFailure = .networkUnavailable
        let uncertainClient = try NativeTeslaClient(dependencies: uncertain.dependencies())
        try await expect(.networkUnavailable) { _ = try await uncertainClient.sessionInfo() }
        try check(uncertainClient.hasLocalSession && uncertain.markedBeforeRefresh && uncertain.clears == 0)
        try await expect(.authenticationFailed) { _ = try await uncertainClient.sessionInfo() }
        let uncertainRestart = try NativeTeslaClient(dependencies: uncertain.dependencies())
        try await expect(.authenticationFailed) { _ = try await uncertainRestart.sessionInfo() }
        try check(uncertain.refreshSends == 1 && uncertain.sessionSends == 0)

        // Failed pre-send save sends nothing; failed post-rotation save cannot fall back/replay.
        let before = SessionRig(); before.seed(expired: true); before.failSaveNumber = 1
        let beforeClient = try NativeTeslaClient(dependencies: before.dependencies())
        try await expect(.keychainUnavailable) { _ = try await beforeClient.sessionInfo() }
        try check(before.refreshSends == 0 && before.stored?.refresh == before.oldRefresh && before.stored?.refreshPending != true)
        let after = SessionRig(); after.seed(expired: true); after.failSaveNumber = 2
        let afterClient = try NativeTeslaClient(dependencies: after.dependencies())
        try await expect(.keychainUnavailable) { _ = try await afterClient.sessionInfo() }
        try check(after.markedBeforeRefresh && after.stored?.refreshPending == true && after.sessionSends == 0)
        let afterRestart = try NativeTeslaClient(dependencies: after.dependencies())
        try await expect(.authenticationFailed) { _ = try await afterRestart.sessionInfo() }
        try check(after.refreshSends == 1 && after.clears == 0)

        let revokedRefresh = SessionRig(); revokedRefresh.seed(expired: true); revokedRefresh.refreshFailure = .signInRequired
        let revokedClient = try NativeTeslaClient(dependencies: revokedRefresh.dependencies())
        try await expect(.signInRequired) { _ = try await revokedClient.sessionInfo() }
        try check(!revokedClient.hasLocalSession && revokedRefresh.stored == nil && revokedRefresh.clears == 1)
    }
}
