import SwiftUI
import PonyCore

@main
struct PonyApp: App {
    @State private var store: AppStore
    @State private var nativeAccount: NativeAccountState?
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.firstIndex(of: "-scenario").flatMap { index in
            arguments.indices.contains(index + 1) ? DemoScenario(rawValue: arguments[index + 1]) : nil
        } ?? .normal
        _store = State(initialValue: AppStore(scenario: scenario))
        #if DEBUG
        _nativeAccount = State(initialValue: arguments.contains("--native-history-fixture") ? nil : NativeAccountState())
        #else
        _nativeAccount = State(initialValue: NativeAccountState())
        #endif
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-history-fixture") {
                NativeHistoryFixtureView()
            } else if let nativeAccount {
                PonyTabs().environment(store).environment(nativeAccount)
            }
            #else
            if let nativeAccount { PonyTabs().environment(store).environment(nativeAccount) }
            #endif
        }
    }
}

enum PonyTab: String, Hashable { case vehicle, trips, charging, profile }

struct PonyTabs: View {
    @Environment(AppStore.self) private var store
    @Environment(NativeAccountState.self) private var account
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("pony.selected-tab") private var selectedRaw = PonyTab.vehicle.rawValue
    private var selected: Binding<PonyTab> {
        Binding(get: { PonyTab(rawValue: selectedRaw) ?? .vehicle }, set: { selectedRaw = $0.rawValue })
    }
    var body: some View {
        TabView(selection: selected) {
            Tab("车辆", systemImage: "car", value: .vehicle) { NavigationStack { if account.hasLocalSession { NativeVehicleStatusView() } else { VehicleView() } }.id(account.hasLocalSession) }
            Tab("行程", systemImage: "point.topleft.down.to.point.bottomright.curvepath", value: .trips) { NavigationStack { if account.hasLocalSession { NativeTripsUnavailableView() } else { TripsView() } }.id(account.hasLocalSession) }
            Tab("充电", systemImage: "bolt", value: .charging) { NavigationStack { if account.hasLocalSession { NativeChargingStatusView() } else { ChargingView() } }.id(account.hasLocalSession) }
            Tab("我的", systemImage: "person.crop.circle", value: .profile) { NavigationStack { ProfileView() } }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .task {
            if !account.hasLocalSession { await store.refresh() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if scenePhase == .active && !account.hasLocalSession { store.tick() }
            }
        }
        .onChange(of: scenePhase) { _, next in
            account.setForeground(next == .active)
            if next == .active { Task { await account.revalidateSession() } }
            if next == .active && !account.hasLocalSession { store.tick(); Task { if !account.hasLocalSession { await store.refresh() } } }
        }
        .alert(store.message?.title ?? "", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("知道了", role: .cancel) { store.message = nil }
        } message: { Text(store.message?.detail ?? "") }
    }
}

#Preview("系统浅色") { PonyTabs().environment(AppStore()).environment(NativeAccountState()).preferredColorScheme(.light) }
#Preview("系统深色") { PonyTabs().environment(AppStore()).environment(NativeAccountState()).preferredColorScheme(.dark) }
#Preview("辅助功能字号") { PonyTabs().environment(AppStore()).environment(NativeAccountState()).dynamicTypeSize(.accessibility3) }
#Preview("离线") { PonyTabs().environment(AppStore(scenario: .offline)).environment(NativeAccountState()) }
