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

/// Presentation-only clock. Retargeting is paired with a new rendered start pose by the host.
/// 550 ms is a tuning baseline, not a platform-prescribed duration.
public struct VehicleTransition: Equatable, Sendable {
    public private(set) var elapsed: Double = 0.55
    public let duration: Double = 0.55
    public init() {}
    public var isComplete: Bool { elapsed >= duration }
    public var progress: Double {
        let t = min(1, max(0, elapsed / duration))
        return t * t * (3 - 2 * t)
    }
    public mutating func restart(animated: Bool) { elapsed = animated ? 0 : duration }
    public mutating func advance(by delta: Double) { elapsed = min(duration, elapsed + max(0, delta)) }
    public mutating func finish() { elapsed = duration }
}

/// Fixed artwork slots are not interchangeable views of a realtime model.
public enum VehicleArtworkSlot: String, CaseIterable, Sendable {
    case homeClosed = "home.closed"
    case homeLamps = "home.lamps"
    case controlTop = "control.top"
    case cabinTop = "cabin.top"
}

public enum VehicleArtworkSupport: String, Sendable {
    case available, unavailable
}

public struct VehicleArtworkEntry: Equatable, Sendable {
    public let support: VehicleArtworkSupport
    public let assetName: String?
}

public struct VehicleArtworkBounds: Equatable, Sendable {
    public let minX: Int
    public let minY: Int
    public let maxX: Int
    public let maxY: Int
}

public struct VehicleArtworkStyle: Equatable, Sendable {
    public let vehicleStyleID: String
    public let assetVersion: String
    public let schemaVersion: Int
    public let title: String
    public let subtitle: String
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let vehicleBounds: VehicleArtworkBounds
    public let hasAlpha: Bool
    /// No light layers or anchor coordinates have been delivered yet.
    public let lampAnchors: [String: [Int]]
    public let supportedStates: [String]
    public let slots: [VehicleArtworkSlot: VehicleArtworkEntry]
}

public extension VehicleBodyState {
    /// All doors, covers, charge port AND windows must have known closed readings.
    var supportsClosedArtwork: Bool {
        !unknownOpenings && openLabels.isEmpty && windowsVented == false
    }
}

/// Future account/vehicle mapping supplies the stable key on VehicleSnapshot.
/// A missing or unrecognized key intentionally has no artwork; display names are never consulted.
public enum VehicleArtworkCatalog {
    public static let demoStyleID = "model3_cn_2022"
    private static let model3 = VehicleArtworkStyle(
        vehicleStyleID: demoStyleID, assetVersion: "static-home-v2", schemaVersion: 1,
        title: "MODEL 3", subtitle: "2022 · 后轮驱动",
        canvasWidth: 1536, canvasHeight: 1024,
        vehicleBounds: VehicleArtworkBounds(minX: 104, minY: 126, maxX: 1448, maxY: 937),
        hasAlpha: true, lampAnchors: [:], supportedStates: ["closed"],
        slots: [
            .homeClosed: VehicleArtworkEntry(support: .available, assetName: "VehicleModel3CN2022HomeClosed"),
            .homeLamps: VehicleArtworkEntry(support: .unavailable, assetName: nil),
            .controlTop: VehicleArtworkEntry(support: .unavailable, assetName: nil),
            .cabinTop: VehicleArtworkEntry(support: .unavailable, assetName: nil)
        ])

    public static func style(for vehicleStyleID: String?) -> VehicleArtworkStyle? {
        vehicleStyleID == demoStyleID ? model3 : nil
    }

    public static func assetName(for vehicle: VehicleSnapshot, slot: VehicleArtworkSlot) -> String? {
        guard let style = style(for: vehicle.vehicleStyleID),
              let entry = style.slots[slot], entry.support == .available else { return nil }
        // The only delivered state is a fully closed exterior. Never substitute it for another slot.
        guard slot == .homeClosed, vehicle.body.supportsClosedArtwork else { return nil }
        return entry.assetName
    }
}
