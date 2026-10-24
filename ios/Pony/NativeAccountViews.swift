import SwiftUI
import Observation
import AuthenticationServices
import PonyCore

/// The only owner of native UI state. Construction reads Keychain, never the network.
@MainActor @Observable
final class NativeAccountState {
    private(set) var hasLocalSession = false
    private(set) var storageUnavailable = false
    private(set) var busy = false
    private(set) var vehicles: [ReadOnlyVehicleIdentity] = []
    private(set) var listLoaded = false
    private(set) var selectedVIN: String?
    private(set) var reading: ReadOnlyVehicleData?
    private(set) var readFailed = false
    private(set) var noCachedVehicleData = false
    private(set) var message: String?
    // Presentation evidence only; neither flag initiates I/O or changes flow admission.
    private var loginInvalidated = false
    /// A confirmed invalid native login must never silently become a demo vehicle.
    var usesNativePresentation: Bool { hasLocalSession || loginInvalidated }
    private var readDeadlineEnded = false
    var hasVehicleDisplayValues: Bool {
        let data = reading?.data
        return data?.charge_state?.battery_level != nil || data?.charge_state?.battery_range != nil
            || data?.climate_state?.inside_temp != nil || data?.climate_state?.outside_temp != nil
            || data?.vehicle_state?.odometer != nil
    }
    var hasChargingDisplayValues: Bool {
        let charge = reading?.data?.charge_state
        return charge?.battery_level != nil || charge?.charge_limit_soc != nil || charge?.charger_power != nil
            || ["Charging", "Complete", "Stopped", "Disconnected", "NoPower"].contains(charge?.charging_state ?? "")
    }
    var hasDisplayableReading: Bool { hasVehicleDisplayValues || hasChargingDisplayValues }
    var hasTerminalUpdateAttempt: Bool {
        loginInvalidated || [SyncPhase.timeout, .unknown, .denied, .readFailed, .cancelled, .confirmationFailed].contains(syncPhase)
    }
    var syncDetail: String {
        if syncPhase == .readFailed {
            return readDeadlineEnded ? "等待已结束，本次未取得最新车况。" : "本次未取得最新车况。"
        }
        return syncPhase.detail
    }
    let history = NativeHistoryStore()
    @ObservationIgnored private var client: NativeTeslaClient?

    var selectedVehicle: ReadOnlyVehicleIdentity? {
        guard let selectedVIN else { return nil }
        return vehicles.first { $0.vin == selectedVIN }
    }

    init() { loadLocalSession() }
    init(client: NativeTeslaClient) {
        self.client = client
        hasLocalSession = client.hasLocalSession
    }

    enum SyncPhase: String, Sendable {
        case idle, listing, selection, waking, waiting, reading, success, timeout, unknown, denied
        case noVehicles, listFailed, readFailed, unsupported, cancelled, confirmationFailed
        var title: String {
            switch self {
            case .idle: ""
            case .listing: "正在获取车辆列表…"
            case .selection: "选择要更新车况的车辆"
            case .waking: "正在发送唤醒请求…"
            case .waiting: "唤醒请求已发送"
            case .reading: "车辆已在线，正在读取车况…"
            case .success: "车况已更新"
            case .timeout, .confirmationFailed: "暂未确认车辆上线"
            case .unknown: "唤醒结果尚未确认"
            case .denied: "未能唤醒车辆"
            case .noVehicles: "未找到已授权车辆"
            case .listFailed: "未能获取车辆列表"
            case .readFailed: "未能更新车况"
            case .unsupported: "当前服务未开放登录后更新车况"
            case .cancelled: "已停止等待，本次车况更新未完成。"
            }
        }
        var detail: String {
            switch self {
            case .listing, .listFailed, .noVehicles: "尚未发起车辆唤醒。"
            case .selection: "选定后，将对这辆车发起一次唤醒请求，并尝试更新车况。"
            case .waking: "本次登录只发起一次，不会因切换页面重复发送。"
            case .waiting: "正在等待车辆上线，尚未获取最新车况。"
            case .reading: "尚未完成车况更新。"
            case .success: "仅更新本次可取得的字段，缺失字段保持未知。"
            case .timeout: "本次车况尚未更新，未再次发送唤醒请求。"
            case .confirmationFailed: "唤醒请求已发送，但未能确认车辆在线。本次未再次发送唤醒请求。"
            case .unknown: "尚未确认唤醒结果，不会自动再次发送请求。"
            case .cancelled: "车辆请求的执行结果尚未确认。"
            case .denied: "本次车况尚未更新。"
            case .readFailed: "本次未取得最新车况。"
            case .unsupported: "可使用手动只读入口，不会发起唤醒。"
            case .idle: ""
            }
        }
        var spinning: Bool { [.listing, .waking, .waiting, .reading].contains(self) }
    }
    private(set) var syncPhase: SyncPhase = .idle {
        didSet {
            if syncPhase != .readFailed { readDeadlineEnded = false }
            if oldValue != syncPhase, syncPhase != .idle {
                UIAccessibility.post(notification: .announcement, argument: syncPhase.title + "。" + syncDetail)
            }
        }
    }
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncGeneration = UUID()
    @ObservationIgnored private var freshSelectionIntent = false
    var syncActive: Bool { syncPhase.spinning || freshSelectionIntent }

    func cancelSync() {
        syncGeneration = UUID(); freshSelectionIntent = false
        syncTask?.cancel(); syncTask = nil
        client?.cancelPendingLogin()
        syncPhase = .cancelled
        finish()
    }

    /// Fresh interactive sign-in is the sole caller. Views/restore/refresh never enter here.
    private func freshLoginSync() async {
        guard let client else { return }
        let generation = syncGeneration
        let accountID = client.accountID
        syncPhase = .listing
        do {
            let info = try await client.sessionInfo()
            guard generation == syncGeneration, client.accountID == accountID else { return }
            let list = try await client.vehicles()
            guard generation == syncGeneration, client.accountID == accountID else { return }
            vehicles = list; listLoaded = true
            if list.isEmpty { syncPhase = .noVehicles; return }
            guard info.features.login_sync == true else { syncPhase = .unsupported; return }
            freshSelectionIntent = true
            if list.count == 1 { beginSelectedSync(list[0].vin) }
            else if let selectedVIN, list.contains(where: { $0.vin == selectedVIN }) { beginSelectedSync(selectedVIN) }
            else { syncPhase = .selection }
        } catch {
            guard generation == syncGeneration else { return }
            syncPhase = .listFailed; report(error)
        }
    }

    private func beginSelectedSync(_ vin: String) {
        guard freshSelectionIntent, let client else { return }
        freshSelectionIntent = false // consume BEFORE any network suspension
        selectedVIN = vin; busy = true
        let generation = syncGeneration
        let accountID = client.accountID
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        syncTask = Task { @MainActor in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.runSelectedSync(vin: vin, generation: generation, accountID: accountID, deadline: deadline)
                    }
                    group.addTask {
                        try await self.expireSelectedSync(vin: vin, generation: generation, deadline: deadline)
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
            } catch {
                // Terminal ownership is generation + VIN. Credentials may have been cleared
                // by this very request's 401/refresh failure; that must not skip cleanup.
                guard self.syncGeneration == generation, self.selectedVIN == vin else { return }
                if !Task.isCancelled, self.syncPhase.spinning { self.syncFailed(error) }
            }
            guard self.syncGeneration == generation else { return }
            self.syncTask = nil; self.finish()
        }
    }
    /// Actor-isolated implementation; task-group closures only cross the actor boundary
    /// with Sendable values rather than using explicitly isolated closure captures.
    private func expireSelectedSync(vin: String, generation: UUID, deadline: ContinuousClock.Instant) async throws {
        try await ContinuousClock().sleep(until: deadline)
        guard syncGeneration == generation, selectedVIN == vin else { throw CancellationError() }
        guard syncPhase.spinning else { return }
        if client?.hasLocalSession == true { syncFailed(SyncDeadline.expired) }
        else { syncFailed(NativeTeslaError.signInRequired) }
        finish()
        // Invalidate before allowing new manual actions: an old task's cleanup
        // must not clear the busy flag or overwrite a later manual read.
        syncGeneration = UUID()
        syncTask = nil
        busy = false
        throw SyncDeadline.expired
    }

    private enum SyncDeadline: Error { case expired }
    private func syncFailed(_ error: Error) {
        if client?.hasLocalSession != true {
            syncPhase = syncPhase == .reading ? .readFailed : .unknown
            report(error)
            return
        }
        switch syncPhase {
        case .reading:
            readDeadlineEnded = error is SyncDeadline
            syncPhase = .readFailed
            if error is SyncDeadline { message = "读取车况等待已结束，本次没有取得新的车况数据。" }
            else { reportRead(error) }
        case .waiting:
            syncPhase = error is SyncDeadline ? .timeout : .confirmationFailed
        default:
            syncPhase = .unknown
        }
    }
    private func runSelectedSync(vin: String, generation: UUID, accountID: String?, deadline: ContinuousClock.Instant) async throws {
        guard let client else { return }
        func check() throws {
            try Task.checkCancellation()
            guard generation == syncGeneration, client.accountID == accountID, selectedVIN == vin else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw SyncDeadline.expired }
        }
        try check(); syncPhase = .waking
        let phase = try await client.loginSync(vin: vin)
        try check()
        switch phase {
        case .wake_unknown: syncPhase = .unknown; return
        case .wake_denied: syncPhase = .denied; return
        case .not_eligible: syncPhase = .unsupported; return
        case .online: break
        case .wake_accepted:
            syncPhase = .waiting
            var online = false
            // Exactly four read-only confirmations, separated by at least five seconds.
            for _ in 0..<4 {
                try await Task.sleep(for: .seconds(5))
                try check()
                let list = try await client.vehicles()
                try check()
                if list.first(where: { $0.vin == vin })?.state == "online" { online = true; break }
            }
            guard online else { syncPhase = .timeout; return }
        }
        try check(); syncPhase = .reading
        let result = try await client.probe(vin: vin)
        try check()
        let data = result.data
        // Only fields actually shown by these screens count, not empty sections or metadata.
        let displayable = data?.charge_state?.battery_level != nil || data?.charge_state?.battery_range != nil
            || data?.charge_state?.charge_limit_soc != nil || data?.charge_state?.charger_power != nil
            || data?.climate_state?.inside_temp != nil || data?.climate_state?.outside_temp != nil
            || data?.vehicle_state?.odometer != nil
            || ["Charging", "Complete", "Stopped", "Disconnected", "NoPower"].contains(data?.charge_state?.charging_state ?? "")
        guard result.origin == .liveRead, displayable else { syncPhase = .readFailed; return }
        reading = result; readFailed = false; noCachedVehicleData = false
        syncPhase = .success
    }

    func loadLocalSession() {
        guard !busy, !syncActive else { return }
        history.invalidate()
        do {
            client = try NativeTeslaClient()
            hasLocalSession = client?.hasLocalSession == true
            storageUnavailable = false
            message = nil
        } catch {
            // Do not replace/delete unreadable Keychain evidence or start a new authorization.
            storageUnavailable = true
            message = "无法读取安全会话存储。请解锁设备后重试；原有存储未被清除。"
        }
    }

    var status: String {
        if storageUnavailable { return "安全存储需要重试" }
        if loginInvalidated { return "登录已失效" }
        if !hasLocalSession { return "账号未连接" }
        return "已保存登录信息"
    }

    func connect(anchor: UIWindow?) async {
        guard !busy, !storageUnavailable, !hasLocalSession, let client else { return }
        guard let anchor, anchor.isKeyWindow, anchor.windowScene?.activationState == .foregroundActive else {
            message = "当前窗口尚未就绪，请返回此页面后重试。"; return
        }
        busy = true; message = nil
        syncGeneration = UUID()
        let generation = syncGeneration
        defer { if generation == syncGeneration { finish() } }
        do {
            try await client.signIn(anchor: anchor)
            guard generation == syncGeneration else { return }
            loginInvalidated = false
            hasLocalSession = client.hasLocalSession
            syncTask = Task { @MainActor in await self.freshLoginSync() }
            await syncTask?.value
        } catch NativeTeslaError.signInRequired {
            guard generation == syncGeneration else { return }
            // No existing session was used by this operation. A legacy server may
            // challenge the new route; that is not an expired owner session.
            message = "手机连接请求尚未获准，未完成授权。服务可能尚未更新，请稍后手动重试。"
        } catch { if generation == syncGeneration { report(error) } }
    }

    func loadVehicles() async {
        guard !busy, !syncActive, hasLocalSession, !storageUnavailable, let client else { return }
        history.invalidate()
        busy = true; message = nil
        // A fresh list is a new selection boundary; never retain a removed vehicle's data.
        clearVehicleData(); vehicles = []; listLoaded = false
        syncPhase = .idle
        let generation = syncGeneration
        defer { if generation == syncGeneration { finish() } }
        do {
            let list = try await client.vehicles()
            guard generation == syncGeneration else { return }
            vehicles = list; listLoaded = true
        } catch { if generation == syncGeneration { report(error) } }
    }

    func select(_ vin: String) {
        guard hasLocalSession, vehicles.contains(where: { $0.vin == vin }) else { return }
        if freshSelectionIntent { beginSelectedSync(vin); return }
        guard !busy else { return }
        syncGeneration = UUID(); syncPhase = .idle
        history.invalidate()
        clearVehicleData(); selectedVIN = vin; message = nil
    }

    func read(cached: Bool) async {
        guard !busy, !syncActive, hasLocalSession, !storageUnavailable, let vin = selectedVIN, let client else { return }
        busy = true; message = nil; readFailed = false; noCachedVehicleData = false
        // Do not silently fall back to either a previous live result or demo data.
        reading = nil; syncPhase = .idle
        let generation = syncGeneration
        let accountID = client.accountID
        defer { if generation == syncGeneration { finish() } }
        do {
            let result: ReadOnlyVehicleData
            if cached { result = try await client.snapshot(vin: vin) }
            else { result = try await client.probe(vin: vin) }
            guard generation == syncGeneration, selectedVIN == vin, client.accountID == accountID else { return }
            reading = result
            if let reading, reading.hasConfirmedNonOnlineState {
                message = "车辆当前不在线，本次未读取实时车况。"
            }
        }
        catch { if generation == syncGeneration { reportRead(error) } }
    }

    func refreshHistory(_ kind: NativeHistoryKind) async {
        guard !busy, !syncActive, hasLocalSession, !storageUnavailable, let vin = selectedVIN, let client else { return }
        busy = true; message = nil
        let generation = syncGeneration
        defer { if generation == syncGeneration { finish() } }
        do { try await history.refresh(kind: kind, vin: vin, client: client) }
        catch { if generation == syncGeneration { report(error) } }
    }

    func loadMoreHistory(_ kind: NativeHistoryKind) async {
        guard !busy, !syncActive, hasLocalSession, !storageUnavailable, let vin = selectedVIN, let client else { return }
        busy = true; message = nil
        let generation = syncGeneration
        defer { if generation == syncGeneration { finish() } }
        do { try await history.loadMore(kind: kind, vin: vin, client: client) }
        catch { if generation == syncGeneration { report(error) } }
    }

    func loadHistoryDetail(_ record: NativeHistoryRecord) async {
        guard !busy, !syncActive, hasLocalSession, !storageUnavailable, let vin = selectedVIN,
              record.vin == vin, let client else { return }
        busy = true; message = nil
        let generation = syncGeneration
        defer { if generation == syncGeneration { finish() } }
        do { try await history.loadDetail(record: record, vin: vin, client: client) }
        catch { if generation == syncGeneration { report(error) } }
    }

    func logout() async {
        guard let client else { return }
        loginInvalidated = false
        if syncActive { cancelSync() }
        syncGeneration = UUID(); syncPhase = .idle
        history.invalidate()
        busy = true; message = nil
        clearVehicleData(); vehicles = []; listLoaded = false
        defer { finish() }
        do {
            let outcome = try await client.logout()
            message = outcome.serverSessionRevoked
                ? "已退出本机，服务器已确认撤销本次应用会话。未撤销 Tesla 授权，也未删除服务器数据。"
                : "已清除本机会话，但未能确认服务器撤销。未撤销 Tesla 授权，也未删除服务器数据。"
        } catch { report(error) }
    }

    private func clearVehicleData() { selectedVIN = nil; reading = nil; readFailed = false; noCachedVehicleData = false }
    private func finish() {
        hasLocalSession = client?.hasLocalSession == true
        if !hasLocalSession { freshSelectionIntent = false; history.invalidate(); clearVehicleData(); vehicles = []; listLoaded = false }
        busy = syncPhase.spinning
    }
    /// Only explicit vehicle reads use these labels; auth/keychain/rate handling stays shared.
    private func reportRead(_ error: Error) {
        readFailed = true
        if error is ReadOnlyVehicleDataError {
            message = "返回的车况数据无法解析，本次未能显示车况。"
            return
        }
        switch error as? NativeTeslaError {
        case .noCachedVehicleData:
            readFailed = false
            noCachedVehicleData = true
            message = "服务器暂无已保存的车况数据。"
        case .networkUnavailable:
            message = "暂时无法连接服务器，本次未能获取车况。"
        case .unavailable:
            message = "车况请求未成功，本次未能获取车况。"
        case .invalidResponse, .responseTooLarge:
            message = "返回的车况数据无法解析，本次未能显示车况。"
        default: report(error)
        }
    }
    private func report(_ error: Error) {
        switch error as? NativeTeslaError {
        case .keychainUnavailable:
            storageUnavailable = true
            message = "安全存储操作未完成，不能确认退出或保存成功。请解锁设备后重试读取；不会自动清除原有存储。"
        case .cancelled: message = "已取消授权。只有再次点击连接才会重新开始。"
        case .signInRequired:
            loginInvalidated = true
            message = "应用会话已失效，请重新连接账号。"
        case .rateLimited: message = "请求过于频繁，请稍后手动重试。车辆探测至少间隔 15 秒。"
        default: message = "本次请求未完成，服务可能尚未开放、网络不可用或没有可用数据。请稍后手动重试。"
        }
    }
}

@MainActor private final class AccountWindowReference {
    weak var window: UIWindow?
    var activeKeyWindow: UIWindow? {
        guard let scene = window?.windowScene, scene.activationState == .foregroundActive else { return nil }
        return scene.windows.first(where: \.isKeyWindow)
    }
}

/// Resolve the scene containing this view, not an arbitrary UIApplication scene.
private struct AccountWindowReader: UIViewRepresentable {
    let reference: AccountWindowReference
    func makeUIView(context: Context) -> WindowView { WindowView(reference: reference) }
    func updateUIView(_ uiView: WindowView, context: Context) { reference.window = uiView.window }
    final class WindowView: UIView {
        let reference: AccountWindowReference
        init(reference: AccountWindowReference) { self.reference = reference; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() { super.didMoveToWindow(); reference.window = window }
    }
}


/// Approved full-opacity secondary text, independent of platform secondary-label blending.
private enum NativeAccountPalette {
    static var secondaryText: Color {
        Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 152.0 / 255, green: 152.0 / 255, blue: 159.0 / 255, alpha: 1)
            }
            return UIColor(red: 99.0 / 255, green: 99.0 / 255, blue: 102.0 / 255, alpha: 1)
        })
    }
}

/// LabeledContent's implicit value tint is not the approved contrast-safe text color.
private struct NativeLabeledValue: View {
    let label: String
    let value: String
    init(_ label: String, value: String) { self.label = label; self.value = value }
    var body: some View {
        LabeledContent {
            Text(value).foregroundStyle(NativeAccountPalette.secondaryText)
        } label: {
            Text(label).foregroundStyle(.primary)
        }
    }
}

/// One component, one account-owned source of truth on both pages. No appearance side effects.
struct NativeLoginSyncSection: View {
    @Environment(NativeAccountState.self) private var account
    var body: some View {
        if account.syncPhase != .idle {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let vehicle = account.selectedVehicle {
                        Text(vehicle.normalizedDisplayName ?? "已选授权车辆")
                    }
                    HStack(alignment: .top, spacing: 8) {
                        if account.syncPhase.spinning { ProgressView().accessibilityHidden(true) }
                        else { Image(systemName: symbol).accessibilityHidden(true) }
                        Text(account.syncPhase.title).font(.headline)
                    }
                    Text(account.syncDetail).font(.subheadline).foregroundStyle(NativeAccountPalette.secondaryText)
                    if account.syncPhase == .success, let received = account.reading?.receivedAt {
                        Text("本次读取完成于\(received.formatted(date: .abbreviated, time: .standard))")
                            .font(.footnote).foregroundStyle(NativeAccountPalette.secondaryText)
                    }
                    if account.syncActive {
                        Button("停止等待", role: .cancel) { account.cancelSync() }
                            .frame(minHeight: 44)
                        Text("停止等待不会撤回已发送的唤醒请求。")
                            .font(.footnote).foregroundStyle(NativeAccountPalette.secondaryText)
                    }
                }
            } header: { Text("更新车况").foregroundStyle(NativeAccountPalette.secondaryText) }
        }
    }
    private var symbol: String {
        switch account.syncPhase {
        case .success: "checkmark.circle"
        case .selection: "car"
        case .timeout: "clock.badge.exclamationmark"
        case .denied, .readFailed, .listFailed: "exclamationmark.circle"
        default: "questionmark.circle"
        }
    }
}

struct AccountView: View {
    @Environment(NativeAccountState.self) private var account
    @State private var windowReference = AccountWindowReference()
    @State private var confirmingLogout = false
    var body: some View {
        Form {
            Section {
                Text(account.status)
                Text("应用会话、车辆列表与车辆数据是不同状态。恢复已有登录信息时，不会自动访问服务器，也不会自动读取或唤醒车辆。")
                    .font(.footnote).foregroundStyle(NativeAccountPalette.secondaryText)
                if account.busy && !account.syncActive { ProgressView("正在处理本次请求…") }
                if let message = account.message { Text(message).foregroundStyle(NativeAccountPalette.secondaryText) }
            } header: { Text("当前账号").foregroundStyle(NativeAccountPalette.secondaryText) }
            NativeLoginSyncSection()
            if account.busy && !account.hasLocalSession {
                Section { Button("取消本次连接", role: .cancel) { account.cancelSync() } }
            }
            if account.storageUnavailable {
                Section { Button("重试读取安全存储") { account.loadLocalSession() }.disabled(account.busy || account.syncActive) }
            } else if !account.hasLocalSession {
                Section {
                    Button("使用 Tesla 账号连接", systemImage: "key") {
                        Task { await account.connect(anchor: windowReference.activeKeyWindow) }
                    }.disabled(account.busy)
                } footer: { Text("登录成功后，如服务支持，将获取授权车辆列表；确定目标车辆后发起一次车辆唤醒请求，并尝试更新车况。其他车辆控制不开放。唤醒需要 Tesla 的车辆控制权限，该权限也涵盖解锁等操作。Pony 本次仅使用它完成登录后的一次唤醒，不开放其他控制操作。").foregroundStyle(NativeAccountPalette.secondaryText) }
            } else {
                NativeVehicleSelectionSection()
                Section {
                    Button("退出当前应用会话", role: .destructive) { confirmingLogout = true }.disabled(account.busy || account.syncActive)
                    Text("退出不等于撤销 Tesla 授权或删除账号。当前未提供服务器账号删除功能。")
                        .font(.footnote).foregroundStyle(NativeAccountPalette.secondaryText)
                } header: { Text("退出").foregroundStyle(NativeAccountPalette.secondaryText) }
            }
        }
        .background(AccountWindowReader(reference: windowReference).frame(width: 0, height: 0))
        .navigationTitle("账号与授权")
        .confirmationDialog("退出当前应用会话？", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("退出会话", role: .destructive) { Task { await account.logout() } }
        } message: { Text("会清除本机会话并尝试撤销服务器应用会话。不会删除数据或撤销 Tesla 官方授权。").foregroundStyle(NativeAccountPalette.secondaryText) }
    }
}

private struct NativeVehicleSelectionSection: View {
    @Environment(NativeAccountState.self) private var account
    var body: some View {
        Section {
            Button(account.listLoaded ? "重新加载授权车辆列表" : "加载授权车辆列表", systemImage: "list.bullet") {
                Task { await account.loadVehicles() }
            }.disabled(account.busy || account.syncActive)
            if account.listLoaded && account.vehicles.isEmpty { Text("未找到此账号可访问的车辆。") }
            ForEach(Array(account.vehicles.enumerated()), id: \.element.vin) { index, vehicle in
                Button {
                    account.select(vehicle.vin)
                } label: {
                    HStack {
                        if let name = vehicle.normalizedDisplayName {
                            Text(name)
                        } else {
                            Text("授权车辆 \(index + 1)")
                        }
                        Spacer()
                        if account.selectedVIN == vehicle.vin { Image(systemName: "checkmark") }
                    }
                }
            }.disabled(account.busy)
            if account.selectedVIN != nil {
                Button("读取车况（不唤醒）", systemImage: "arrow.clockwise") { Task { await account.read(cached: false) } }.disabled(account.busy || account.syncActive)
                Button("查看服务器缓存快照", systemImage: "clock") { Task { await account.read(cached: true) } }.disabled(account.busy || account.syncActive)
            }
        } header: { Text("授权车辆与手动读取").foregroundStyle(NativeAccountPalette.secondaryText) } footer: {
            Text("恢复已有登录信息不会自动更新或唤醒车辆；仅新登录成功后的更新流程会对选定车辆发起一次唤醒请求。此处手动读取和缓存入口不会唤醒车辆。缓存可能不存在或已过期。").foregroundStyle(NativeAccountPalette.secondaryText)
        }
    }
}

struct NativeVehicleStatusView: View {
    @Environment(NativeAccountState.self) private var account
    var body: some View {
        List {
            Section {
                Text(account.status)
                NavigationLink("账号与车辆授权") { AccountView() }
                if let message = account.message { Text(message).font(.footnote).foregroundStyle(NativeAccountPalette.secondaryText) }
            } header: { Text("账号与车况").foregroundStyle(NativeAccountPalette.secondaryText) }
            NativeLoginSyncSection()
            NativeReadingSourceSection()
            Section {
                if !account.hasVehicleDisplayValues { Text("暂无可显示的车况数据") }
                NativeLabeledValue("电量", value: nativeNumber(account.reading?.data?.charge_state?.battery_level, unit: "%"))
                NativeLabeledValue("预计续航", value: nativeNumber(account.reading?.data?.charge_state?.batteryRangeKilometres, unit: "公里"))
                NativeLabeledValue("车内温度", value: nativeNumber(account.reading?.data?.climate_state?.inside_temp, unit: "℃"))
                NativeLabeledValue("车外温度", value: nativeNumber(account.reading?.data?.climate_state?.outside_temp, unit: "℃"))
                NativeLabeledValue("里程表", value: nativeNumber(account.reading?.data?.vehicle_state?.odometer.map { $0 * 1.609344 }, unit: "公里"))
                NativeLabeledValue("门锁与车门", value: "未知")
            } header: { Text(account.hasVehicleDisplayValues ? "上次状态" : "车况").foregroundStyle(NativeAccountPalette.secondaryText) }
            Section { Text("缺失字段保持未知。一次读取不代表持续在线；除新登录后的一次唤醒外，没有其他车辆控制或持续遥测采集。").foregroundStyle(NativeAccountPalette.secondaryText) }
        }.navigationTitle(
            (account.selectedVehicle?.normalizedDisplayName).map { Text($0) } ?? Text("车辆")
        )
    }
}

private struct NativeReadingSourceSection: View {
    @Environment(NativeAccountState.self) private var account
    var body: some View {
        Section {
            NativeLabeledValue("本次结果", value: origin)
            if let reading = account.reading, account.hasDisplayableReading {
                NativeLabeledValue("服务器获取时间", value: date(reading.fetchedAt))
                NativeLabeledValue("本机接收时间", value: date(reading.receivedAt))
                NativeLabeledValue("电池源时间", value: date(reading.sourceTimestamp(for: .charge)))
                NativeLabeledValue("温度源时间", value: date(reading.sourceTimestamp(for: .climate)))
                NativeLabeledValue("里程源时间", value: date(reading.sourceTimestamp(for: .vehicle)))
                // Local presentation clock only: never refreshes or probes the vehicle.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("电池字段：\(freshness(reading, section: .charge, at: context.date))")
                        Text("温度字段：\(freshness(reading, section: .climate, at: context.date))")
                        Text("里程字段：\(freshness(reading, section: .vehicle, at: context.date))")
                        Text("仅展示上次读取值；源时间缺失、位于未来或无法验证时，新鲜度未知。缓存始终非实时，不因本机时间更新而变为实时。")
                    }
                    .font(.footnote)
                    .foregroundStyle(NativeAccountPalette.secondaryText)
                }
                if reading.origin == .cachedSnapshot {
                    NativeLabeledValue("服务器缓存标记", value: reading.cacheStale.map { $0 ? "已过期" : "未标记过期（不代表实时）" } ?? "未知")
                }
            }
        } header: { Text("数据来源与时间").foregroundStyle(NativeAccountPalette.secondaryText) }
    }
    private var origin: String {
        if account.reading == nil && account.hasTerminalUpdateAttempt { return "未取得最新车况" }
        if account.noCachedVehicleData { return "暂无车况缓存" }
        if account.readFailed { return "本次读取失败 · 当前状态未知" }
        switch account.reading?.origin {
        case .liveRead: return account.hasDisplayableReading ? "本次车辆读取 · 非持续在线" : "未取得最新车况"
        case .cachedSnapshot: return "上次状态 · 服务器缓存 · 非实时"
        case .noLiveData: return account.reading?.hasConfirmedNonOnlineState == true ? "车辆不在线" : "未取得实时数据"
        case nil: return "尚未读取 · 未知"
        }
    }
    private func freshness(_ reading: ReadOnlyVehicleData, section: ReadOnlyVehicleData.Section, at now: Date) -> String {
        let prefix = reading.origin == .cachedSnapshot ? "缓存 · 非实时 · " : ""
        switch reading.freshness(of: section, at: now) {
        case .fresh: return prefix + "源时间在最近 2 分钟内，非持续在线保证"
        case .stale: return prefix + "源数据已超过 2 分钟，不代表当前状态"
        case .unknown: return prefix + "新鲜度未知，不代表当前状态"
        }
    }
    private func date(_ value: Date?) -> String { value?.formatted(date: .abbreviated, time: .standard) ?? "未知" }
}

struct NativeTripsUnavailableView: View {
    var body: some View {
        List {
            Section {
                ContentUnavailableView {
                    Label("尚未采集真实行程", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } description: {
                    Text("本阶段仅支持手动只读车辆状态。尚未接入持续采集与真实行程历史；没有记录不代表车辆未行驶。")
                        .foregroundStyle(NativeAccountPalette.secondaryText)
                }
            }
            Section { Text("演示行程与导出仍可在“我的 → 演示功能与设置”查看，不会作为真实账号记录展示。").foregroundStyle(NativeAccountPalette.secondaryText) }
        }.navigationTitle("行程")
    }
}

struct NativeChargingStatusView: View {
    @Environment(NativeAccountState.self) private var account
    var body: some View {
        List {
            NativeReadingSourceSection()
            Section {
                if !account.hasChargingDisplayValues { Text("暂无可显示的充电状态数据") }
                NativeLabeledValue("电量", value: nativeNumber(account.reading?.data?.charge_state?.battery_level, unit: "%"))
                NativeLabeledValue("充电上限", value: nativeNumber(account.reading?.data?.charge_state?.charge_limit_soc, unit: "%"))
                NativeLabeledValue("充电功率", value: nativeNumber(account.reading?.data?.charge_state?.charger_power, unit: "kW"))
                NativeLabeledValue("充电状态", value: chargeStatus)
                NavigationLink("前往手动读取") { AccountView() }
            } header: { Text(account.hasChargingDisplayValues ? "上次充电状态 · 只读" : "充电状态 · 只读").foregroundStyle(NativeAccountPalette.secondaryText) }
            NativeChargeHistorySection()
        }.navigationTitle("充电")
    }
    private var chargeStatus: String {
        switch account.reading?.data?.charge_state?.charging_state {
        case "Charging": "充电中"
        case "Complete": "充电完成"
        case "Stopped": "已停止"
        case "Disconnected": "未连接充电设备"
        case "NoPower": "未供电"
        default: "未知"
        }
    }
}

private func nativeNumber(_ value: Double?, unit: String) -> String {
    guard let value else { return "未知" }
    return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
}
