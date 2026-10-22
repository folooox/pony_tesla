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
    private(set) var message: String?
    let history = NativeHistoryStore()
    @ObservationIgnored private var client: NativeTeslaClient?

    init() { loadLocalSession() }

    func loadLocalSession() {
        guard !busy else { return }
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
        if !hasLocalSession { return "未连接 · 演示模式" }
        return "本机已保存授权会话 · 不代表已读取车辆"
    }

    func connect(anchor: UIWindow?) async {
        guard !busy, !storageUnavailable, !hasLocalSession, let client else { return }
        guard let anchor, anchor.isKeyWindow, anchor.windowScene?.activationState == .foregroundActive else {
            message = "当前窗口尚未就绪，请返回此页面后重试。"; return
        }
        busy = true; message = nil
        defer { finish() }
        do {
            try await client.signIn(anchor: anchor)
            message = "授权会话已保存。请手动加载车辆列表，再选择车辆读取。"
        } catch NativeTeslaError.signInRequired {
            // No existing session was used by this operation. A legacy server may
            // challenge the new route; that is not an expired owner session.
            message = "手机连接请求尚未获准，未完成授权。服务可能尚未更新，请稍后手动重试。"
        } catch { report(error) }
    }

    func loadVehicles() async {
        guard !busy, hasLocalSession, !storageUnavailable, let client else { return }
        history.invalidate()
        busy = true; message = nil
        // A fresh list is a new selection boundary; never retain a removed vehicle's data.
        clearVehicleData(); vehicles = []; listLoaded = false
        defer { finish() }
        do { vehicles = try await client.vehicles(); listLoaded = true }
        catch { report(error) }
    }

    func select(_ vin: String) {
        guard !busy, hasLocalSession, vehicles.contains(where: { $0.vin == vin }) else { return }
        history.invalidate()
        clearVehicleData(); selectedVIN = vin; message = nil
    }

    func read(cached: Bool) async {
        guard !busy, hasLocalSession, !storageUnavailable, let vin = selectedVIN, let client else { return }
        busy = true; message = nil; readFailed = false
        // Do not silently fall back to either a previous live result or demo data.
        reading = nil
        defer { finish() }
        do {
            if cached { reading = try await client.snapshot(vin: vin) }
            else { reading = try await client.probe(vin: vin) }
        }
        catch { readFailed = true; report(error) }
    }

    func refreshHistory(_ kind: NativeHistoryKind) async {
        guard !busy, hasLocalSession, !storageUnavailable, let vin = selectedVIN, let client else { return }
        busy = true; message = nil
        defer { finish() }
        do { try await history.refresh(kind: kind, vin: vin, client: client) }
        catch { report(error) }
    }

    func loadMoreHistory(_ kind: NativeHistoryKind) async {
        guard !busy, hasLocalSession, !storageUnavailable, let vin = selectedVIN, let client else { return }
        busy = true; message = nil
        defer { finish() }
        do { try await history.loadMore(kind: kind, vin: vin, client: client) }
        catch { report(error) }
    }

    func loadHistoryDetail(_ record: NativeHistoryRecord) async {
        guard !busy, hasLocalSession, !storageUnavailable, let vin = selectedVIN,
              record.vin == vin, let client else { return }
        busy = true; message = nil
        defer { finish() }
        do { try await history.loadDetail(record: record, vin: vin, client: client) }
        catch { report(error) }
    }

    func logout() async {
        guard !busy, let client else { return }
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

    private func clearVehicleData() { selectedVIN = nil; reading = nil; readFailed = false }
    private func finish() {
        hasLocalSession = client?.hasLocalSession == true
        if !hasLocalSession { history.invalidate(); clearVehicleData(); vehicles = []; listLoaded = false }
        busy = false
    }
    private func report(_ error: Error) {
        switch error as? NativeTeslaError {
        case .keychainUnavailable:
            storageUnavailable = true
            message = "安全存储操作未完成，不能确认退出或保存成功。请解锁设备后重试读取；不会自动清除原有存储。"
        case .cancelled: message = "已取消授权。只有再次点击连接才会重新开始。"
        case .signInRequired: message = "应用会话已失效，请重新连接账号。"
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

struct AccountView: View {
    @Environment(NativeAccountState.self) private var account
    @State private var windowReference = AccountWindowReference()
    @State private var confirmingLogout = false
    var body: some View {
        Form {
            Section("当前账号") {
                Text(account.status)
                Text("应用会话、车辆列表与车辆数据是不同状态。恢复本机会话不会自动访问服务器，也不会自动读取车辆。")
                    .font(.footnote).foregroundStyle(.secondary)
                if account.busy { ProgressView("正在处理本次请求…") }
                if let message = account.message { Text(message).foregroundStyle(.secondary) }
            }
            if account.storageUnavailable {
                Section { Button("重试读取安全存储") { account.loadLocalSession() } }
            } else if !account.hasLocalSession {
                Section {
                    Button("使用 Tesla 账号连接", systemImage: "key") {
                        Task { await account.connect(anchor: windowReference.activeKeyWindow) }
                    }
                } footer: { Text("连接 Tesla 账号后，可手动读取已授权车辆列表；车辆在线时可读取车况。车辆控制、行程采集和充电历史暂不可用。") }
            } else {
                NativeVehicleSelectionSection()
                Section("退出") {
                    Button("退出当前应用会话", role: .destructive) { confirmingLogout = true }
                    Text("退出不等于撤销 Tesla 授权或删除账号。当前未提供服务器账号删除功能。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(account.busy)
        .background(AccountWindowReader(reference: windowReference).frame(width: 0, height: 0))
        .navigationTitle("账号与授权")
        .confirmationDialog("退出当前应用会话？", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("退出会话", role: .destructive) { Task { await account.logout() } }
        } message: { Text("会清除本机会话并尝试撤销服务器应用会话。不会删除数据或撤销 Tesla 官方授权。") }
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
                LabeledContent("电量", value: nativeNumber(account.reading?.data?.charge_state?.battery_level, unit: "%"))
                LabeledContent("预计续航", value: nativeNumber(account.reading?.data?.charge_state?.batteryRangeKilometres, unit: "公里"))
                LabeledContent("车内温度", value: nativeNumber(account.reading?.data?.climate_state?.inside_temp, unit: "℃"))
                LabeledContent("车外温度", value: nativeNumber(account.reading?.data?.climate_state?.outside_temp, unit: "℃"))
                LabeledContent("里程表", value: nativeNumber(account.reading?.data?.vehicle_state?.odometer.map { $0 * 1.609344 }, unit: "公里"))
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
            if let reading = account.reading {
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
        switch account.reading?.origin {
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
                LabeledContent("电量", value: nativeNumber(account.reading?.data?.charge_state?.battery_level, unit: "%"))
                LabeledContent("充电上限", value: nativeNumber(account.reading?.data?.charge_state?.charge_limit_soc, unit: "%"))
                LabeledContent("充电功率", value: nativeNumber(account.reading?.data?.charge_state?.charger_power, unit: "kW"))
                LabeledContent("充电状态", value: chargeStatus)
                NavigationLink("前往手动读取") { AccountView() }
            }
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
