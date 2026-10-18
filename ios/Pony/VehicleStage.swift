import SwiftUI
import PonyCore

struct VehicleStage: View {
    let vehicle: VehicleSnapshot
    var initialCamera: VehicleCamera = .exterior
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera: VehicleCamera = .exterior
    @State private var rotation: Float = 0
    @State private var dragStart: Float = 0
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MODEL 3").font(.subheadline.weight(.semibold)).tracking(2)
                Spacer()
                Text("2022 · 后轮驱动").font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .bottom) {
                VehicleScene(vehicle: vehicle, camera: camera, dark: scheme == .dark,
                    animate: !reduceMotion && visible && scenePhase == .active, rotation: rotation)
                    .frame(height: 235)
                    .accessibilityHidden(true)
                    .gesture(DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            rotation = dragStart + Float(value.translation.width) * 0.008
                        }
                        .onEnded { _ in dragStart = rotation })
                HStack {
                    Text("3D 交互样机").font(.caption2)
                    Spacer()
                    Button("重置视角", systemImage: "arrow.counterclockwise") { rotation = 0; dragStart = 0 }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("车辆三维视图，\(camera.rawValue)")
            .accessibilityAdjustableAction { direction in
                rotation += direction == .increment ? 0.35 : -0.35; dragStart = rotation
            }
            Picker("车辆视角", selection: $camera) {
                ForEach(VehicleCamera.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if vehicle.body.unknownOpenings {
                Label("部分车身状态未知", systemImage: "questionmark.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if !vehicle.body.openLabels.isEmpty {
                Label(vehicle.body.openLabels.joined(separator: "、") + "已打开", systemImage: "car.side.rear.open")
                    .font(.footnote).foregroundStyle(.primary)
            }
            if vehicle.cabinMode != .off {
                Label("空调 · \(vehicle.cabinMode.rawValue)", systemImage: "fan")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { camera = initialCamera; visible = true }
        .onDisappear { visible = false }
    }
}

/// Explicit local sensor simulation, kept away from actual control affordances.
struct VehicleBodyDemoView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("模拟车门与舱盖传感器的回报，检查模型联动。这些开关不会发送真实开门或关门指令。")
                    StatusNotice()
                }
                if let vehicle = store.vehicle {
                    Section("车身开合") {
                        ForEach(VehicleOpening.allCases) { opening in
                            Toggle(opening.title, isOn: Binding(
                                get: { vehicle.body.openings[opening] == true },
                                set: { value in Task { await store.execute(.simulateOpening(opening, value), announceSuccess: false) } }
                            ))
                            .disabled(!store.canControl || vehicle.body.openings[opening] == nil)
                        }
                    }
                }
            }
            .navigationTitle("车况演示").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct SeatHeatControls: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let vehicle = store.vehicle {
            Section("座椅加热") {
                ForEach(SeatPosition.allCases) { seat in
                    if vehicle.body.heatedSeats.contains(seat) {
                        HStack {
                            Label(seat.title, systemImage: "seat.heat.waves")
                            Spacer()
                            Menu {
                                ForEach(0...3, id: \.self) { level in
                                    Button(level == 0 ? "关闭" : "\(level) 挡") {
                                        Task { await store.execute(.setSeatHeat(seat, level), announceSuccess: false) }
                                    }
                                }
                            } label: {
                                Text(vehicle.body.seatHeat[seat].map { $0 == 0 ? "关闭" : "\($0) 挡" } ?? "未知")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("\(seat.title)加热挡位")
                            .disabled(!store.canControl)
                        }
                    }
                }
                if vehicle.body.heatedSeats.isEmpty { Text("当前未取得座椅加热能力").foregroundStyle(.secondary) }
                if vehicle.body.supportsSteeringHeat {
                    Toggle("方向盘加热", isOn: Binding(
                        get: { (vehicle.body.steeringHeat ?? 0) > 0 },
                        set: { on in Task { await store.execute(.setSteeringHeat(on ? 1 : 0), announceSuccess: false) } }
                    )).disabled(!store.canControl)
                }
            }
        }
    }
}
