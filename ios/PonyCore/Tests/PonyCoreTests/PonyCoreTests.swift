import Foundation
import Testing
@testable import PonyCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private func trip(end: Date = now, energy: Double? = 2) -> TripRecord {
    TripRecord(title: "家 → 公司", start: end.addingTimeInterval(-1800), end: end, distanceKM: 10, energyKWh: energy, samples: [])
}

@Test func retentionUsesEndTimeAndExcludesExactBoundaryAndFuture() {
    let edge = now.addingTimeInterval(-HistoryPolicy.retention)
    let records = [trip(), trip(end: edge), trip(end: edge.addingTimeInterval(1)), trip(end: now.addingTimeInterval(1))]
    #expect(HistoryPolicy.visible(records, now: now).count == 2)
}
@Test func retentionAcceptsTripCrossingBoundary() {
    let record = trip(end: now.addingTimeInterval(-HistoryPolicy.retention + 60))
    #expect(HistoryPolicy.visible([record], now: now).count == 1)
}
@Test func dailyFilterUsesProvidedCalendar() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let record = trip(end: now)
    #expect(HistoryPolicy.onDay(record.start, trips: [record], calendar: calendar).count == 1)
    #expect(HistoryPolicy.onDay(record.start.addingTimeInterval(86400), trips: [record], calendar: calendar).isEmpty)
}
@Test func missingEnergyDoesNotBecomeZeroOrPartialAverage() {
    let summary = TripSummary(trips: [trip(), trip(energy: nil)])
    #expect(summary.distanceKM == 20)
    #expect(summary.energyKWh == nil)
    #expect(summary.averageWhPerKM == nil)
    #expect(TripSummary(trips: []).averageWhPerKM == nil)
}
@Test func summaryIsDistanceWeighted() {
    var a = trip(energy: 1); a.distanceKM = 5
    var b = trip(energy: 4); b.distanceKM = 20
    #expect(TripSummary(trips: [a, b]).averageWhPerKM == 200)
}
@Test func invalidDistanceInvalidatesAggregateInsteadOfInflatingEfficiency() {
    var record = trip(); record.distanceKM = .nan
    let summary = TripSummary(trips: [record, trip()])
    #expect(summary.distanceKM == nil)
    #expect(summary.averageWhPerKM == nil)
}
@Test func invalidReadingsAreNotShownAsRealValues() {
    let point = TripSample(id: 1, time: now, speed: -1, power: -12, battery: 101, coordinate: nil)
    #expect(point.value(for: .speed) == nil)
    #expect(point.value(for: .power) == -12)
    #expect(point.value(for: .battery) == nil)
    #expect(!Coordinate(latitude: .nan, longitude: 1).isValid)
}
@Test func mapAndChartBreakAtDataGaps() {
    let points = [0, 60, 600, 660].enumerated().map { index, offset in
        TripSample(id: index, time: now.addingTimeInterval(Double(offset)), speed: 10, power: 1, battery: 60, coordinate: Coordinate(latitude: 30, longitude: 120))
    }
    let record = TripRecord(title: "Gap", start: now, end: now.addingTimeInterval(660), distanceKM: 10, energyKWh: nil, samples: points)
    #expect(record.segments().count == 2)
    #expect(record.segments(metric: .speed).count == 2)
    #expect(record.sample(at: now.addingTimeInterval(300)) == nil)
    #expect(record.sample(at: now.addingTimeInterval(60))?.id == 1)
}
@Test func absentCoordinatesSplitMapButNotSpeedCurve() {
    var points = (0...2).map { TripSample(id: $0, time: now.addingTimeInterval(Double($0 * 60)), speed: 10, power: 1, battery: 60, coordinate: Coordinate(latitude: 30, longitude: 120)) }
    points[1].coordinate = nil
    let record = TripRecord(title: "Gap", start: now, end: now.addingTimeInterval(120), distanceKM: 1, energyKWh: nil, samples: points)
    #expect(record.segments().count == 2)
    #expect(record.segments(metric: .speed).count == 1)
}
@Test func layoutSanitizesUnknownDuplicateAndExcessiveValues() {
    let layout = ControlLayout(rawValues: ["lock", "unknown", "lock", "fan", "horn", "trunk", "sentry", "lights"])
    #expect(layout.controls == [.lock, .horn, .trunk, .sentry])
    #expect(ControlLayout(rawValues: []).controls.isEmpty)
}
@Test func layoutMovesAndLimitsAdditions() {
    var layout = ControlLayout()
    layout.move(from: IndexSet(integer: 0), to: 4)
    #expect(layout.controls == [.climate, .trunk, .sentry, .lock])
    layout.add(.horn)
    #expect(layout.controls.count == 4)
    layout.remove(at: IndexSet(integer: 1)); layout.add(.horn)
    #expect(layout.controls.last == .horn)
    layout.move(from: IndexSet(integer: 100), to: 0)
    #expect(layout.controls.count == 4)
}
@Test func freshnessCannotManufactureOnlineStatus() {
    var snapshot = VehicleSnapshot(now: now)
    #expect(snapshot.canControl(at: now))
    #expect(!snapshot.canControl(at: now.addingTimeInterval(120)))
    #expect(!snapshot.canControl(at: now.addingTimeInterval(-1)))
    snapshot.status = .asleep
    #expect(!snapshot.canControl(at: now))
}
@Test func csvEscapesLabelsAndFiltersExpiredRecords() {
    var record = trip(); record.title = "=CMD(1)"; record.note = "一句,\"备注\"\n下一行"
    let csv = TripCSV.export([record, trip(end: now.addingTimeInterval(-HistoryPolicy.retention))], now: now)
    #expect(csv.contains("'="))
    #expect(csv.contains("\"\"备注\"\""))
    #expect(csv.contains("模拟数据"))
}
@Test func commandsChangeOnlyAfterAcknowledgment() async throws {
    let service = DemoVehicleService(now: now, latency: .zero)
    let unlocked = try await service.execute(.quick(.unlock), now: now)
    #expect(unlocked.locked == false)
    let result = try await service.dashboard(now: now)
    #expect(result.vehicle.locked == false)
    let charging = try await service.execute(.setCharging(false), now: now)
    #expect(!charging.charging)
}
@Test func offlineCannotExecuteAndRefreshDoesNotChangeTimestamp() async throws {
    let service = DemoVehicleService(scenario: .offline, now: now, latency: .zero)
    await #expect(throws: ServiceError.offline) { try await service.execute(.quick(.unlock), now: now) }
    let data = try await service.dashboard(now: now.addingTimeInterval(300))
    #expect(data.vehicle.fetchedAt == now)
    #expect(data.vehicle.locked == true)
}
@Test func unsupportedAndInvalidSettingsDoNotMutateState() async throws {
    let service = DemoVehicleService(scenario: .missingData, now: now, latency: .zero)
    await #expect(throws: ServiceError.unsupported) { try await service.execute(.quick(.windows), now: now) }
    await #expect(throws: ServiceError.invalidValue) { try await service.execute(.setChargeLimit(101), now: now) }
    await #expect(throws: ServiceError.invalidValue) { try await service.execute(.setClimate(temperature: .nan, mode: .normal), now: now) }
    #expect(try await service.dashboard(now: now).vehicle.chargeLimit == 80)
}
@Test func expiredAuthorizationIsDistinctFromServiceFailure() async {
    let service = DemoVehicleService(scenario: .expired, now: now, latency: .zero)
    await #expect(throws: ServiceError.unauthorized) { try await service.dashboard(now: now) }
}
@Test func deleteAndMetadataOperateOnDemoHistory() async throws {
    let service = DemoVehicleService(now: now, latency: .zero)
    let first = try await service.dashboard(now: now).trips[0]
    try await service.saveTrip(id: first.id, tag: "通勤", note: "备注")
    #expect(try await service.dashboard(now: now).trips.first(where: { $0.id == first.id })?.tag == "通勤")
    try await service.deleteHistory()
    let empty = try await service.dashboard(now: now)
    #expect(empty.trips.isEmpty && empty.charges.isEmpty)
}

@Test func concurrentCommandsHaveOnlyOneAcknowledgment() async {
    let service = DemoVehicleService(now: now, latency: .milliseconds(50))
    let successes = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<2 {
            group.addTask {
                do { _ = try await service.execute(.quick(.sentry), now: now); return true }
                catch { #expect(error as? ServiceError == .busy); return false }
            }
        }
        var count = 0
        for await succeeded in group { if succeeded { count += 1 } }
        return count
    }
    #expect(successes == 1)
}

@Test func cancellationDoesNotChangeVehicleAndReleasesCommandLock() async throws {
    let service = DemoVehicleService(now: now, latency: .milliseconds(50))
    let pending = Task { try await service.execute(.quick(.unlock), now: now) }
    pending.cancel()
    do { _ = try await pending.value; Issue.record("Cancelled command was acknowledged") } catch { #expect(error is CancellationError) }
    let snapshot = try await service.dashboard(now: now)
    #expect(snapshot.vehicle.locked == true)
    _ = try await service.execute(.setChargeLimit(90), now: now)
}
