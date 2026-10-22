import Foundation
import Testing
@testable import PonyCore

struct NativeHistoryTests {
    let vin = "LRW3E7FA0NC123456"
    let first = "2026-10-19T08:00:00Z"
    let last = "2026-10-19T08:01:00.000Z"
    // Fixed relative clock: no fixture ever depends on Date.now or the local time zone.
    let now = Date(timeIntervalSince1970: 1_792_396_920) // 2026-10-19T08:02:00Z

    func record(_ changes: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = [
            "id": String(repeating: "a", count: 64), "vin": vin, "kind": "trip", "source": "telemetry",
            "start": first, "end": last, "first_observed_at": first, "last_observed_at": last,
            "start_observed": true, "complete": true, "end_reason": "parked", "revision": 1,
            "tag": "", "note": "", "sample_count": 2, "distance_km": NSNull(), "net_energy_kwh": NSNull(),
            "energy_method": "insufficient_data", "cost": NSNull(), "cost_currency": NSNull()
        ]
        value.merge(changes) { _, new in new }
        return value
    }
    func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func decode(_ value: [String: Any], simulation: Bool = false) throws -> NativeHistoryRecord {
        try NativeHistoryDecoder.decode(NativeHistoryRecord.self, from: data(value), allowSimulation: simulation)
    }
    func rejects(_ value: [String: Any]) -> Bool {
        do { _ = try decode(value); return false } catch { return error is NativeHistoryError }
    }
    func sample(_ at: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["at": at]
        result.merge(fields) { _, new in new }
        return result
    }

    @Test func listAndDetailUseOneModelWithoutDemoDefaults() throws {
        let envelope: [String: Any] = ["records": [record()], "next_cursor": NSNull(), "retention_hours": 168, "source_policy": "telemetry_only"]
        let page = try NativeHistoryDecoder.decode(NativeHistoryPage.self, from: data(envelope))
        try page.validate(expectedVIN: vin, now: now)
        let row = try #require(page.records.first)
        #expect(row.samples == nil)
        #expect(row.sampleCount == 2)
        #expect(row.distanceKM == nil && row.netEnergyKWh == nil && row.cost == nil)
        #expect(page.nextCursor == nil && page.retentionHours == 168)
        var detailFixture = record(["samples": [sample(first, ["battery_percent": 80]), sample(last, ["battery_percent": 79])], "retention_hours": 168])
        detailFixture.removeValue(forKey: "sample_count") // Actual detail omits the list-only count.
        let detail = try decode(detailFixture)
        #expect(detail.sampleCount == nil)
        #expect(detail.samples?.count == 2)
        #expect(detail.distanceKM == nil && detail.netEnergyKWh == nil) // Battery never invents energy or distance.
        #expect(detail.firstObservedAt == Date(timeIntervalSince1970: 1_792_396_800))
        let emptyDetail = try decode(record(["sample_count": 0, "samples": []]))
        #expect(emptyDetail.samples?.isEmpty == true)
        let missing = try decode(record(["tag": NSNull(), "note": NSNull(), "sample_count": NSNull()]))
        #expect(missing.tag == nil && missing.note == nil && missing.sampleCount == nil)
    }

    @Test func strictSourcePolicyAndExplicitSimulationNeverLeakBetweenCalls() throws {
        #expect(rejects(record(["source": "unknown"])))
        #expect(rejects(record(["kind": "drive"])))
        #expect(rejects(record(["source": "simulation"])))
        let simulated = try decode(record(["source": "simulation"]), simulation: true)
        #expect(simulated.source == .simulation)
        #expect(rejects(record(["source": "simulation"])))
        #expect(try decode(record()).source == .telemetry)
        let envelope: [String: Any] = ["records": [], "retention_hours": 168, "source_policy": "telemetry_and_simulation"]
        #expect(throws: NativeHistoryError.simulationNotAllowed) {
            try NativeHistoryDecoder.decode(NativeHistoryPage.self, from: data(envelope))
        }
        let allowed = try NativeHistoryDecoder.decode(NativeHistoryPage.self, from: data(envelope), allowSimulation: true)
        #expect(allowed.records.isEmpty)
    }

    @Test func sampleBoundsKindsAndFiniteValuesAreValidated() throws {
        for fields in [
            ["battery_percent": 101], ["speed_kph": -1], ["speed_kph": 401], ["latitude": 91], ["longitude": -181],
            ["power_kw": -1001], ["power_kw": 2001], ["odometer_km": -1], ["energy_added_kwh": -1], ["gear": "X"], ["kind": "charge"]
        ] as [[String: Any]] {
            #expect(rejects(record(["samples": [sample(first, fields), sample(last)]])))
        }
        let valid = try decode(record(["net_energy_kwh": -0.2, "distance_km": 0, "energy_method": "trapezoid_power_estimate",
            "samples": [sample(first, ["power_kw": -10, "latitude": -90, "longitude": 180]), sample(last)]]))
        #expect(valid.netEnergyKWh == -0.2 && valid.distanceKM == 0)
        #expect(valid.samples?.first?.coordinate?.isValid == true)
        #expect(rejects(record(["energy_added_kwh": 1])))
        #expect(rejects(record(["distance_km": -1])))
        #expect(rejects(record(["cost": 3])))
        #expect(rejects(record(["cost_currency": "CNY"])))
        // Non-finite JSON numeric overflow is rejected with a sanitized error.
        let overflow = Data("{\"at\":\"2026-10-19T08:00:00Z\",\"power_kw\":1e999}".utf8)
        #expect(throws: NativeHistoryError.invalidData) { try NativeHistoryDecoder.decode(NativeHistorySample.self, from: overflow) }
    }

    @Test func incompleteChargeAndCounterResetDoNotBecomeCompleteOrInventCost() throws {
        let changes: [String: Any] = ["kind": "charge", "start": NSNull(), "end": NSNull(), "start_observed": false,
            "complete": false, "end_reason": "counter_reset", "charger_type": "dc", "energy_basis": "dc_charger_session_counter",
            "energy_added_kwh": NSNull(), "samples": [sample(first, ["kind": "charge", "id": "a", "energy_added_kwh": 12]),
                                                       sample(last, ["kind": "charge", "id": "b", "energy_added_kwh": 1])]]
        let charge = try decode(record(changes))
        #expect(!charge.complete && charge.start == nil && charge.end == nil)
        #expect(charge.energyAddedKWh == nil && charge.cost == nil)
        #expect(charge.energyBasis == "dc_charger_session_counter")
        var bad = changes; bad["distance_km"] = 1
        #expect(rejects(record(bad)))
        bad = changes; bad["complete"] = true
        #expect(rejects(record(bad)))
        var ongoing = changes; ongoing["end_reason"] = "in_progress"
        #expect(try decode(record(ongoing)).end == nil)
    }

    @Test func endReasonsAndCompletionAreKindSpecific() throws {
        for reason in ["unknown", "Complete", "Stopped", "Disconnected", "NoPower", "counter_reset"] {
            #expect(rejects(record(["end_reason": reason])))
            #expect(rejects(record(["end_reason": reason, "complete": false])))
        }
        let charge = record(["kind": "charge", "end_reason": "Complete", "energy_basis": "battery_session_counter"])
        #expect(try decode(charge).complete)
        for reason in ["unknown", "parked"] {
            var bad = charge; bad["end_reason"] = reason
            #expect(rejects(bad))
            bad["complete"] = false
            #expect(rejects(bad))
        }
        for reason in ["Stopped", "Complete", "Disconnected", "NoPower"] {
            var partial = charge
            partial.merge(["end_reason": reason, "start": NSNull(), "start_observed": false, "complete": false]) { _, new in new }
            let decoded = try decode(partial)
            #expect(!decoded.complete && decoded.start == nil && decoded.end != nil)
        }
        for reason in ["data_gap", "counter_reset", "in_progress"] {
            var bad = charge
            bad.merge(["end_reason": reason, "end": NSNull()]) { _, new in new }
            #expect(rejects(bad)) // Cannot claim completion without a kind-specific witnessed terminal.
            bad["complete"] = false
            #expect(try decode(bad).complete == false)
        }
    }

    @Test func energyMetadataMustMatchKindAndMeasurementAvailability() throws {
        for changes in [
            ["net_energy_kwh": 1],
            ["net_energy_kwh": 1, "energy_method": "observed_session_counter_delta"],
            ["net_energy_kwh": NSNull(), "energy_method": "trapezoid_power_estimate"],
            ["energy_method": NSNull()], ["energy_method": "unknown"],
            ["energy_basis": "battery_session_counter"]
        ] as [[String: Any]] { #expect(rejects(record(changes))) }
        #expect(try decode(record(["net_energy_kwh": 0, "energy_method": "trapezoid_power_estimate"])).netEnergyKWh == 0)
        var missingTripMethod = record(); missingTripMethod.removeValue(forKey: "energy_method")
        #expect(rejects(missingTripMethod))
        let charge = record(["kind": "charge", "end_reason": "Complete", "energy_basis": "battery_session_counter"])
        for changes in [
            ["energy_added_kwh": 1],
            ["energy_added_kwh": 1, "energy_method": "trapezoid_power_estimate"],
            ["energy_method": "observed_session_counter_delta"],
            ["energy_method": NSNull()], ["energy_method": "unknown"],
            ["energy_basis": NSNull()], ["energy_basis": "unknown"],
            ["energy_basis": "trapezoid_power_estimate"], ["net_energy_kwh": 1]
        ] as [[String: Any]] {
            var bad = charge; bad.merge(changes) { _, new in new }
            #expect(rejects(bad))
        }
        for missing in ["energy_basis", "energy_method"] {
            var bad = charge; bad.removeValue(forKey: missing)
            #expect(rejects(bad))
        }
        for basis in ["battery_session_counter", "ac_charger_session_counter", "dc_charger_session_counter"] {
            var measured = charge
            measured.merge(["energy_basis": basis, "energy_added_kwh": 0, "energy_method": "observed_session_counter_delta"]) { _, new in new }
            let decoded = try decode(measured)
            #expect(decoded.energyAddedKWh == 0 && decoded.energyBasis == basis)
        }
    }

    @Test func chronologyCalendarAndOwnerContextAreExplicit() throws {
        for changes in [
            ["id": "demo-id"], ["vin": "not-a-vin"], ["revision": 0], ["sample_count": -1],
            ["first_observed_at": last, "last_observed_at": first], ["end": "2026-10-19T07:59:00Z"],
            ["start": last], ["start_observed": false], ["end_reason": "data_gap"],
            ["first_observed_at": "2026-02-30T08:00:00Z"], ["start": "2026-10-19T08:00:00+08:00"],
            ["samples": [sample(last), sample(first)]], ["samples": [sample(first), sample(first)]],
            ["samples": [sample(first, ["id": "same"]), sample(last, ["id": "same"])]]
        ] as [[String: Any]] { #expect(rejects(record(changes))) }
        let valid = try decode(record())
        #expect(throws: NativeHistoryError.wrongVehicle) { try valid.validate(expectedVIN: "LRW3E7FA0NC123457", now: now) }
        #expect(throws: NativeHistoryError.outsideRetention) { try valid.validate(expectedVIN: vin, now: valid.firstObservedAt.addingTimeInterval(-1)) }
        #expect(throws: NativeHistoryError.outsideRetention) { try valid.validate(expectedVIN: vin, now: valid.firstObservedAt.addingTimeInterval(NativeHistoryRecord.retention)) }
        try valid.validate(expectedVIN: vin, now: valid.lastObservedAt)
        #expect(throws: NativeHistoryError.invalidData) {
            try NativeHistoryDecoder.decode(NativeHistoryRecord.self, from: Data("{private-secret}".utf8))
        }
        #expect(!NativeHistoryError.invalidData.localizedDescription.contains("private-secret"))
    }

    @Test func traceBreaksOnMissingCoordinatesAndLongGaps() throws {
        let points = [sample(first, ["latitude": 30, "longitude": 120]),
                      sample("2026-10-19T08:00:10Z", ["latitude": 30]), // incomplete coordinate breaks, never (0,0)
                      sample("2026-10-19T08:00:20Z", ["latitude": 30.1, "longitude": 120.1]),
                      sample("2026-10-19T08:02:21Z", ["latitude": 30.2, "longitude": 120.2])]
        let detail = try decode(record(["end": "2026-10-19T08:02:21Z", "last_observed_at": "2026-10-19T08:02:21Z", "samples": points, "sample_count": 4]))
        #expect(detail.traceSegments().map(\.count) == [1, 1, 1])
        #expect(detail.traceSegments(maximumGap: .infinity).isEmpty)
        #expect(detail.distanceKM == nil)
    }

    @Test func csvEscapesNotesAndIncludesRealProvenanceWithoutUnknownZeros() throws {
        let real = try decode(record(["tag": " \t=SUM(1,2)", "note": "@link\n\"quoted\",note"]))
        let csv = try NativeHistoryCSV.export([real], expectedVIN: vin, now: now)
        #expect(csv.contains("\"真实遥测\""))
        #expect(csv.contains("\"' \t=SUM(1,2)\""))
        #expect(csv.contains("\"'@link\n\"\"quoted\"\",note\""))
        #expect(csv.contains("\"parked\",\"\",\"\",\"\",\"insufficient_data\""))
        #expect(!csv.contains("模拟数据") && !csv.contains("\"0.0\""))
        let simulated = try decode(record(["source": "simulation"]), simulation: true)
        #expect(try NativeHistoryCSV.export([simulated], expectedVIN: vin, now: now).contains("模拟数据"))
        #expect(throws: NativeHistoryError.wrongVehicle) { try NativeHistoryCSV.export([real], expectedVIN: "LRW3E7FA0NC123457", now: now) }
        for note in ["+cmd", "-cmd", "\r\n=cmd"] {
            let value = try decode(record(["note": note]))
            #expect(try NativeHistoryCSV.export([value], expectedVIN: vin, now: now).contains("\"'" + note + "\""))
        }
    }
}
