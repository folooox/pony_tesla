import Foundation

/// Only fixed, non-sensitive failures cross the server-data boundary.
public enum NativeHistoryError: Error, Sendable, Equatable {
    case invalidData, simulationNotAllowed, wrongVehicle, outsideRetention
}

public enum NativeHistoryKind: String, Decodable, Sendable { case trip, charge }
public enum NativeHistorySource: String, Decodable, Sendable {
    case telemetry, simulation
    public var label: String { self == .telemetry ? "真实遥测" : "模拟数据" }
}

private enum NativeHistoryWire {
    static let simulationKey = CodingUserInfoKey(rawValue: "PonyCore.NativeHistory.allowSimulation")!
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    static func date(_ value: String) throws -> Date {
        guard matches(value, #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$"#) else { throw NativeHistoryError.invalidData }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw NativeHistoryError.invalidData }
        // Foundation may normalize invalid calendar dates. Reject that normalization.
        formatter.formatOptions = [.withInternetDateTime]
        guard formatter.string(from: date).prefix(19) == value.prefix(19) else { throw NativeHistoryError.invalidData }
        return date
    }
    static func number(_ value: Double?, _ range: ClosedRange<Double>) throws {
        if let value, !value.isFinite || !range.contains(value) { throw NativeHistoryError.invalidData }
    }
    static func vin(_ value: String) -> Bool { matches(value, "^[A-HJ-NPR-Z0-9]{17}$") }
}

/// Each call owns its decoder/formatters; no non-Sendable Foundation instance is shared.
/// Call validate(expectedVIN:now:) before displaying or caching a response for an owner request.
public enum NativeHistoryDecoder {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, allowSimulation: Bool = false) throws -> T {
        let decoder = JSONDecoder()
        decoder.userInfo[NativeHistoryWire.simulationKey] = allowSimulation
        do { return try decoder.decode(type, from: data) }
        catch let error as NativeHistoryError { throw error }
        catch { throw NativeHistoryError.invalidData }
    }
}

public struct NativeHistorySample: Decodable, Sendable, Identifiable {
    public let id: String?
    public let kind: NativeHistoryKind?
    public let at: Date
    public let gear: String?
    public let latitude: Double?
    public let longitude: Double?
    public let speedKPH: Double?
    public let powerKW: Double?
    public let batteryPercent: Double?
    public let odometerKM: Double?
    public let chargeState: String?
    public let chargerType: String?
    public let energyAddedKWh: Double?
    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }
    private enum CodingKeys: String, CodingKey {
        case id, kind, at, gear, latitude, longitude
        case speedKPH = "speed_kph", powerKW = "power_kw", batteryPercent = "battery_percent", odometerKM = "odometer_km"
        case chargeState = "charge_state", chargerType = "charger_type", energyAddedKWh = "energy_added_kwh"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        kind = try c.decodeIfPresent(NativeHistoryKind.self, forKey: .kind)
        at = try NativeHistoryWire.date(c.decode(String.self, forKey: .at))
        gear = try c.decodeIfPresent(String.self, forKey: .gear)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        speedKPH = try c.decodeIfPresent(Double.self, forKey: .speedKPH)
        powerKW = try c.decodeIfPresent(Double.self, forKey: .powerKW)
        batteryPercent = try c.decodeIfPresent(Double.self, forKey: .batteryPercent)
        odometerKM = try c.decodeIfPresent(Double.self, forKey: .odometerKM)
        chargeState = try c.decodeIfPresent(String.self, forKey: .chargeState)
        chargerType = try c.decodeIfPresent(String.self, forKey: .chargerType)
        energyAddedKWh = try c.decodeIfPresent(Double.self, forKey: .energyAddedKWh)
        try NativeHistoryWire.number(latitude, -90...90)
        try NativeHistoryWire.number(longitude, -180...180)
        try NativeHistoryWire.number(speedKPH, 0...400)
        try NativeHistoryWire.number(powerKW, -1000...2000)
        try NativeHistoryWire.number(batteryPercent, 0...100)
        try NativeHistoryWire.number(odometerKM, 0...10_000_000)
        try NativeHistoryWire.number(energyAddedKWh, 0...100_000)
        guard gear.map({ ["P", "D", "R", "N"].contains($0) }) ?? true,
              chargeState.map({ ["Charging", "Starting", "Stopped", "Complete", "Disconnected", "NoPower", "unknown"].contains($0) }) ?? true,
              chargerType.map({ ["ac", "dc", "unknown"].contains($0) }) ?? true else { throw NativeHistoryError.invalidData }
    }
    fileprivate func validate(kind expected: NativeHistoryKind) throws {
        guard kind == nil || kind == expected else { throw NativeHistoryError.invalidData }
        if expected == .trip {
            guard chargeState == nil, chargerType == nil, energyAddedKWh == nil else { throw NativeHistoryError.invalidData }
        } else {
            guard gear == nil, latitude == nil, longitude == nil, speedKPH == nil, powerKW == nil, odometerKM == nil else { throw NativeHistoryError.invalidData }
        }
    }
}

/// A partial record can lack a witnessed start, a witnessed end, or both.
/// complete is server evidence, never inferred from elapsed wall time. An in-progress
/// record remains open; data_gap/counter_reset are incomplete, not completed sessions.
public struct NativeHistoryRecord: Decodable, Sendable, Identifiable {
    public let id: String
    public let vin: String
    public let kind: NativeHistoryKind
    public let source: NativeHistorySource
    public let start: Date?
    public let end: Date?
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let startObserved: Bool
    public let complete: Bool
    public let endReason: String
    public let revision: Int
    public let tag: String?
    public let note: String?
    public let sampleCount: Int?
    /// nil means detail unavailable; [] means detail was supplied with no samples.
    public let samples: [NativeHistorySample]?
    public let distanceKM: Double?
    public let netEnergyKWh: Double?
    public let energyAddedKWh: Double?
    public let energyMethod: String?
    public let energyBasis: String?
    public let chargerType: String?
    public let cost: Double?
    public let costCurrency: String?
    public let retentionHours: Int?
    public static let retention: TimeInterval = 168 * 3600
    private enum CodingKeys: String, CodingKey {
        case id, vin, kind, source, start, end, complete, revision, tag, note, samples, cost
        case firstObservedAt = "first_observed_at", lastObservedAt = "last_observed_at", startObserved = "start_observed", endReason = "end_reason"
        case sampleCount = "sample_count", distanceKM = "distance_km", netEnergyKWh = "net_energy_kwh", energyAddedKWh = "energy_added_kwh"
        case energyMethod = "energy_method", energyBasis = "energy_basis", chargerType = "charger_type", costCurrency = "cost_currency", retentionHours = "retention_hours"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        vin = try c.decode(String.self, forKey: .vin)
        kind = try c.decode(NativeHistoryKind.self, forKey: .kind)
        source = try c.decode(NativeHistorySource.self, forKey: .source)
        guard source != .simulation || decoder.userInfo[NativeHistoryWire.simulationKey] as? Bool == true else { throw NativeHistoryError.simulationNotAllowed }
        start = try c.decodeIfPresent(String.self, forKey: .start).map(NativeHistoryWire.date)
        end = try c.decodeIfPresent(String.self, forKey: .end).map(NativeHistoryWire.date)
        firstObservedAt = try NativeHistoryWire.date(c.decode(String.self, forKey: .firstObservedAt))
        lastObservedAt = try NativeHistoryWire.date(c.decode(String.self, forKey: .lastObservedAt))
        startObserved = try c.decode(Bool.self, forKey: .startObserved)
        complete = try c.decode(Bool.self, forKey: .complete)
        endReason = try c.decode(String.self, forKey: .endReason)
        revision = try c.decode(Int.self, forKey: .revision)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount)
        samples = try c.decodeIfPresent([NativeHistorySample].self, forKey: .samples)
        distanceKM = try c.decodeIfPresent(Double.self, forKey: .distanceKM)
        netEnergyKWh = try c.decodeIfPresent(Double.self, forKey: .netEnergyKWh)
        energyAddedKWh = try c.decodeIfPresent(Double.self, forKey: .energyAddedKWh)
        energyMethod = try c.decodeIfPresent(String.self, forKey: .energyMethod)
        energyBasis = try c.decodeIfPresent(String.self, forKey: .energyBasis)
        chargerType = try c.decodeIfPresent(String.self, forKey: .chargerType)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        costCurrency = try c.decodeIfPresent(String.self, forKey: .costCurrency)
        retentionHours = try c.decodeIfPresent(Int.self, forKey: .retentionHours)
        try validateStructure()
    }
    private func validateStructure() throws {
        let terminalReasons = kind == .trip ? ["parked"] : ["Stopped", "Complete", "Disconnected", "NoPower"]
        let partialReasons = kind == .trip ? ["data_gap", "in_progress"] : ["data_gap", "counter_reset", "in_progress"]
        guard (terminalReasons + partialReasons).contains(endReason) else { throw NativeHistoryError.invalidData }
        guard NativeHistoryWire.matches(id, "^[a-f0-9]{64}$"), NativeHistoryWire.vin(vin), revision > 0,
              firstObservedAt <= lastObservedAt, startObserved == (start != nil),
              start.map({ $0 <= firstObservedAt }) ?? true,
              end.map({ $0 >= lastObservedAt && $0 >= (start ?? firstObservedAt) }) ?? true,
              !complete || (startObserved && end != nil && terminalReasons.contains(endReason)),
              endReason != "in_progress" || end == nil,
              sampleCount.map({ $0 >= 0 }) ?? true,
              retentionHours.map({ $0 == 168 }) ?? true,
              cost == nil, costCurrency == nil else { throw NativeHistoryError.invalidData }
        try NativeHistoryWire.number(distanceKM, 0...10_000_000)
        try NativeHistoryWire.number(netEnergyKWh, -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude)
        try NativeHistoryWire.number(energyAddedKWh, 0...100_000)
        if kind == .trip {
            guard energyAddedKWh == nil, energyBasis == nil, chargerType == nil,
                  energyMethod == (netEnergyKWh == nil ? "insufficient_data" : "trapezoid_power_estimate") else { throw NativeHistoryError.invalidData }
        } else {
            guard distanceKM == nil, netEnergyKWh == nil,
                  let energyBasis,
                  ["battery_session_counter", "ac_charger_session_counter", "dc_charger_session_counter"].contains(energyBasis),
                  energyMethod == (energyAddedKWh == nil ? "insufficient_data" : "observed_session_counter_delta"),
                  chargerType.map({ ["ac", "dc", "unknown"].contains($0) }) ?? true else { throw NativeHistoryError.invalidData }
        }
        if let samples {
            guard sampleCount.map({ $0 == samples.count }) ?? true else { throw NativeHistoryError.invalidData }
            var previous: Date?
            var ids = Set<String>()
            for sample in samples {
                try sample.validate(kind: kind)
                guard sample.at >= firstObservedAt, sample.at <= lastObservedAt,
                      previous.map({ sample.at > $0 }) ?? true else { throw NativeHistoryError.invalidData }
                if let id = sample.id, !ids.insert(id).inserted { throw NativeHistoryError.invalidData }
                previous = sample.at
            }
            if let first = samples.first, let last = samples.last {
                guard first.at == firstObservedAt, last.at == lastObservedAt else { throw NativeHistoryError.invalidData }
            }
        }
    }
    /// The caller supplies its captured request VIN and clock; decoding alone cannot verify ownership.
    /// This checks vehicle context, not account authorization (which remains the server's job).
    public func validate(expectedVIN: String, now: Date) throws {
        guard vin == expectedVIN, NativeHistoryWire.vin(expectedVIN) else { throw NativeHistoryError.wrongVehicle }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              firstObservedAt > now.addingTimeInterval(-Self.retention), lastObservedAt <= now,
              start.map({ $0 > now.addingTimeInterval(-Self.retention) && $0 <= now }) ?? true,
              end.map({ $0 <= now }) ?? true else { throw NativeHistoryError.outsideRetention }
    }
    /// No sorting, interpolation, distance inference, or bridging missing/invalid coordinates.
    public func traceSegments(maximumGap: TimeInterval = 120) -> [[NativeHistorySample]] {
        guard maximumGap.isFinite, maximumGap > 0 else { return [] }
        var result: [[NativeHistorySample]] = []
        var current: [NativeHistorySample] = []
        func flush() { if !current.isEmpty { result.append(current); current = [] } }
        for sample in samples ?? [] {
            guard sample.coordinate != nil else { flush(); continue }
            if let previous = current.last, sample.at.timeIntervalSince(previous.at) > maximumGap { flush() }
            current.append(sample)
        }
        flush()
        return result
    }
}

public struct NativeHistoryPage: Decodable, Sendable {
    public let records: [NativeHistoryRecord]
    public let nextCursor: String?
    public let retentionHours: Int
    public let sourcePolicy: String
    private enum CodingKeys: String, CodingKey {
        case records, nextCursor = "next_cursor", retentionHours = "retention_hours", sourcePolicy = "source_policy"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decode([NativeHistoryRecord].self, forKey: .records)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        retentionHours = try c.decode(Int.self, forKey: .retentionHours)
        sourcePolicy = try c.decode(String.self, forKey: .sourcePolicy)
        guard retentionHours == 168, ["telemetry_only", "telemetry_and_simulation"].contains(sourcePolicy),
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
              Set(records.map(\.id)).count == records.count else { throw NativeHistoryError.invalidData }
        if sourcePolicy == "telemetry_and_simulation", decoder.userInfo[NativeHistoryWire.simulationKey] as? Bool != true { throw NativeHistoryError.simulationNotAllowed }
        if sourcePolicy == "telemetry_only", records.contains(where: { $0.source != .telemetry }) { throw NativeHistoryError.invalidData }
    }
    public func validate(expectedVIN: String, now: Date) throws {
        guard NativeHistoryWire.vin(expectedVIN), now.timeIntervalSinceReferenceDate.isFinite else { throw NativeHistoryError.invalidData }
        for record in records { try record.validate(expectedVIN: expectedVIN, now: now) }
    }
}

public enum NativeHistoryCSV {
    private static func cell(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = ["=", "+", "-", "@"].contains(where: { trimmed.hasPrefix($0) }) ? "'" + raw : raw
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func export(_ records: [NativeHistoryRecord], expectedVIN: String, now: Date) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rows = [["source", "id", "vin", "kind", "start", "end", "first_observed_at", "last_observed_at", "start_observed", "complete", "end_reason", "distance_km", "net_energy_kwh", "energy_added_kwh", "energy_method", "energy_basis", "charger_type", "cost", "cost_currency", "tag", "note"]]
        for record in records {
            try record.validate(expectedVIN: expectedVIN, now: now)
            rows.append([record.source.label, record.id, record.vin, record.kind.rawValue,
                         record.start.map { formatter.string(from: $0) } ?? "", record.end.map { formatter.string(from: $0) } ?? "",
                         formatter.string(from: record.firstObservedAt), formatter.string(from: record.lastObservedAt),
                         String(record.startObserved), String(record.complete), record.endReason,
                         record.distanceKM.map { String($0) } ?? "", record.netEnergyKWh.map { String($0) } ?? "",
                         record.energyAddedKWh.map { String($0) } ?? "", record.energyMethod ?? "", record.energyBasis ?? "", record.chargerType ?? "",
                         "", "", record.tag ?? "", record.note ?? ""])
        }
        return "\u{FEFF}" + rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
