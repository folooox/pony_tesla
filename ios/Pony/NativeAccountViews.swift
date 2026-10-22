import SwiftUI
import Observation
import AuthenticationServices
import PonyCore

/// The only owner of native UI state. Construction reads Keychain, never the network.
@MainActor @Observable
final class NativeAccountState {
    private(set) var hasLocalSession = false
    private(set) var sessionConfirmed = false
    private(set) var pairingCode: String?
    private(set) var pairingDeadline: Date?
    private(set) var storageUnavailable = false
    private(set) var busy = false
    private(set) var vehicles: [ReadOnlyVehicleIdentity] = []
    private(set) var listLoaded = false
    private(set) var selectedVIN: String?
    private(set) var reading: ReadOnlyVehicleData?
    private(set) var readFailed = false
    private(set) var message: String?
    let history = NativeHistoryStore()
    @ObservationIgnored private var privacy = NativePrivacyEpoch()
    @ObservationIgnored private var validationQueued = false
    @ObservationIgnored private var client: NativeTeslaClient?

    init() { loadLocalSession() }

    func loadLocalSession() {
        guard !busy else { return }
        hidePrivateData()
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
        if sessionConfirmed { return "设备已配对" }
        if hasLocalSession { return "本机已保存会话 · 尚未确认有效" }
        if pairingCode != nil { return "等待你在后台确认" }
        return "尚未配对"
    }

    func preparePairing() async {
        guard !busy, !storageUnavailable, !hasLocalSession, let client else { return }
        busy = true; message = nil
        defer { finish() }
        do { try await client.preparePairing() }
        catch { report(error) }
    }

    func connect(anchor: UIWindow?) async {
        guard !busy, !storageUnavailable, !hasLocalSession, let client else { return }
        guard let anchor, anchor.isKeyWindow, anchor.windowScene?.activationState == .foregroundActive else {
            message = "当前窗口尚未就绪，请返回此页面后重试。"; return
        }
        let epoch = privacy.value
        busy = true; message = "正在完成连接…"
        defer { finish() }
        do {
            try await client.openPairing(anchor: anchor)
            hasLocalSession = client.hasLocalSession
            _ = try await client.sessionInfo()
            guard privacy.admits(epoch) else { return }
            sessionConfirmed = true; message = nil
        } catch { report(error) }
    }

    func cancelPairing() {
        client?.cancelPairing(); pairingCode = nil; pairingDeadline = nil
        message = "本机配对步骤已结束；不代表后台请求已取消。"
    }

    func revalidateSession() async {
        if busy { validationQueued = true; return }
        guard privacy.active, hasLocalSession, !storageUnavailable, let client else { return }
        hidePrivateData()
        let epoch = privacy.value
        busy = true; message = nil
        defer { finish() }
        do {
            _ = try await client.sessionInfo()
            guard privacy.admits(epoch) else { return }
            sessionConfirmed = true
        } catch { if privacy.admits(epoch) { report(error) } }
    }

    func setForeground(_ active: Bool) {
        privacy.setActive(active)
        if !active { hidePrivateData() }
    }

    func hidePrivateData() {
        privacy.invalidate()
        sessionConfirmed = false; history.invalidate(); clearVehicleData(); vehicles = []; listLoaded = false
    }

    func loadVehicles() async {
        guard !busy, sessionConfirmed, !storageUnavailable, let client else { return }
        history.invalidate()
        busy = true; message = nil
        // A fresh list is a new selection boundary; never retain a removed vehicle's data.
        clearVehicleData(); vehicles = []; listLoaded = false
        defer { finish() }
        let epoch = privacy.value
        do {
            let result = try await client.vehicles()
            guard privacy.admits(epoch), sessionConfirmed else { return }
            vehicles = result; listLoaded = true
        }
        catch { report(error) }
    }

    func select(_ vin: String) {
        guard !busy, sessionConfirmed, vehicles.contains(where: { $0.vin == vin }) else { return }
        history.invalidate()
        clearVehicleData(); selectedVIN = vin; message = nil
    }

    func read(cached: Bool) async {
        guard !busy, sessionConfirmed, !storageUnavailable, let vin = selectedVIN, let client else { return }
        busy = true; message = nil; readFailed = false
        // Do not silently fall back to either a previous live result or demo data.
        reading = nil
        defer { finish() }
        let epoch = privacy.value
        do {
            let result: ReadOnlyVehicleData
            if cached { result = try await client.snapshot(vin: vin) }
            else { result = try await client.probe(vin: vin) }
            guard privacy.admits(epoch), sessionConfirmed else { return }
            reading = result
        }
        catch { readFailed = true; report(error) }
    }

    func refreshHistory(_ kind: NativeHistoryKind) async {
        message = "此连接暂不提供行程或充电历史。"
    }

    func loadMoreHistory(_ kind: NativeHistoryKind) async {
        message = "此连接暂不提供行程或充电历史。"
    }

    func loadHistoryDetail(_ record: NativeHistoryRecord) async {
        message = "此连接暂不提供行程或充电历史。"
    }

    func logout() async {
        guard !busy, let client else { return }
        hidePrivateData()
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

    private func clearVehicleData() { selectedVIN = nil; reading = nil; readFailed = false }
    private func finish() {
        hasLocalSession = client?.hasLocalSession == true
        pairingCode = client?.pairingCode; pairingDeadline = client?.pairingDeadline
        if !hasLocalSession { sessionConfirmed = false }
        if !hasLocalSession { history.invalidate(); clearVehicleData(); vehicles = []; listLoaded = false }
        if !privacy.active { hidePrivateData() }
        busy = false
        if validationQueued {
            validationQueued = false
            if privacy.active, hasLocalSession, !storageUnavailable {
                Task { await self.revalidateSession() }
            }
        }
    }
    private func report(_ error: Error) {
        hidePrivateData()
        switch error as? NativeTeslaError {
        case .keychainUnavailable:
            storageUnavailable = true
            message = "安全存储操作未完成，不能确认退出或保存成功。请解锁设备后重试读取；不会自动清除原有存储。"
        case .pairingRejected: message = "配对请求已被拒绝。本次配对未完成。"
        case .localPairingWindowEnded: message = "本机确认时限已结束，请手动重新开始。后台请求状态尚未确认。"
        case .pairingExpired: message = "配对请求已过期。本次请求已失效，请重新开始。"
        case .cancelled: message = "已返回应用；不代表后台请求已取消。可继续打开后台，确认页面可能需要重新开始。"
        case .signInRequired: message = "设备连接已失效。请重新配对后再访问后台。"
        case .authenticationFailed where client?.refreshRecoveryRequired == true:
            message = "会话续期结果尚未确认，为避免重复使用凭据已停止重试。私有数据已隐藏。请明确退出本机会话后再重新配对；退出不删除服务器数据或撤销Tesla授权。"
        case .rateLimited: message = "请求过于频繁，请稍后手动重试。车辆探测至少间隔 15 秒。"
        default: message = hasLocalSession || client?.hasLocalSession == true
            ? "本机会话已保存，但未确认有效；私有数据已隐藏。请重试验证连接，不要重新配对。"
            : "本次请求未完成，服务可能尚未开放或网络不可用。请稍后手动重试。"
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

struct AccountView: View {
    @Environment(NativeAccountState.self) private var account
    @State private var windowReference = AccountWindowReference()
    @State private var confirmingLogout = false
    @ScaledMetric(relativeTo: .title3) private var codeSize = 20.0
    private var deviceKind: String { {
        #if targetEnvironment(simulator)
        return "此设备"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }() }
    var body: some View {
        Form {
            Section("连接状态") {
                Text(account.status)
                if account.busy { ProgressView(account.pairingCode == nil ? "正在处理…" : "正在完成连接…") }
                if let message = account.message { Text(message).foregroundStyle(.secondary) }
            }
            Section("后台地址") { Text(NativeOwnerPairing.origin).fixedSize(horizontal: false, vertical: true) }
            Section("当前设备") { Text(deviceKind) }
            if let code = account.pairingCode, let deadline = account.pairingDeadline {
                Section("核对码") {
                    Text(NativeOwnerPairing.grouped(code))
                        .font(.system(size: codeSize, weight: .semibold, design: .monospaced))
                        .accessibilityLabel("核对码，" + NativeOwnerPairing.spoken(code))
                    Text("记住下方核对码，再打开后台。在后台输入此码并确认配对。")
                    Text("只在下方后台地址输入核对码，不要发到聊天或交给他人。")
                    Text("请在请求创建后的10分钟内完成确认，打开页面不会延长有效期。")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date >= deadline { Text("本机确认时限已结束，请手动重新开始。") }
                        else { Text("有效至 \(deadline.formatted(date: .omitted, time: .standard))（最长 10 分钟）") }
                    }
                }
            }
            Section {
                if account.storageUnavailable {
                    Button("重试读取安全存储") { account.loadLocalSession() }
                } else if account.hasLocalSession {
                    Button("重试验证连接") { Task { await account.revalidateSession() } }
                } else if account.pairingCode != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let deadline = account.pairingDeadline, context.date < deadline {
                            Button("打开后台") { Task { await account.connect(anchor: windowReference.activeKeyWindow) } }
                        } else {
                            Button("重新开始配对") { Task { await account.preparePairing() } }
                        }
                    }
                    Button("取消本机配对", role: .destructive) { account.cancelPairing() }
                } else {
                    Button("开始配对") { Task { await account.preparePairing() } }
                }
            } header: { Text("下一步") } footer: {
                Text("通过设备配对，使用此后台已有的Tesla车辆授权。本次不需要重新登录Tesla。仅在系统浏览器中验证后台所有者身份；应用不会索取或保存后台管理员密码或 Tesla 令牌。配对不会唤醒、读取或控制车辆。车辆控制、行程和充电历史暂不可用。")
            }
            if account.sessionConfirmed { NativeVehicleSelectionSection() }
            if account.hasLocalSession {
                Section("退出") {
                    Button("退出当前应用会话", role: .destructive) { confirmingLogout = true }
                    Text("退出仅清除本机会话并尝试撤销服务器设备会话；不撤销 Tesla 授权，不删除服务器数据。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .tint(.blue)
        .disabled(account.busy)
        .background(AccountWindowReader(reference: windowReference).frame(width: 0, height: 0))
        .navigationTitle("连接现有后台")
        .task { await account.revalidateSession() }
        .confirmationDialog("退出当前应用会话？", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("退出会话", role: .destructive) { Task { await account.logout() } }
        } message: { Text("不会删除服务器数据或撤销 Tesla 授权。服务器撤销是否成功会单独说明。") }
    }
}

private struct NativeVehicleSelectionSection: View {
    @Environment(NativeAccountState.self) private var account
    var body: some View {
        Section {
            Button(account.listLoaded ? "重新加载授权车辆列表" : "加载授权车辆列表", systemImage: "list.bullet") {
                Task { await account.loadVehicles() }
            }
            if account.listLoaded && account.vehicles.isEmpty { Text("未找到此账号可访问的车辆。") }
            ForEach(Array(account.vehicles.enumerated()), id: \.element.vin) { index, vehicle in
                Button {
                    account.select(vehicle.vin)
                } label: {
                    HStack {
                        Text("授权车辆 \(index + 1)")
                        Spacer()
                        if account.selectedVIN == vehicle.vin { Image(systemName: "checkmark") }
                    }
                }
            }
            if account.selectedVIN != nil {
                Button("读取一次车辆状态（只读）", systemImage: "arrow.clockwise") { Task { await account.read(cached: false) } }
                Button("查看服务器缓存快照", systemImage: "clock") { Task { await account.read(cached: true) } }
            }
        } header: { Text("授权车辆与手动读取") } footer: {
            Text("列表不代表已连接车辆。选择车辆会先清除旧数据；每次读取都需点击，不唤醒车辆、不轮询、不提供控车命令。缓存可能不存在或已过期。")
        }
    }
}

struct NativeVehicleStatusView: View {
    @Environment(NativeAccountState.self) private var account
    var body: some View {
        List {
            Section("真实账号 · 只读") {
                Text(account.status)
                NavigationLink("账号、车辆选择与手动读取") { AccountView() }
                if let message = account.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            NativeReadingSourceSection()
            Section("上次读取的车辆状态 · 非当前状态保证") {
                LabeledContent("电量", value: nativeNumber((account.sessionConfirmed ? account.reading : nil)?.data?.charge_state?.battery_level, unit: "%"))
                LabeledContent("预计续航", value: nativeNumber((account.sessionConfirmed ? account.reading : nil)?.data?.charge_state?.batteryRangeKilometres, unit: "公里"))
                LabeledContent("车内温度", value: nativeNumber((account.sessionConfirmed ? account.reading : nil)?.data?.climate_state?.inside_temp, unit: "℃"))
                LabeledContent("车外温度", value: nativeNumber((account.sessionConfirmed ? account.reading : nil)?.data?.climate_state?.outside_temp, unit: "℃"))
                LabeledContent("里程表", value: nativeNumber((account.sessionConfirmed ? account.reading : nil)?.data?.vehicle_state?.odometer.map { $0 * 1.609344 }, unit: "公里"))
                LabeledContent("门锁与车门", value: "未知")
            }
            Section { Text("缺失字段保持未知。一次读取不代表持续在线；本阶段没有遥测采集、唤醒或车辆控制。") }
        }.navigationTitle("车辆")
    }
}

private struct NativeReadingSourceSection: View {
    @Environment(NativeAccountState.self) private var account
    var body: some View {
        Section("数据来源与时间") {
            LabeledContent("本次结果", value: origin)
            if let reading = (account.sessionConfirmed ? account.reading : nil) {
                LabeledContent("服务器获取时间", value: date(reading.fetchedAt))
                LabeledContent("本机接收时间", value: date(reading.receivedAt))
                LabeledContent("电池源时间", value: date(reading.sourceTimestamp(for: .charge)))
                LabeledContent("温度源时间", value: date(reading.sourceTimestamp(for: .climate)))
                LabeledContent("里程源时间", value: date(reading.sourceTimestamp(for: .vehicle)))
                // Local presentation clock only: never refreshes or probes the vehicle.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("电池字段：\(freshness(reading, section: .charge, at: context.date))")
                        Text("温度字段：\(freshness(reading, section: .climate, at: context.date))")
                        Text("里程字段：\(freshness(reading, section: .vehicle, at: context.date))")
                        Text("仅展示上次读取值；源时间缺失、位于未来或无法验证时，新鲜度未知。缓存始终非实时，不因本机时间更新而变为实时。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if reading.origin == .cachedSnapshot {
                    LabeledContent("服务器缓存标记", value: reading.cacheStale.map { $0 ? "已过期" : "未标记过期（不代表实时）" } ?? "未知")
                }
            }
        }
    }
    private var origin: String {
        if account.readFailed { return "本次读取失败 · 当前状态未知" }
        switch (account.sessionConfirmed ? account.reading : nil)?.origin {
        case .liveRead: return "本次车辆读取 · 非持续在线"
        case .cachedSnapshot: return "服务器缓存 · 非实时"
        case .noLiveData: return "未取得实时数据 · 车辆可能离线或休眠"
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
                ContentUnavailableView("尚未采集真实行程", systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text("本阶段仅支持手动只读车辆状态。尚未接入持续采集与真实行程历史；没有记录不代表车辆未行驶。"))
            }
            Section { Text("演示行程与导出仍可在“我的 → 演示功能与设置”查看，不会作为真实账号记录展示。") }
        }.navigationTitle("行程")
    }
}

struct NativeChargingStatusView: View {
    @Environment(NativeAccountState.self) private var account
    var body: some View {
        List {
            NativeReadingSourceSection()
            Section("上次读取的充电状态 · 只读") {
                LabeledContent("电量", value: nativeNumber((account.sessionConfirmed ? account.reading : nil)?.data?.charge_state?.battery_level, unit: "%"))
                LabeledContent("充电上限", value: nativeNumber((account.sessionConfirmed ? account.reading : nil)?.data?.charge_state?.charge_limit_soc, unit: "%"))
                LabeledContent("充电功率", value: nativeNumber((account.sessionConfirmed ? account.reading : nil)?.data?.charge_state?.charger_power, unit: "kW"))
                LabeledContent("充电状态", value: chargeStatus)
                NavigationLink("前往手动读取") { AccountView() }
            }
            Section { Text("此连接暂不提供充电历史。") }
        }.navigationTitle("充电")
    }
    private var chargeStatus: String {
        switch (account.sessionConfirmed ? account.reading : nil)?.data?.charge_state?.charging_state {
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
