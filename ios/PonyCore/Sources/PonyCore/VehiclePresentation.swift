import Foundation

/// Physical positions stay independent of the chosen visual theme and driving side.
public enum VehicleOpening: String, CaseIterable, Identifiable, Sendable {
    case frontLeft, frontRight, rearLeft, rearRight, frunk, trunk, chargePort
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .frontLeft: "左前门"
        case .frontRight: "右前门"
        case .rearLeft: "左后门"
        case .rearRight: "右后门"
        case .frunk: "前备箱"
        case .trunk: "后备箱"
        case .chargePort: "充电口"
        }
    }
}

public enum SeatPosition: String, CaseIterable, Identifiable, Sendable {
    case frontLeft, frontRight, rearLeft, rearCenter, rearRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .frontLeft: "左前座椅"
        case .frontRight: "右前座椅"
        case .rearLeft: "左后座椅"
        case .rearCenter: "后排中间"
        case .rearRight: "右后座椅"
        }
    }
}

/// Missing entries mean unknown readings, never closed doors or zero heat.
public struct VehicleBodyState: Equatable, Sendable {
    public var openings: [VehicleOpening: Bool] = [:]
    public var seatHeat: [SeatPosition: Int] = [:]
    public var steeringHeat: Int?
    public var windowsVented: Bool?
    public var heatedSeats: Set<SeatPosition> = []
    public var supportsSteeringHeat = false
    public init() {}
    public var openLabels: [String] {
        VehicleOpening.allCases.filter { openings[$0] == true }.map(\.title)
    }
    public var unknownOpenings: Bool { VehicleOpening.allCases.contains { openings[$0] == nil } }
    public static var demo: Self {
        var result = Self()
        result.openings = Dictionary(uniqueKeysWithValues: VehicleOpening.allCases.map { ($0, false) })
        result.seatHeat = Dictionary(uniqueKeysWithValues: SeatPosition.allCases.map { ($0, 0) })
        result.steeringHeat = 0
        result.windowsVented = false
        result.heatedSeats = Set(SeatPosition.allCases)
        result.supportsSteeringHeat = true
        return result
    }
}
