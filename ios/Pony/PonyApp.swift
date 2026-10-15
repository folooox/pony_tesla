import SwiftUI
import PonyCore

@main
struct PonyApp: App {
    @State private var store: AppStore
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.firstIndex(of: "-scenario").flatMap { index in
            arguments.indices.contains(index + 1) ? DemoScenario(rawValue: arguments[index + 1]) : nil
        } ?? .normal
        _store = State(initialValue: AppStore(scenario: scenario))
    }
    var body: some Scene { WindowGroup { PonyTabs().environment(store) } }
}

enum PonyTab: String, Hashable { case vehicle, trips, charging, profile }

struct PonyTabs: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("pony.selected-tab") private var selectedRaw = PonyTab.vehicle.rawValue
    private var selected: Binding<PonyTab> {
        Binding(get: { PonyTab(rawValue: selectedRaw) ?? .vehicle }, set: { selectedRaw = $0.rawValue })
    }
    var body: some View {
        TabView(selection: selected) {
            Tab("车辆", systemImage: "car", value: .vehicle) { NavigationStack { VehicleView() } }
            Tab("行程", systemImage: "point.topleft.down.to.point.bottomright.curvepath", value: .trips) { NavigationStack { TripsView() } }
            Tab("充电", systemImage: "bolt", value: .charging) { NavigationStack { ChargingView() } }
            Tab("我的", systemImage: "person.crop.circle", value: .profile) { NavigationStack { ProfileView() } }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .task {
            await store.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if scenePhase == .active { store.tick() }
            }
        }
        .onChange(of: scenePhase) { _, next in
            if next == .active { store.tick(); Task { await store.refresh() } }
        }
        .alert(store.message?.title ?? "", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("知道了", role: .cancel) { store.message = nil }
        } message: { Text(store.message?.detail ?? "") }
    }
}

#Preview("系统浅色") { PonyTabs().environment(AppStore()).preferredColorScheme(.light) }
#Preview("系统深色") { PonyTabs().environment(AppStore()).preferredColorScheme(.dark) }
#Preview("辅助功能字号") { PonyTabs().environment(AppStore()).dynamicTypeSize(.accessibility3) }
#Preview("离线") { PonyTabs().environment(AppStore(scenario: .offline)) }
