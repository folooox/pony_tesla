import Foundation
import Testing
@testable import PonyCore

struct ReadOnlyVehicleDataTests {
    let vin = "LRW3E7FA0NC123456"
    let now = Date(timeIntervalSince1970: 1_800_000_010)
    let timestamp = "2027-01-15T08:00:00.000Z"
    func payload(_ extra: String = "", live: Bool = true, state: String = "online") -> Data {
        Data("{\"connected\":true,\"live_data\":\(live),\"vehicle\":{\"vin\":\"\(vin)\",\"state\":\"\(state)\"}\(extra)}".utf8)
    }
    func reject(_ bytes: Data, expectedVIN: String? = nil) -> ReadOnlyVehicleDataError? {
        do { _ = try ReadOnlyVehicleDataDecoder.decodeProbe(bytes, expectedVIN: expectedVIN ?? vin, receivedAt: now); Issue.record("Expected strict decoding rejection"); return nil }
        catch { return error as? ReadOnlyVehicleDataError }
    }
    @Test func partialFieldsStayUnknownAndNoControlsAreGranted() throws {
        let d = try ReadOnlyVehicleDataDecoder.decodeProbe(payload(",\"fetched_at\":\"\(timestamp)\",\"data\":{\"charge_state\":{\"battery_level\":51}}"), expectedVIN: vin, receivedAt: now)
        #expect(d.data?.charge_state?.battery_level == 51)
        #expect(d.data?.charge_state?.battery_range == nil)
        #expect(d.data?.drive_state == nil)
        #expect(d.data?.climate_state == nil)
        #expect(d.vehicle.display_name == nil)
        #expect(d.supportedQuickControls.isEmpty)
        #expect(d.sourceTimestamp(for: .charge) == nil)
        #expect(d.freshness(of: .charge, at: now) == .unknown)
    }
    @Test func offlineAndUnknownStatesNeverClaimLiveData() throws {
        for state in ["offline", "asleep", "unrecognized"] {
            let d = try ReadOnlyVehicleDataDecoder.decodeProbe(payload(live: false, state: state), expectedVIN: vin, receivedAt: now)
            #expect(d.origin == .noLiveData)
            #expect(d.data == nil && d.fetchedAt == nil)
            #expect(d.vehicle.state == state)
        }
        #expect(reject(payload(",\"fetched_at\":\"\(timestamp)\",\"data\":{\"charge_state\":{}}", state: "unknown")) == .invalidPayload)
    }
    @Test func identityMismatchAndInvalidSelectionAreRejected() {
        #expect(reject(payload(live: false), expectedVIN: "LRW3E7FA0NC123457") == .identityMismatch)
        #expect(reject(payload(live: false), expectedVIN: " invalid ") == .invalidExpectedVIN)
    }
    @Test func malformedTypesAndJSONHaveSafeErrors() {
        for raw in ["{not-json secret}", "{\"connected\":\"true\"}"] {
            #expect(reject(Data(raw.utf8)) == .invalidPayload)
        }
        #expect(reject(payload(",\"fetched_at\":\"\(timestamp)\",\"data\":{\"charge_state\":{\"battery_level\":\"51\"}}")) == .invalidPayload)
        #expect(ReadOnlyVehicleDataError.invalidPayload.localizedDescription.contains("secret") == false)
    }
    @Test func noLiveDataMustNotCarrySnapshotAndLiveRequiresDataTime() {
        #expect(reject(payload(",\"data\":{}", live: false, state: "offline")) == .invalidPayload)
        #expect(reject(payload()) == .invalidPayload)
        #expect(reject(payload(",\"fetched_at\":\"\(timestamp)\"")) == .invalidPayload)
    }
    @Test func valuesAndTimestampUnitsAreNotGuessed() {
        #expect(reject(payload(",\"fetched_at\":\"\(timestamp)\",\"data\":{\"charge_state\":{\"battery_level\":101}}")) == .outOfRange)
        #expect(reject(payload(",\"fetched_at\":\"\(timestamp)\",\"data\":{\"location_data\":{\"latitude\":91}}")) == .outOfRange)
        #expect(reject(payload(",\"fetched_at\":\"\(timestamp)\",\"data\":{\"charge_state\":{\"timestamp\":1800000000}}")) == .invalidTimestamp)
        #expect(reject(payload(",\"fetched_at\":\" \(timestamp)\",\"data\":{\"charge_state\":{}}")) == .invalidTimestamp)
    }
    @Test func milesConvertExplicitlyAndFreshnessUsesSensorNotReceipt() throws {
        let d = try ReadOnlyVehicleDataDecoder.decodeProbe(payload(",\"fetched_at\":\"\(timestamp)\",\"data\":{\"charge_state\":{\"battery_range\":100,\"timestamp\":1800000000000}}"), expectedVIN: vin, receivedAt: now)
        #expect(d.data?.charge_state?.batteryRangeKilometres == 160.9344)
        #expect(d.freshness(of: .charge, at: now) == .fresh)
        #expect(d.freshness(of: .charge, at: now.addingTimeInterval(120)) == .stale)
        #expect(d.freshness(of: .charge, at: now.addingTimeInterval(-11)) == .unknown)
    }
    @Test func cachePreservesSourceAndBackendTimestamp() throws {
        let raw = "{\"snapshot\":{\"vehicle\":{\"vin\":\"\(vin)\",\"state\":\"online\"},\"fetched_at\":\"\(timestamp)\",\"source\":\"vehicle_data\",\"cached\":true,\"stale\":true,\"data\":{\"charge_state\":{\"timestamp\":1800000000000}}}}"
        let d = try ReadOnlyVehicleDataDecoder.decodeCache(Data(raw.utf8), expectedVIN: vin, receivedAt: now.addingTimeInterval(300))
        #expect(d.origin == .cachedSnapshot)
        #expect(d.cacheStale == true)
        #expect(d.fetchedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(d.freshness(of: .charge, at: now.addingTimeInterval(300)) == .stale)
        #expect(d.supportedQuickControls.isEmpty)
    }
}
