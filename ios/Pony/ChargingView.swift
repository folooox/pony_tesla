import SwiftUI
import PonyCore

struct ChargingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var draftLimit = 80.0
    @State private var hasDraft = false
    @State private var confirming = false
    var body: some View {
        DashboardGate { vehicle in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DemoNotice(); StatusNotice()
                    VStack(spacing: 16) {
                        Image(systemName: "bolt.batteryblock.fill").font(.largeTitle)
                            .foregroundStyle(vehicle.charging ? .green : .secondary)
                            .symbolEffect(.pulse, isActive: vehicle.charging && vehicle.canControl(at: store.now) && store.failure == nil && !reduceMotion && scenePhase == .active)
                        Text("\(Display.number(vehicle.battery))%")
                            .font(.system(.largeTitle, design: .default, weight: .semibold)).monospacedDigit()
                        Text(chargeStatus(vehicle)).font(.headline)
                        if let battery = vehicle.battery {
                            ProgressView(value: min(max(battery / 100, 0), 1)) { Text("当前电量") }.tint(.green)
                        }
                        Text("家用充电桩 · 交流充电 · 示例").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical)
                    GroupBox {
                        MetricRow(values: [("当前功率", vehicle.charging ? Display.number(vehicle.chargingKW, digits: 1) : "0", "kW"),
                                           ("本次充入", Display.number(vehicle.energyAdded, digits: 1), "kWh")])
                    }
                    GroupBox {
                        VStack(spacing: 16) {
                            LabeledContent("车辆充电上限", value: "\(Int(vehicle.chargeLimit))%")
                            LabeledContent("待应用上限", value: "\(Int(draftLimit))%")
                            Slider(value: $draftLimit, in: 50...100, step: 5, onEditingChanged: { if $0 { hasDraft = true } }) { Text("充电上限") }
                            Button("应用到模拟车辆") { Task { await store.execute(.setChargeLimit(draftLimit)) } }
                                .buttonStyle(.glass).disabled(!store.canControl || draftLimit == vehicle.chargeLimit)
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { chargeButtons(vehicle) }
                        VStack { chargeButtons(vehicle) }
                    }
                    Text("滑块只修改草稿，收到服务结果后才更新车辆上限。").font(.footnote).foregroundStyle(.secondary)
                    chargingHistory
                }.padding()
            }
            .refreshable { await store.refresh() }
            .onAppear { if !hasDraft { draftLimit = vehicle.chargeLimit } }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("充电")
        .confirmationDialog("模拟充电操作", isPresented: $confirming, titleVisibility: .visible) {
            Button(store.vehicle?.charging == true ? "模拟暂停充电" : "模拟开始充电") {
                Task { await store.execute(.setCharging(!(store.vehicle?.charging ?? false))) }
            }
        } message: { Text("仅修改演示会话，不向真实车辆发送指令。") }
        .onChange(of: store.scenario) { _, _ in hasDraft = false; draftLimit = 80 }
    }
    private func chargeStatus(_ vehicle: VehicleSnapshot) -> String {
        guard vehicle.status == .online, vehicle.isFresh(at: store.now), store.failure == nil else { return "充电实时状态不可用" }
        return vehicle.charging ? "正在充电 · 模拟" : "已暂停 · 模拟"
    }
    @ViewBuilder private func chargeButtons(_ vehicle: VehicleSnapshot) -> some View {
        Button(vehicle.charging ? "暂停充电" : "开始充电", systemImage: vehicle.charging ? "pause" : "bolt") { confirming = true }
            .buttonStyle(.glassProminent).controlSize(.large).disabled(!store.canControl)
        NavigationLink("充电预约", systemImage: "clock") {
            PreviewInfoView(title: "充电预约", message: "预约服务尚未接入。此版本不保存或执行预约，避免将草稿误认为已下发。")
        }.buttonStyle(.glass).controlSize(.large)
    }
    private var chargingHistory: some View {
        GroupBox("最近充电") {
            if store.charges.isEmpty {
                ContentUnavailableView("暂无充电记录", systemImage: "bolt.slash", description: Text("记录会从接入后开始积累。"))
            } else {
                VStack(spacing: 16) {
                    ForEach(store.charges) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("家用充电桩", value: "\(Display.number(record.energyKWh, digits: 1)) kWh")
                            Text("\(record.start.formatted(date: .abbreviated, time: .shortened)) · \(Int(record.fromPercent))% → \(Int(record.toPercent))%")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(Display.duration(record.end.timeIntervalSince(record.start))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.top, 8)
            }
        }
    }
}
