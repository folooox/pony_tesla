import Foundation

public struct ChargingRecord: Identifiable, Sendable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let fromPercent: Double
    public let toPercent: Double
    public let energyKWh: Double
}

public struct Dashboard: Sendable {
    public let vehicle: VehicleSnapshot
    public let trips: [TripRecord]
    public let charges: [ChargingRecord]
}

public protocol VehicleService: Sendable {
    func dashboard(now: Date) async throws -> Dashboard
    func execute(_ command: VehicleCommand, now: Date) async throws -> VehicleSnapshot
    func saveTrip(id: UUID, tag: String, note: String) async throws
    func deleteHistory() async throws
}

/// An isolated simulation backend. It has no network access or credentials.
public actor DemoVehicleService: VehicleService {
    private var vehicle: VehicleSnapshot
    private var trips: [TripRecord]
    private var charges: [ChargingRecord]
    private let scenario: DemoScenario
    private let latency: Duration
    private var commandActive = false
    public init(scenario: DemoScenario = .normal, now: Date = .now, latency: Duration = .milliseconds(350)) {
        self.scenario = scenario; self.latency = latency
        var snapshot = VehicleSnapshot(now: now)
        if scenario == .offline { snapshot.status = .offline }
        if scenario == .asleep { snapshot.status = .asleep }
        if scenario == .missingData {
            snapshot.battery = nil; snapshot.rangeKM = nil; snapshot.cabinTemperature = nil
            snapshot.chargingKW = nil; snapshot.energyAdded = nil; snapshot.coordinate = nil
            snapshot.supported.remove(.windows); snapshot.supported.remove(.closeWindows)
        }
        vehicle = snapshot
        let one = Self.makeTrip(title: "家 → 公司", end: now.addingTimeInterval(-3600), duration: 32, distance: 18.6, energy: 2.46)
        let two = Self.makeTrip(title: "公司 → 城市公园", end: now.addingTimeInterval(-600), duration: 18, distance: 9.8, energy: 1.32)
        let older = Self.makeTrip(title: "家 → 湖滨路", end: now.addingTimeInterval(-86400), duration: 24, distance: 13.5, energy: 1.8)
        trips = scenario == .empty ? [] : [one, two, older]
        if scenario == .missingData {
            trips[0].energyKWh = nil
            trips[0].samples.removeAll { (10...18).contains($0.id) }
        }
        charges = scenario == .empty ? [] : [ChargingRecord(id: UUID(), start: now.addingTimeInterval(-28000), end: now.addingTimeInterval(-14000), fromPercent: 36, toPercent: 80, energyKWh: 25.8)]
    }
    private func check() throws {
        if scenario == .error { throw ServiceError.unavailable }
        if scenario == .expired { throw ServiceError.unauthorized }
    }
    public func dashboard(now: Date) async throws -> Dashboard {
        try await Task.sleep(for: latency)
        try check()
        trips = HistoryPolicy.visible(trips, now: now)
        charges.removeAll { $0.end <= now.addingTimeInterval(-HistoryPolicy.retention) }
        // Offline snapshots stay old: refreshing the UI does not manufacture fresh vehicle data.
        if vehicle.status == .online { vehicle.fetchedAt = now }
        return Dashboard(vehicle: vehicle, trips: trips, charges: charges)
    }
    public func execute(_ command: VehicleCommand, now: Date) async throws -> VehicleSnapshot {
        try check()
        guard !commandActive else { throw ServiceError.busy }
        guard vehicle.status == .online else { throw ServiceError.offline }
        commandActive = true
        defer { commandActive = false }
        try await Task.sleep(for: latency)
        try Task.checkCancellation()
        switch command {
        case .quick(let control):
            guard vehicle.supported.contains(control) else { throw ServiceError.unsupported }
            switch control {
            case .lock: vehicle.locked = true
            case .unlock: vehicle.locked = false
            case .sentry: vehicle.sentry = !(vehicle.sentry ?? false)
            case .climate: vehicle.cabinMode = vehicle.cabinMode == .off ? .normal : .off
            default: break // Momentary commands acknowledge only; never invent persistent sensor states.
            }
        case .setClimate(let temperature, let mode):
            guard temperature.isFinite, (16...28).contains(temperature) else { throw ServiceError.invalidValue }
            vehicle.targetTemperature = temperature; vehicle.cabinMode = mode
        case .setChargeLimit(let limit):
            guard limit.isFinite, (50...100).contains(limit) else { throw ServiceError.invalidValue }
            vehicle.chargeLimit = limit
        case .setCharging(let active): vehicle.charging = active
        }
        vehicle.fetchedAt = now
        return vehicle
    }
    public func saveTrip(id: UUID, tag: String, note: String) async throws {
        try check()
        guard let index = trips.firstIndex(where: { $0.id == id }) else { throw ServiceError.unavailable }
        trips[index].tag = String(tag.prefix(30)); trips[index].note = String(note.prefix(500))
    }
    public func deleteHistory() async throws {
        try check(); trips.removeAll(); charges.removeAll()
    }
    private static func makeTrip(title: String, end: Date, duration: Int, distance: Double, energy: Double) -> TripRecord {
        let start = end.addingTimeInterval(Double(-duration * 60))
        let samples = (0...duration).map { minute in
            let fraction = Double(minute) / Double(duration)
            return TripSample(id: minute, time: start.addingTimeInterval(Double(minute * 60)),
                speed: minute == 0 || minute == duration ? 0 : 38 + sin(Double(minute) * 0.7) * 22,
                power: minute == 0 || minute == duration ? 0 : 12 + sin(Double(minute) * 0.9) * 20,
                battery: 66 - fraction * 4,
                coordinate: Coordinate(latitude: 30.245 + fraction * 0.033, longitude: 120.143 + fraction * 0.052))
        }
        return TripRecord(title: title, start: start, end: end, distanceKM: distance, energyKWh: energy, tag: "日常", samples: samples)
    }
}
