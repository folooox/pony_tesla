// Synthetic-only entry point. Installed ONLY into a disposable copy of PonyApp.swift.
import SwiftUI
import UIKit
import Foundation
import AuthenticationServices
import PonyCore

private let fixtureVIN = "TEST0000000000001"
private let fixtureAccount = "11111111-1111-4111-8111-111111111111"
private let opaque = String(repeating: "a", count: 43)

@MainActor private final class MemorySession: NativeSessionStorage {
    var value: NativeStoredSession?
    init(restored: Bool, expired: Bool) {
        if restored { value = NativeStoredSession(access: opaque, refresh: opaque,
            expiresAt: Date().addingTimeInterval(expired ? -10 : 800),
            refreshExpiresAt: Date().addingTimeInterval(3600), accountID: fixtureAccount) }
    }
    func load() throws -> NativeStoredSession? { value }
    func save(_ session: NativeStoredSession) throws { value = session }
    func clear() throws { value = nil }
}

// Every URL is intercepted, including unrecognized routes. No fallthrough to a real host.
// URLProtocol inherits a nonisolated designated initializer. Opt the ENTIRE test
// transport out of target defaultMainActor, including synthesized/inherited init.
// Mutable state below remains protected by its static/instance locks.
nonisolated private final class SyntheticProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var scenario = "success-light"
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    nonisolated(unsafe) static var capturedState = ""
    nonisolated(unsafe) static var unexpected: [String] = []
    nonisolated static let lock = NSLock()
    private let instanceLock = NSLock()
    nonisolated(unsafe) private var stopped = false
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated static func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
    nonisolated static func snapshotCounts() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
    nonisolated static func unknownRoutes() -> [String] { lock.lock(); defer { lock.unlock() }; return unexpected }
    nonisolated static func state() -> String { lock.lock(); defer { lock.unlock() }; return capturedState }
    nonisolated override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? "missing"
        let route = path.replacingOccurrences(of: "/api/native/v1", with: "")
        let key = (request.httpMethod ?? "GET") + " " + route
        Self.counts[key, default: 0] += 1
        let number = Self.counts[key, default: 0]
        let scenario = Self.scenario
        var status = 200
        var delay = 0.05
        var body: [String: Any] = [:]
        var networkError = false
        let validOrigin = request.url?.scheme == "https" && request.url?.host == "tesla.ponypro.party"
        switch (request.httpMethod ?? "GET", route, validOrigin) {
        case ("POST", "/auth/start", true):
            var bytes = request.httpBody
            if bytes == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var all = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; all.append(buffer, count: n) }
                bytes = all
            }
            let json = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Self.capturedState = json?["state"] as? String ?? ""
            body = ["authorization_url": "https://tesla.ponypro.party/api/native/v1/auth/browser?request=" + String(repeating: "a", count: 43), "expires_in": 300]
        case ("POST", "/auth/exchange", true), ("POST", "/auth/refresh", true):
            body = ["access_token": String(repeating: "a", count: 43), "refresh_token": String(repeating: "b", count: 43), "token_type": "Bearer", "expires_in": 800, "refresh_expires_in": 3600, "account_id": "11111111-1111-4111-8111-111111111111"]
        case ("GET", "/session", true):
            body = ["account_id": "11111111-1111-4111-8111-111111111111", "native_deployment_verified": false,
                "features": ["vehicles": true, "probe": true, "snapshot": true, "commands": false, "telemetry": false, "charge_history": false, "trips": false, "login_sync": true]]
        case ("GET", "/vehicles", true):
            let online = number > 1 && scenario != "timeout"
            var vehicles: [[String: Any]] = [["vin": "TEST0000000000001", "display_name": "合成车辆", "state": online ? "online" : "asleep"]]
            if scenario == "multiple" { vehicles.append(["vin": "TEST0000000000002", "display_name": "合成车辆二", "state": "asleep"]) }
            body = ["vehicles": vehicles]
            if scenario == "401-waiting" && number > 1 { status = 401; body = ["error": "Synthetic expired session"] }
            if scenario == "confirmation-error" && number > 1 { status = 429; body = ["error": "Synthetic confirmation rate limit"] }
        case ("POST", "/vehicles/TEST0000000000001/login-sync", true):
            body = ["vin": "TEST0000000000001", "phase": scenario == "unknown" ? "wake_unknown" : (scenario == "denied" ? "wake_denied" : "wake_accepted")]
            if scenario == "deadline-reading" { delay = 29 }
            if scenario == "late" { delay = 3 }
            if scenario == "401-waking" { status = 401; body = ["error": "Synthetic expired session"] }
        case ("POST", "/vehicles/TEST0000000000001/probe", true):
            delay = scenario == "deadline-reading" ? 29 : 2
            body = ["connected": true, "live_data": true, "vehicle": ["vin": "TEST0000000000001", "display_name": "合成车辆", "state": "online"], "fetched_at": ISO8601DateFormatter().string(from: Date()), "data": ["charge_state": ["battery_level": 61]]]
            if scenario == "401-reading" { status = 401; body = ["error": "Synthetic expired session"] }
        case ("GET", "/vehicles/TEST0000000000001/snapshot", true):
            switch scenario {
            case "no-cache": status = 404; body = ["error": "No cached vehicle data"]
            case "unknown404": status = 404; body = ["error": "Synthetic unknown error"]
            case "401-cancel": status = 401; body = ["error": "Synthetic expired session"]
            case "429": status = 429; body = ["error": "Synthetic rate limit"]
            case "network": networkError = true
            default: body = ["snapshot": "synthetic malformed payload"]
            }
        case ("POST", "/auth/logout", true): body = ["logged_out": true, "tesla_revoked": false, "data_deleted": false]
        default:
            Self.unexpected.append(key); networkError = true
        }
        Self.lock.unlock()
        let bytes = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let code = status; let failed = networkError
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            instanceLock.lock(); let cancelled = stopped; instanceLock.unlock()
            guard !cancelled else { return }
            if failed { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Content-Length": String(bytes.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    nonisolated override func stopLoading() { instanceLock.lock(); stopped = true; instanceLock.unlock() }
}

@MainActor private final class SyntheticBrowser: NativeLoginBrowser {
    func open(_ url: URL) async throws -> URL {
        let state = SyntheticProtocol.state()
        guard NativeTeslaPKCE.isOpaque(state) else { throw NativeTeslaError.invalidCallback }
        return URL(string: "pony-native://auth?state=\(state)&grant=\(opaque)")!
    }
    func cancel() {}
}

@MainActor @Observable private final class FixtureDriver {
    let scenario: String
    let account: NativeAccountState
    let client: NativeTeslaClient
    var accountPage = false
    var checks: [[String: Any]] = []
    var started = false
    var captured: Set<String> = []
    var scrollEvidence: [[String: Any]] = []
    init() {
        let args = ProcessInfo.processInfo.arguments
        scenario = args.firstIndex(of: "--fixture-scenario").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "success-light"
        SyntheticProtocol.scenario = scenario
        let restored = ["restore", "refresh", "no-cache", "unknown404", "429", "network", "decode", "401-cancel"].contains(scenario)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyntheticProtocol.self]
        let client = try! NativeTeslaClient(storage: MemorySession(restored: restored, expired: scenario == "refresh"), configuration: config, makeBrowser: { _ in SyntheticBrowser() })
        self.client = client
        account = NativeAccountState(client: client)
    }
    func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
    func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    func wait(_ predicate: () -> Bool, seconds: Double = 35) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { if predicate() { return true }; await pause(0.05) }
        return predicate()
    }
    func capture(_ name: String, window: UIWindow) async {
        guard !captured.contains(name) else { return }; captured.insert(name)
        await pause(0.2)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: documents.appendingPathComponent("合成验证-\(scenario)-\(name).png"))
    }
    // Capture actual overlapping UIKit scroll viewports; never stitch/recreate content.
    // The synthetic banner belongs to the surrounding VStack and stays in each PNG.
    func captureScrollPages(_ prefix: String, window: UIWindow) async {
        func scrollViews(in view: UIView) -> [UIScrollView] {
            guard !view.isHidden, view.alpha > 0.01 else { return [] }
            var result: [UIScrollView] = []
            if let scroll = view as? UIScrollView,
               scroll.window === window,
               scroll.bounds.height > 100, scroll.bounds.width > window.bounds.width * 0.5,
               scroll.convert(scroll.bounds, to: window).intersects(window.bounds),
               scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom > scroll.bounds.height + 20 {
                result.append(scroll)
            }
            for child in view.subviews { result.append(contentsOf: scrollViews(in: child)) }
            return result
        }
        window.layoutIfNeeded()
        await pause(0.3)
        guard let scroll = scrollViews(in: window).max(by: { $0.bounds.height < $1.bounds.height }) else {
            check("\(prefix) finds actual vertically scrollable UIKit view", false)
            return
        }
        check("\(prefix) finds actual vertically scrollable UIKit view", true)
        let countsBefore = SyntheticProtocol.snapshotCounts()
        let top = -scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: top), animated: false)
        scroll.layoutIfNeeded(); window.layoutIfNeeded()
        await pause(0.2)
        var moved = false
        for page in 0..<10 {
            // List/UICollectionView estimates can change as cells are realized. Re-read
            // geometry on EVERY page rather than using the initial contentSize.
            scroll.layoutIfNeeded(); window.layoutIfNeeded()
            await pause(0.15)
            scrollEvidence.append(["capture": "\(prefix)-\(page)", "offsetY": Double(scroll.contentOffset.y),
                "contentHeight": Double(scroll.contentSize.height), "viewportHeight": Double(scroll.bounds.height)])
            await capture("\(prefix)-\(page)", window: window)
            let current = scroll.contentOffset.y
            let maximum = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let overlapStep = max(80, (scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom) * 0.65)
            let next = min(maximum, current + overlapStep)
            if next <= current + 1 { break }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
            scroll.layoutIfNeeded(); window.layoutIfNeeded()
            await pause(0.2)
            if scroll.contentOffset.y > current + 1 { moved = true } else { break }
        }
        check("\(prefix) actually moves vertically", moved)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
        scroll.layoutIfNeeded(); window.layoutIfNeeded()
        await pause(0.2)
        check("\(prefix) restores top viewport", abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) < 2)
        check("\(prefix) scrolling makes no network requests or repeat wake/probe", SyntheticProtocol.snapshotCounts() == countsBefore)
    }
    var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    func run(window: UIWindow) async {
        guard !started else { return }; started = true
        check("initialization does not access network", SyntheticProtocol.snapshotCounts().isEmpty)
        check("real scene key window active", window.isKeyWindow && window.windowScene?.activationState == .foregroundActive)
        if ["restore", "refresh", "no-cache", "unknown404", "429", "network", "decode", "401-cancel"].contains(scenario) {
            await pause(0.3)
            check("restored session has no automatic requests", SyntheticProtocol.snapshotCounts().isEmpty && account.hasLocalSession)
            if scenario != "restore" {
                await account.loadVehicles(); account.select(fixtureVIN)
                if scenario == "401-cancel" {
                    do { _ = try await client.snapshot(vin: fixtureVIN); check("direct transport 401 rejects", false) }
                    catch { check("direct transport 401 rejects", !client.hasLocalSession) }
                    check("fixture arranged stale UI session before cancellation", account.hasLocalSession && !client.hasLocalSession)
                    account.cancelSync()
                    check("cancelSync reconciles invalidated session", !account.hasLocalSession && !account.busy && !account.syncActive && account.selectedVIN == nil && account.reading == nil)
                    check("cancelSync leaves reconnect available", !account.storageUnavailable && !account.hasLocalSession && !account.busy)
                    check("cancelSync keeps production native presentation after invalidation", account.usesNativePresentation && !account.hasLocalSession)
                } else if scenario != "refresh" {
                    await account.read(cached: true)
                    check("cache request exactly once", SyntheticProtocol.count("GET /vehicles/\(fixtureVIN)/snapshot") == 1)
                    check("no reading on failure", account.reading == nil)
                    check("only exact cache miss gets no-cache flag", account.noCachedVehicleData == (scenario == "no-cache"))
                    check("readFailed classification", account.readFailed == (scenario != "no-cache"))
                    let expected: [String: String] = ["no-cache": "服务器暂无已保存的车况数据。", "unknown404": "车况请求未成功，本次未能获取车况。", "429": "请求过于频繁", "network": "暂时无法连接服务器", "decode": "返回的车况数据无法解析"]
                    check("specific safe failure copy", account.message?.contains(expected[scenario]!) == true)
                } else {
                    check("refresh actually exercised", SyntheticProtocol.count("POST /auth/refresh") == 1)
                    await account.read(cached: false)
                    check("manual probe is displayable and read-only", probeCount == 1 && account.reading?.data?.charge_state?.battery_level == 61)
                    check("manual probe does not refresh twice", SyntheticProtocol.count("POST /auth/refresh") == 1)
                }
            }
            check("restore refresh and manual cache never wake", wakeCount == 0)
        } else {
            let selectedFlowStarted = Date()
            await account.connect(anchor: window)
            check("fresh sign-in saves local session", account.hasLocalSession)
            check("auth start exchange session exactly once", SyntheticProtocol.count("POST /auth/start") == 1 && SyntheticProtocol.count("POST /auth/exchange") == 1 && SyntheticProtocol.count("GET /session") == 1)
            if scenario == "multiple" {
                check("multiple waits for selection with zero wake", account.syncPhase == .selection && wakeCount == 0)
                account.select(fixtureVIN); account.select(fixtureVIN)
            }
            await account.connect(anchor: window)
            check("duplicate connect does not restart authentication", SyntheticProtocol.count("POST /auth/start") == 1)
            if scenario.hasPrefix("401-") {
                let ended = await wait({ !self.account.busy && !self.account.hasLocalSession && !self.account.syncPhase.spinning }, seconds: 15)
                check("401 reconciles local session promptly", ended && !account.hasLocalSession)
                check("401 root retains production native presentation without authorization", account.usesNativePresentation && !account.hasLocalSession)
                check("401 leaves no spinner or active sync", !account.busy && !account.syncActive && !account.syncPhase.spinning)
                check("401 clears selected vehicle and readings", account.selectedVIN == nil && account.reading == nil)
                check("401 provides sign-in-required message", account.message?.contains("请重新连接账号") == true)
                check("401 permits reconnect UI", !account.hasLocalSession && !account.storageUnavailable && !account.busy && !account.syncActive)
                check("401 phase-specific request count", probeCount == (scenario == "401-reading" ? 1 : 0) && SyntheticProtocol.count("GET /vehicles") == (scenario == "401-waking" ? 1 : 2))
                let before = SyntheticProtocol.snapshotCounts()
                await pause(1)
                check("401 never retries or wakes again automatically", before == SyntheticProtocol.snapshotCounts() && wakeCount == 1)
                await capture("expired-session", window: window)
                account.cancelSync()
                check("cancelSync preserves reconciled missing session", !account.hasLocalSession && !account.busy && !account.syncActive && account.selectedVIN == nil)
            } else if scenario == "cancel" || scenario == "late" || scenario == "logout" {
                _ = await wait({ self.wakeCount == 1 }, seconds: 3)
                if scenario == "logout" { await account.logout() } else { account.cancelSync() }
                await pause(6)
                check("cancelled or logged out result cannot overwrite", account.syncPhase == (scenario == "logout" ? .idle : .cancelled) && account.reading == nil)
                check("cancel prevents probe", probeCount == 0)
                if scenario == "logout" { check("logout clears local session", !account.hasLocalSession) }
            } else if scenario == "deadline-reading" {
                let reachedReading = await wait({ self.account.syncPhase == .reading }, seconds: 42)
                check("deadline fixture reaches reading after delayed wake and confirmation", reachedReading)
                await capture("deadline-reading", window: window)
                let ended = await wait({ self.account.syncPhase == .readFailed && !self.account.busy }, seconds: 32)
                let elapsed = Date().timeIntervalSince(selectedFlowStarted)
                check("hard deadline ends reading at approximately sixty seconds", ended && elapsed >= 58 && elapsed <= 70)
                check("deadline terminal has no spinner or active sync", !account.busy && !account.syncActive && !account.syncPhase.spinning)
                check("deadline never publishes live data", account.reading == nil)
                check("deadline has exactly one wake confirmation and probe", wakeCount == 1 && SyntheticProtocol.count("GET /vehicles") == 2 && probeCount == 1)
                check("deadline explains no new vehicle data", account.message?.contains("本次没有取得新的车况数据") == true)
                let counts = SyntheticProtocol.snapshotCounts()
                await pause(4)
                check("cancelled delayed probe cannot overwrite terminal or replay", account.syncPhase == .readFailed && account.reading == nil && !account.busy && SyntheticProtocol.snapshotCounts() == counts)
                await capture("deadline-terminal", window: window)
            } else if scenario == "denied" {
                let reached = await wait({ self.account.syncPhase == .denied }, seconds: 5)
                check("wake denied is explicit terminal", reached && !account.busy && !account.syncActive && !account.syncPhase.spinning)
                check("wake denied has no confirmation or probe", SyntheticProtocol.count("GET /vehicles") == 1 && probeCount == 0 && account.reading == nil)
                let counts = SyntheticProtocol.snapshotCounts()
                await pause(0.5)
                check("wake denied never retries automatically", counts == SyntheticProtocol.snapshotCounts() && wakeCount == 1)
            } else if scenario == "confirmation-error" {
                let reached = await wait({ self.account.syncPhase == .confirmationFailed && !self.account.busy }, seconds: 12)
                check("confirmation HTTP429 is failure not timeout", reached && account.syncPhase != .timeout && !account.syncActive && !account.syncPhase.spinning)
                check("confirmation error has one failed check and zero probes", SyntheticProtocol.count("GET /vehicles") == 2 && probeCount == 0 && account.reading == nil)
                let counts = SyntheticProtocol.snapshotCounts()
                await pause(0.5)
                check("confirmation error never retries or re-wakes", counts == SyntheticProtocol.snapshotCounts() && wakeCount == 1)
            } else if scenario == "unknown" {
                let reached = await wait({ self.account.syncPhase == .unknown })
                check("unknown is explicit terminal", reached && account.reading == nil && probeCount == 0)
            } else if scenario == "timeout" {
                let reached = await wait({ self.account.syncPhase == .timeout })
                check("bounded timeout", reached && account.reading == nil && probeCount == 0)
                check("exactly four read-only confirmations", SyntheticProtocol.count("GET /vehicles") == 5)
            } else {
                let waiting = await wait({ self.account.syncPhase == .waiting })
                check("waiting reached", waiting)
                await capture("waiting", window: window)
                if ["success-light", "success-dark", "success-large"].contains(scenario) {
                    let countsBeforeManualActions = SyntheticProtocol.snapshotCounts()
                    let phaseBeforeManualActions = account.syncPhase
                    let vinBeforeManualActions = account.selectedVIN
                    await account.loadVehicles()
                    await account.read(cached: false)
                    await account.read(cached: true)
                    account.select(fixtureVIN)
                    check("waiting blocks actual manual list probe snapshot and selection methods", SyntheticProtocol.snapshotCounts() == countsBeforeManualActions)
                    check("waiting manual actions preserve phase and selected VIN", phaseBeforeManualActions == .waiting && account.syncPhase == .waiting && account.selectedVIN == vinBeforeManualActions && vinBeforeManualActions == fixtureVIN)
                    check("waiting manual actions publish no reading or extra wake probe", account.reading == nil && wakeCount == 1 && probeCount == 0)
                    let countsBeforeViewToggle = SyntheticProtocol.snapshotCounts()
                    accountPage = true
                    await capture("account-waiting", window: window)
                    accountPage = false
                    await pause(0.2)
                    check("shared account page remains waiting while switching views", account.syncPhase == .waiting && account.hasLocalSession)
                    check("view toggles never authenticate or wake again", SyntheticProtocol.snapshotCounts() == countsBeforeViewToggle && SyntheticProtocol.count("POST /auth/start") == 1 && wakeCount == 1)
                }
                let reading = await wait({ self.account.syncPhase == .reading })
                check("reading reached after confirmation", reading)
                await capture("reading", window: window)
                let success = await wait({ self.account.syncPhase == .success })
                check("live displayable success", success && account.reading?.origin == .liveRead && account.reading?.data?.charge_state?.battery_level == 61)
                check("missing fields remain unknown", account.reading?.data?.climate_state == nil)
                check("exactly one confirmation and one probe", SyntheticProtocol.count("GET /vehicles") == 2 && probeCount == 1)
                await capture("success", window: window)
                if ["success-light", "success-dark", "success-large"].contains(scenario) {
                    await captureScrollPages("success-viewport", window: window)
                    check("success viewport scrolling preserves battery61 and unknown fields", account.syncPhase == .success && account.reading?.data?.charge_state?.battery_level == 61 && account.reading?.data?.climate_state == nil)
                }
            }
            check("exactly one login-sync dispatch", wakeCount == 1)
            if scenario != "logout" && !scenario.hasPrefix("401-") { await account.connect(anchor: window); await pause(0.2) }
            check("terminal state has no second wake dispatch", wakeCount == 1)
        }
        await capture("terminal", window: window)
        accountPage = true
        await capture("account", window: window)
        if scenario == "401-reading" {
            await captureScrollPages("account-reconnect-viewport", window: window)
            check("expired account scrolling preserves empty session and readings", !account.hasLocalSession && !account.busy && !account.syncActive && account.reading == nil && account.selectedVIN == nil)
        }
        let blocked = SyntheticProtocol.unknownRoutes()
        check("no unknown URL allowed", blocked.isEmpty)
        let report: [String: Any] = ["synthetic": true, "scenario": scenario, "result": checks.allSatisfy { $0["passed"] as? Bool == true } ? "pass" : "fail", "assertions": checks, "counts": SyntheticProtocol.snapshotCounts(), "screenshots": captured.sorted(), "scrollViewports": scrollEvidence, "limits": "Synthetic URLProtocol only; no real Tesla, browser, Keychain or server atomicity proof. Cancellation test uses URLSession cancellation, not forced delivery after cancellation."]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: documents.appendingPathComponent("assertions.json"), options: .atomic) } catch { print("Fixture report write failed: \(error)") }
    }
    var wakeCount: Int { SyntheticProtocol.count("POST /vehicles/\(fixtureVIN)/login-sync") }
    var probeCount: Int { SyntheticProtocol.count("POST /vehicles/\(fixtureVIN)/probe") }
}

private struct FixtureWindowReader: UIViewRepresentable {
    let driver: FixtureDriver
    func makeUIView(context: Context) -> WindowView { WindowView(driver: driver) }
    func updateUIView(_ uiView: WindowView, context: Context) {}
    final class WindowView: UIView {
        let driver: FixtureDriver
        init(driver: FixtureDriver) { self.driver = driver; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            Task { @MainActor in
                for _ in 0..<100 {
                    if window.isKeyWindow && window.windowScene?.activationState == .foregroundActive { await driver.run(window: window); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
}

@main private struct LoginWakeFixtureApp: App {
    @State private var driver = FixtureDriver()
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                Text("合成验证 · 不连接真实车辆").font(.caption.bold()).padding(6).frame(maxWidth: .infinity).background(.yellow.opacity(0.3))
                if driver.accountPage {
                    NavigationStack { AccountView() }
                } else {
                    // PonyTabs is appended VERBATIM from production by run.py.
                    PonyTabs()
                }
            }
            .environment(driver.account)
            .environment(store)
            .preferredColorScheme(driver.scenario == "success-dark" ? .dark : .light)
            .dynamicTypeSize(driver.scenario == "success-large" ? .accessibility3 : .large)
            .background(FixtureWindowReader(driver: driver).frame(width: 0, height: 0))
        }
    }
}
