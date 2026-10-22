import SwiftUI
import UIKit
import PonyCore

struct VehicleStage: View {
    let vehicle: VehicleSnapshot
    @Binding var camera: VehicleCamera

    private var slot: VehicleArtworkSlot {
        switch camera {
        case .exterior: .homeClosed
        case .overhead: .controlTop
        case .cabin: .cabinTop
        }
    }
    private var style: VehicleArtworkStyle? {
        VehicleArtworkCatalog.style(for: vehicle.vehicleStyleID)
    }
    private var artwork: UIImage? {
        guard let name = VehicleArtworkCatalog.assetName(for: vehicle, slot: slot) else { return nil }
        return UIImage(named: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(style?.title ?? "车辆").font(.subheadline.weight(.semibold)).tracking(2)
                Spacer()
                if let style {
                    Text(style.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            ZStack {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("车辆外观，车门关闭")
                        .accessibilityIdentifier("vehicle.artwork.home.closed")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "car.side").font(.largeTitle).accessibilityHidden(true)
                        Text("车辆画面暂不可用").font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("vehicle.artwork.unavailable")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 235)
            Picker("车辆视角", selection: $camera) {
                ForEach(VehicleCamera.allCases) {
                    Text($0.rawValue).tag($0)
                        .accessibilityIdentifier("vehicle.camera.\($0 == .exterior ? "exterior" : $0 == .overhead ? "overhead" : "cabin")")
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .accessibilityIdentifier("vehicle.presentation")
            if vehicle.body.unknownOpenings {
                Label("部分车身状态未知", systemImage: "questionmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !vehicle.body.openLabels.isEmpty {
                Label(vehicle.body.openLabels.joined(separator: "、") + "已打开", systemImage: "car.side.rear.open")
                    .font(.footnote).foregroundStyle(.primary)
            }
            if let vented = vehicle.body.windowsVented {
                if vented {
                    Label("车窗通风中", systemImage: "car.side")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Label("车窗状态未知", systemImage: "questionmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if vehicle.cabinMode != .off {
                Label("空调 · \(vehicle.cabinMode.rawValue)", systemImage: "fan")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
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
                    Text("模拟车门与舱盖传感器的回报，检查车况显示。这些开关不会发送真实开门或关门指令。")
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
                            Label(seat.title, systemImage: "carseat.left.and.heat.waves")
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
