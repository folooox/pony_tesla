import Foundation

/// Unknown is not off. These readings describe a snapshot, never a command's intent.
public enum FeatureReading: Equatable, Sendable {
    case on, off, unknown
}

public enum VehicleFeature: String, CaseIterable, Identifiable, Sendable {
    // Declaration order is the home order. Valet has no source field yet.
    case valet, sentry, climate, dog, camp, defrost, seats, wheel, charging
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .valet: "酒保模式"
        case .sentry: "哨兵模式"
        case .climate: "空调"
        case .dog: "宠物模式"
        case .camp: "露营模式"
        case .defrost: "除霜"
        case .seats: "座椅加热"
        case .wheel: "方向盘加热"
        case .charging: "充电"
        }
    }
    public var activeTitle: String { self == .charging ? "正在充电" : title + "已开启" }
    public var symbol: String {
        switch self {
        case .valet: "key"
        case .sentry: "shield"
        case .climate: "fan"
        case .dog: "pawprint"
        case .camp: "tent"
        case .defrost: "windshield.front.and.heat.waves"
        case .seats: "carseat.left.and.heat.waves"
        case .wheel: "steeringwheel"
        case .charging: "bolt"
        }
    }
}

public struct FeatureStatusCard: Identifiable, Equatable, Sendable {
    public let feature: VehicleFeature
    /// Only true for an online, fresh snapshot. Does not imply a real vehicle source.
    public let isCurrent: Bool
    public let timestamp: Date
    public var id: VehicleFeature { feature }
    public var title: String { isCurrent ? feature.activeTitle : feature.title }
    public var cachedStatus: String? { isCurrent ? nil : "上次状态：已开启" }
}

public struct FeatureStatusPresentation: Equatable, Sendable {
    public let current: [FeatureStatusCard]
    public let previous: [FeatureStatusCard]

    public init(readings: [VehicleFeature: FeatureReading], fetchedAt: Date, online: Bool, now: Date, maximumAge: TimeInterval = 120) {
        let age = now.timeIntervalSince(fetchedAt)
        let isCurrent = online && age >= 0 && age < maximumAge
        let cards = VehicleFeature.allCases.compactMap { feature -> FeatureStatusCard? in
            guard readings[feature] == .on else { return nil }
            return FeatureStatusCard(feature: feature, isCurrent: isCurrent, timestamp: fetchedAt)
        }
        current = isCurrent ? cards : []
        previous = isCurrent ? [] : cards
    }

    public init(vehicle: VehicleSnapshot, now: Date) {
        self.init(readings: Self.readings(from: vehicle), fetchedAt: vehicle.fetchedAt, online: vehicle.status == .online, now: now)
    }

    public static func readings(from vehicle: VehicleSnapshot) -> [VehicleFeature: FeatureReading] {
        func reading(_ value: Bool?) -> FeatureReading {
            guard let value else { return .unknown }
            return value ? .on : .off
        }
        let seatValues = vehicle.body.heatedSeats.map { vehicle.body.seatHeat[$0] }
        let seats: FeatureReading
        if seatValues.contains(where: { ($0 ?? 0) > 0 }) {
            seats = .on
        } else if !seatValues.isEmpty && seatValues.allSatisfy({ $0 == 0 }) {
            seats = .off
        } else {
            seats = .unknown
        }
        // cabinMode and charging are nonoptional in the existing demo model.
        // Do not invent additional fallback readings for future real snapshots.
        return [
            .valet: .unknown,
            .sentry: reading(vehicle.sentry),
            .climate: reading(vehicle.cabinMode == .normal),
            .dog: reading(vehicle.cabinMode == .dog),
            .camp: reading(vehicle.cabinMode == .camp),
            .defrost: reading(vehicle.cabinMode == .defrost),
            .seats: seats,
            .wheel: vehicle.body.supportsSteeringHeat ? reading(vehicle.body.steeringHeat.map { $0 > 0 }) : .unknown,
            .charging: reading(vehicle.charging)
        ]
    }
}

/// Command feedback is independent of active snapshot cards. In particular,
/// transport failure/timeout is not evidence that a vehicle rejected a command.
public struct CommandStatusPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case pending, unknown, rejected }
    public let commandTitle: String
    public let phase: Phase
    public init(commandTitle: String, phase: Phase) {
        self.commandTitle = commandTitle
        self.phase = phase
    }
    public var title: String {
        switch phase {
        case .pending: "正在处理"
        case .unknown: "结果未知"
        case .rejected: "操作被拒绝"
        }
    }
    public var detail: String {
        switch phase {
        case .pending: "等待车辆确认"
        case .unknown: "尚未取得确认，请刷新状态后核实"
        case .rejected: "车辆明确拒绝了此操作"
        }
    }
}
