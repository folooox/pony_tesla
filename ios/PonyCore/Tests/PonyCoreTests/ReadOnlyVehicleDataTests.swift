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

    @Test func displayNameRetainsRawJSONAndTrimsOnlyEdges() throws {
        let raw = #"{"vin":"TEST0000000000001","display_name":" \tSynthetic  Vehicle\r\n","state":"online"}"#
        let vehicle = try JSONDecoder().decode(ReadOnlyVehicleIdentity.self, from: Data(raw.utf8))
        #expect(vehicle.display_name == " \tSynthetic  Vehicle\r\n")
        #expect(vehicle.normalizedDisplayName == "Synthetic  Vehicle")
    }

    @Test func displayNamePreservesUnicodeAndEmoji() throws {
        let raw = #"{"vin":"TEST0000000000001","display_name":"\u2003测试车 🚙🌙\u00a0\n"}"#
        let vehicle = try JSONDecoder().decode(ReadOnlyVehicleIdentity.self, from: Data(raw.utf8))
        #expect(vehicle.display_name == "\u{2003}测试车 🚙🌙\u{00a0}\n")
        #expect(vehicle.normalizedDisplayName == "测试车 🚙🌙")
    }

    @Test func missingNullAndBlankDisplayNamesAllowExistingUIFallback() throws {
        for field in ["", #", "display_name":null"#, #", "display_name":"""#,
                      #", "display_name":" \t\r\n\u2003\u00a0""#] {
            let raw = #"{"vin":"TEST0000000000001"\#(field)}"#
            let vehicle = try JSONDecoder().decode(ReadOnlyVehicleIdentity.self, from: Data(raw.utf8))
            #expect(vehicle.normalizedDisplayName == nil)
        }
    }

    @Test func identityCodableRoundtripKeepsRawSnakeCaseFieldsOnly() throws {
        let raw = #"{"vin":"TEST0000000000001","display_name":"  Synthetic 🚙\n","state":"online"}"#
        let vehicle = try JSONDecoder().decode(ReadOnlyVehicleIdentity.self, from: Data(raw.utf8))
        let encoded = try JSONEncoder().encode(vehicle)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(Set(fields.keys) == Set(["vin", "display_name", "state"]))
        #expect(fields["display_name"] == vehicle.display_name)
        let roundtrip = try JSONDecoder().decode(ReadOnlyVehicleIdentity.self, from: encoded)
        #expect(roundtrip.vin == vehicle.vin)
        #expect(roundtrip.state == vehicle.state)
        #expect(roundtrip.display_name == vehicle.display_name)
        #expect(roundtrip.normalizedDisplayName == "Synthetic 🚙")
    }

    @Test func differentVINDisplayNamesRemainIndependent() throws {
        let raw = #"[{"vin":"TEST0000000000001","display_name":"  Synthetic Alpha  "},{"vin":"TEST0000000000002","display_name":"Synthetic Beta 🚙"},{"vin":"TEST0000000000003","display_name":" \n"}]"#
        let vehicles = try JSONDecoder().decode([ReadOnlyVehicleIdentity].self, from: Data(raw.utf8))
        #expect(vehicles[0].vin != vehicles[1].vin)
        #expect(vehicles[0].normalizedDisplayName == "Synthetic Alpha")
        #expect(vehicles[1].normalizedDisplayName == "Synthetic Beta 🚙")
        #expect(vehicles[2].normalizedDisplayName == nil)
        #expect(vehicles[0].display_name == "  Synthetic Alpha  ")
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
    @Test func snapshotCacheMissRequiresExactContextAndAllowlistedJSON() {
        let path = "/api/native/v1/vehicles/\(vin)/snapshot"
        let body = Data(#"{"error":"No cached vehicle data"}"#.utf8)
        func classify(_ bytes: Data = Data(#"{"error":"No cached vehicle data"}"#.utf8),
                      method: String = "GET", route: String? = nil, status: Int = 404,
                      mime: String? = "application/json") -> Bool {
            NativeSnapshotErrorClassifier.isNoCachedVehicleData(method: method, path: route ?? path,
                status: status, mimeType: mime, body: bytes)
        }
        #expect(classify(body))
        #expect(classify(Data(" \n{\"error\":\"No cached vehicle data\"}\n".utf8)))
        for method in ["POST", "get", "HEAD", "DELETE"] { #expect(!classify(method: method)) }
        for status in [200, 400, 401, 403, 429, 500] { #expect(!classify(status: status)) }
        for route in [path + "/", path + "?x=1", path + "\n", path + "#x",
                      "/api/native/v1/vehicles/\(vin)/probe", "/api/native/v1/vehicles",
                      "/api/native/v1/auth/snapshot", path.replacingOccurrences(of: vin, with: "invalid"),
                      path.replacingOccurrences(of: vin, with: "LRW3E7FA0NC12345I"),
                      path.replacingOccurrences(of: vin, with: "LRW3E7FA0NC12345O"),
                      path.replacingOccurrences(of: vin, with: "LRW3E7FA0NC12345Q"),
                      path.replacingOccurrences(of: vin, with: vin.lowercased()),
                      path.replacingOccurrences(of: vin, with: "%4C" + String(vin.dropFirst()))] {
            #expect(!classify(route: route))
        }
        for mime in [nil, "text/html", "text/plain", "application/problem+json"] {
            #expect(!classify(mime: mime))
        }
        for raw in ["", "{invalid secret}", "null", "[]", "true",
                    #"{"error":null}"#, #"{"error":404}"#,
                    #"{"message":"No cached vehicle data"}"#,
                    #"{"error":"No cached vehicle data "}"#,
                    #"{"error":"no cached vehicle data"}"#,
                    #"{"error":"<script>secret upstream message</script>"}"#,
                    #"{"error":"No cached vehicle data\nsecret"}"#] {
            #expect(!classify(Data(raw.utf8)))
        }
        var oversized = body
        oversized.append(Data(repeating: 32, count: NativeSnapshotErrorClassifier.maximumBodyBytes))
        #expect(!classify(oversized))
        #expect(!classify(Data(repeating: 123, count: NativeSnapshotErrorClassifier.maximumBodyBytes)))
    }

    @Test func onlineWithoutLiveDataDoesNotBecomeCacheOrOffline() throws {
        let d = try ReadOnlyVehicleDataDecoder.decodeProbe(payload(live: false, state: "online"),
            expectedVIN: vin, receivedAt: now)
        #expect(d.origin == .noLiveData)
        #expect(d.vehicle.state == "online")
        #expect(d.data == nil && d.cacheStale == nil)
    }

    @Test func onlyExplicitNonOnlineStatesReceiveOfflineLabel() throws {
        for state in ["offline", "asleep"] {
            let value = try ReadOnlyVehicleDataDecoder.decodeProbe(payload(live: false, state: state),
                expectedVIN: vin, receivedAt: now)
            #expect(value.hasConfirmedNonOnlineState)
        }
        for state in ["online", "unknown", "future_state", ""] {
            let value = try ReadOnlyVehicleDataDecoder.decodeProbe(payload(live: false, state: state),
                expectedVIN: vin, receivedAt: now)
            #expect(!value.hasConfirmedNonOnlineState)
        }
        for field in ["", ",\"state\":null"] {
            let bytes = Data("{\"connected\":true,\"live_data\":false,\"vehicle\":{\"vin\":\"\(vin)\"\(field)}}".utf8)
            let value = try ReadOnlyVehicleDataDecoder.decodeProbe(bytes, expectedVIN: vin, receivedAt: now)
            #expect(!value.hasConfirmedNonOnlineState)
        }
    }

}
