import Foundation

public struct Coordinate: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    public var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

public enum TripMetric: String, CaseIterable, Identifiable, Sendable {
    case speed = "速度", power = "功率", battery = "电量"
    public var id: Self { self }
    public var unit: String { switch self { case .speed: "km/h"; case .power: "kW"; case .battery: "%" } }
}

public struct TripSample: Identifiable, Codable, Sendable, Equatable {
    public let id: Int
    public let time: Date
    public var speed: Double?
    public var power: Double?
    public var battery: Double?
    public var coordinate: Coordinate?
    public init(id: Int, time: Date, speed: Double?, power: Double?, battery: Double?, coordinate: Coordinate?) {
        self.id = id; self.time = time; self.speed = speed; self.power = power; self.battery = battery; self.coordinate = coordinate
    }
    public func value(for metric: TripMetric) -> Double? {
        let value: Double?
        switch metric { case .speed: value = speed; case .power: value = power; case .battery: value = battery }
        guard let value, value.isFinite else { return nil }
        switch metric {
        case .speed: return value >= 0 ? value : nil
        case .power: return value // Negative power represents regeneration, not invalid data.
        case .battery: return (0...100).contains(value) ? value : nil
        }
    }
}

public struct TripSegment: Identifiable, Sendable {
    public let id: Int
    public let samples: [TripSample]
}

public struct TripRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public let start: Date
    public let end: Date
    public var distanceKM: Double
    public var energyKWh: Double?
    public var note: String
    public var tag: String
    public var samples: [TripSample]
    public init(id: UUID = UUID(), title: String, start: Date, end: Date, distanceKM: Double, energyKWh: Double?, note: String = "", tag: String = "", samples: [TripSample]) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.distanceKM = distanceKM
        self.energyKWh = energyKWh; self.note = note; self.tag = tag; self.samples = samples.sorted { $0.time < $1.time }
    }
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    public var averageWhPerKM: Double? {
        guard distanceKM.isFinite, distanceKM > 0, let energyKWh, energyKWh.isFinite, energyKWh >= 0 else { return nil }
        return energyKWh * 1000 / distanceKM
    }
    public func sample(at time: Date, maximumDistance: TimeInterval = 60) -> TripSample? {
        guard time >= start, time <= end,
              let nearest = samples.min(by: { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }),
              abs(nearest.time.timeIntervalSince(time)) <= maximumDistance else { return nil }
        return nearest
    }
    /// Gaps and invalid samples break lines; never draw a made-up route across missing data.
    public func segments(metric: TripMetric? = nil, maximumGap: TimeInterval = 120) -> [TripSegment] {
        var result: [TripSegment] = []
        var current: [TripSample] = []
        func flush() { if !current.isEmpty { result.append(TripSegment(id: result.count, samples: current)); current = [] } }
        for point in samples {
            let valid = metric.map { point.value(for: $0) != nil } ?? (point.coordinate?.isValid == true)
            guard valid, point.time >= start, point.time <= end else { flush(); continue }
            if let last = current.last, point.time.timeIntervalSince(last.time) > maximumGap { flush() }
            current.append(point)
        }
        flush()
        return result
    }
}

public enum HistoryPolicy {
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public static func visible(_ trips: [TripRecord], now: Date) -> [TripRecord] {
        trips.filter { $0.start <= $0.end && $0.end <= now && $0.end > now.addingTimeInterval(-retention) }
            .sorted { $0.start > $1.start }
    }
    public static func onDay(_ day: Date, trips: [TripRecord], calendar: Calendar = .current) -> [TripRecord] {
        trips.filter { calendar.isDate($0.start, inSameDayAs: day) }
    }
}

public struct TripSummary: Sendable {
    public let count: Int
    public let distanceKM: Double?
    public let energyKWh: Double?
    public var averageWhPerKM: Double? { guard let energyKWh, let distanceKM, distanceKM > 0 else { return nil }; return energyKWh * 1000 / distanceKM }
    public init(trips: [TripRecord]) {
        count = trips.count
        distanceKM = trips.allSatisfy { $0.distanceKM.isFinite && $0.distanceKM >= 0 }
            ? trips.reduce(0) { $0 + $1.distanceKM } : nil
        let energy = trips.compactMap(\.energyKWh)
        energyKWh = !trips.isEmpty && energy.count == trips.count && energy.allSatisfy { $0.isFinite && $0 >= 0 }
            ? energy.reduce(0, +) : nil
    }
}

public enum TripCSV {
    private static func cell(_ raw: String) -> String {
        // Spreadsheet formula injection also applies to user-controlled labels and notes.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = ["=", "+", "-", "@"].contains(where: { trimmed.hasPrefix($0) }) ? "'" + raw : raw
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func export(_ trips: [TripRecord], now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let header = "数据来源,行程,开始时间,结束时间,里程_km,估算耗电_kWh,标签,备注"
        let rows = HistoryPolicy.visible(trips, now: now).map { trip in
            ["模拟数据", trip.title, formatter.string(from: trip.start), formatter.string(from: trip.end), String(trip.distanceKM), trip.energyKWh.map { String($0) } ?? "", trip.tag, trip.note].map(cell).joined(separator: ",")
        }
        return "\u{FEFF}" + ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
