import Foundation

/// Errors deliberately contain neither response text, decoding paths nor vehicle identifiers.
public enum ReadOnlyVehicleDataError: String, Error, Sendable, LocalizedError {
    case invalidExpectedVIN, identityMismatch, invalidPayload, invalidTimestamp, outOfRange
    public var errorDescription: String? {
        switch self {
        case .invalidExpectedVIN: "Invalid selected vehicle identifier."
        case .identityMismatch: "Response does not match the selected vehicle."
        case .invalidPayload: "Invalid vehicle data response."
        case .invalidTimestamp: "Invalid vehicle data timestamp."
        case .outOfRange: "Vehicle data value is outside supported bounds."
        }
    }
}

/// Raw Tesla names and units are retained. No field is evidence of command support.
public struct ReadOnlyVehicleIdentity: Codable, Sendable {
    public let vin: String
    public let display_name: String?
    /// Unknown states are preserved verbatim; only the exact value `online` means online.
    public let state: String?
}

public struct ReadOnlyChargeState: Codable, Sendable {
    public let battery_level: Double?
    public let usable_battery_level: Double?
    public let charge_limit_soc: Double?
    /// Tesla battery_range is miles, not kilometres.
    public let battery_range: Double?
    public let charger_power: Double?
    public let charging_state: String?
    public let timestamp: Double?
    public var batteryRangeKilometres: Double? { battery_range.map { $0 * 1.609344 } }
}

public struct ReadOnlyClimateState: Codable, Sendable {
    public let inside_temp: Double?
    public let outside_temp: Double?
    public let driver_temp_setting: Double?
    public let passenger_temp_setting: Double?
    public let timestamp: Double?
}

public struct ReadOnlyVehicleState: Codable, Sendable {
    /// Raw Tesla odometer value in miles.
    public let odometer: Double?
    public let timestamp: Double?
}

public struct ReadOnlyDriveState: Codable, Sendable {
    /// Raw Tesla speed in miles/hour, power in kW.
    public let speed: Double?
    public let power: Double?
    public let shift_state: String?
    public let latitude: Double?
    public let longitude: Double?
    public let timestamp: Double?
}

public struct ReadOnlyLocationData: Codable, Sendable {
    public let latitude: Double?
    public let longitude: Double?
    public let timestamp: Double?
}

public struct ReadOnlyVehicleSections: Codable, Sendable {
    public let charge_state: ReadOnlyChargeState?
    public let climate_state: ReadOnlyClimateState?
    public let vehicle_state: ReadOnlyVehicleState?
    public let drive_state: ReadOnlyDriveState?
    public let location_data: ReadOnlyLocationData?
}

public struct ReadOnlyVehicleData: Sendable {
    public enum Origin: String, Codable, Sendable { case liveRead, noLiveData, cachedSnapshot }
    public enum Section: Sendable { case charge, climate, vehicle, drive, location }
    public enum Freshness: Sendable { case fresh, stale, unknown }

    public let vehicle: ReadOnlyVehicleIdentity
    public let origin: Origin
    /// Backend fetch time, NOT a source/sensor timestamp. Cache reads preserve this value.
    public let fetchedAt: Date?
    /// Caller-provided receipt time; does not renew source freshness.
    public let receivedAt: Date
    public let data: ReadOnlyVehicleSections?
    /// Backend cache hint is not a source freshness guarantee.
    public let cacheStale: Bool?
    /// Deliberately empty even if the backend reports pairing/capability information.
    public var supportedQuickControls: Set<QuickControl> { [] }

    public func sourceTimestamp(for section: Section) -> Date? {
        let milliseconds: Double?
        switch section {
        case .charge: milliseconds = data?.charge_state?.timestamp
        case .climate: milliseconds = data?.climate_state?.timestamp
        case .vehicle: milliseconds = data?.vehicle_state?.timestamp
        case .drive: milliseconds = data?.drive_state?.timestamp
        case .location: milliseconds = data?.location_data?.timestamp
        }
        return milliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }

    /// Freshness must be requested explicitly per section. Future timestamps are unknown.
    /// Even fresh cached values are not a live read and grant no control capability.
    public func freshness(of section: Section, at now: Date, maximumAge: TimeInterval = 120) -> Freshness {
        guard maximumAge.isFinite, maximumAge > 0, now.timeIntervalSince1970.isFinite,
              let source = sourceTimestamp(for: section), source <= now, source <= receivedAt,
              fetchedAt.map({ source <= $0 && $0 <= now && $0 <= receivedAt }) == true else { return .unknown }
        return now.timeIntervalSince(source) < maximumAge ? .fresh : .stale
    }
}

/// Pure backend response decoding. No networking, auth, persistence or demo fallback.
public enum ReadOnlyVehicleDataDecoder {
    private struct Probe: Decodable {
        let connected: Bool
        let live_data: Bool
        let vehicle: ReadOnlyVehicleIdentity
        let fetched_at: String?
        let data: ReadOnlyVehicleSections?
    }
    private struct CacheEnvelope: Decodable { let snapshot: Cache }
    private struct Cache: Decodable {
        let vehicle: ReadOnlyVehicleIdentity
        let fetched_at: String
        let data: ReadOnlyVehicleSections
        let source: String
        let cached: Bool
        let stale: Bool
    }

    public static func decodeProbe(_ bytes: Data, expectedVIN: String, receivedAt: Date) throws -> ReadOnlyVehicleData {
        try validateVIN(expectedVIN)
        let probe = try decode(Probe.self, bytes)
        try validateIdentity(probe.vehicle, expectedVIN)
        guard probe.connected, receivedAt.timeIntervalSince1970.isFinite else { throw ReadOnlyVehicleDataError.invalidPayload }
        let fetched = try probe.fetched_at.map(parseISO)
        try validateSections(probe.data)
        if probe.live_data {
            guard probe.vehicle.state == "online", fetched != nil, let sections = probe.data,
                  sections.charge_state != nil || sections.climate_state != nil || sections.vehicle_state != nil
                    || sections.drive_state != nil || sections.location_data != nil else {
                throw ReadOnlyVehicleDataError.invalidPayload
            }
        } else if probe.data != nil || probe.fetched_at != nil {
            // Offline probes must not masquerade as a cached/live snapshot.
            throw ReadOnlyVehicleDataError.invalidPayload
        }
        return ReadOnlyVehicleData(vehicle: probe.vehicle, origin: probe.live_data ? .liveRead : .noLiveData,
                                   fetchedAt: fetched, receivedAt: receivedAt, data: probe.data, cacheStale: nil)
    }

    /// Accepts the actual route envelope {"snapshot": {...}}, not an unwrapped snapshot.
    public static func decodeCache(_ bytes: Data, expectedVIN: String, receivedAt: Date) throws -> ReadOnlyVehicleData {
        try validateVIN(expectedVIN)
        let cached = try decode(CacheEnvelope.self, bytes).snapshot
        try validateIdentity(cached.vehicle, expectedVIN)
        guard cached.cached, cached.source == "vehicle_data", receivedAt.timeIntervalSince1970.isFinite else {
            throw ReadOnlyVehicleDataError.invalidPayload
        }
        let fetched = try parseISO(cached.fetched_at)
        try validateSections(cached.data)
        return ReadOnlyVehicleData(vehicle: cached.vehicle, origin: .cachedSnapshot, fetchedAt: fetched,
                                   receivedAt: receivedAt, data: cached.data, cacheStale: cached.stale)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ bytes: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw ReadOnlyVehicleDataError.invalidPayload }
    }
    private static func validateVIN(_ vin: String) throws {
        guard vin.range(of: "^[A-HJ-NPR-Z0-9]{17}$", options: .regularExpression) != nil else {
            throw ReadOnlyVehicleDataError.invalidExpectedVIN
        }
    }
    private static func validateIdentity(_ vehicle: ReadOnlyVehicleIdentity, _ expected: String) throws {
        guard vehicle.vin.range(of: "^[A-HJ-NPR-Z0-9]{17}$", options: .regularExpression) != nil,
              vehicle.vin == expected else { throw ReadOnlyVehicleDataError.identityMismatch }
    }
    private static func parseISO(_ text: String) throws -> Date {
        // Backend emits UTC ISO dates. Reject whitespace, numeric epoch values and partial dates.
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$", options: .regularExpression) != nil else {
            throw ReadOnlyVehicleDataError.invalidTimestamp
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: text), date.timeIntervalSince1970.isFinite else {
            throw ReadOnlyVehicleDataError.invalidTimestamp
        }
        return date
    }
    private static func bounded(_ values: [Double?], _ range: ClosedRange<Double>) throws {
        for case let value? in values {
            guard value.isFinite, range.contains(value) else { throw ReadOnlyVehicleDataError.outOfRange }
        }
    }
    private static func validateSections(_ sections: ReadOnlyVehicleSections?) throws {
        guard let sections else { return }
        let charge = sections.charge_state, climate = sections.climate_state
        let vehicle = sections.vehicle_state, drive = sections.drive_state, location = sections.location_data
        try bounded([charge?.battery_level, charge?.usable_battery_level, charge?.charge_limit_soc], 0...100)
        try bounded([charge?.battery_range], 0...1_000)
        try bounded([charge?.charger_power], 0...1_000)
        try bounded([climate?.inside_temp, climate?.outside_temp, climate?.driver_temp_setting, climate?.passenger_temp_setting], -100...100)
        try bounded([vehicle?.odometer], 0...10_000_000)
        try bounded([drive?.speed], 0...300)
        try bounded([drive?.power], -1_000...2_000)
        try bounded([drive?.latitude, location?.latitude], -90...90)
        try bounded([drive?.longitude, location?.longitude], -180...180)
        // Plausible Tesla millisecond epochs (2000–2100); never guess seconds vs milliseconds.
        for case let timestamp? in [charge?.timestamp, climate?.timestamp, vehicle?.timestamp, drive?.timestamp, location?.timestamp] {
            guard timestamp.isFinite, (946_684_800_000...4_102_444_800_000).contains(timestamp) else {
                throw ReadOnlyVehicleDataError.invalidTimestamp
            }
        }
    }
}
