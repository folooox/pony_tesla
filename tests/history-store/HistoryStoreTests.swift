import Foundation
import XCTest
import PonyCore
@testable import HistoryStoreHarness

@MainActor private final class Gate {
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var started = false
    func suspend() async {
        await withCheckedContinuation { continuation in
            pending = continuation; started = true
            observer?.resume(); observer = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}

@MainActor private final class FixtureClient: NativeHistoryFetching {
    var hasLocalSession = true
    var tripsEnabled = true
    var chargesEnabled = true
    var verified = true
    var sessionCalls = 0
    var listCalls: [(String, NativeHistoryKind, String?)] = []
    var detailCalls = 0
    var page: NativeHistoryPage
    var detail: NativeHistoryRecord
    var fail = false
    var listGate: Gate?
    var detailGate: Gate?
    init(page: NativeHistoryPage, detail: NativeHistoryRecord) { self.page = page; self.detail = detail }
    func sessionInfo() async throws -> NativeTeslaSessionInfo {
        sessionCalls += 1
        if fail { throw NativeTeslaError.networkUnavailable }
        return NativeTeslaSessionInfo(account_id: "00000000-0000-4000-8000-000000000001",
            features: NativeTeslaFeatures(vehicles: true, probe: true, snapshot: true, commands: false,
                telemetry: false, charge_history: chargesEnabled, trips: tripsEnabled), native_deployment_verified: verified)
    }
    func historyList(vin: String, kind: NativeHistoryKind, before: String?) async throws -> NativeHistoryPage {
        listCalls.append((vin, kind, before))
        let captured = page
        if let listGate { await listGate.suspend() }
        if fail { throw NativeTeslaError.networkUnavailable }
        return captured
    }
    func historyDetail(vin: String, id: String) async throws -> NativeHistoryRecord {
        detailCalls += 1
        let captured = detail
        if let detailGate { await detailGate.suspend() }
        if fail { throw NativeTeslaError.networkUnavailable }
        return captured
    }
}

@MainActor final class HistoryStoreTests: XCTestCase {
    private let vin = "5YJ3E1EA7JF000001"
    private let otherVIN = "5YJ3E1EA7JF000002"
    private let instant = Date(timeIntervalSince1970: 1_790_000_000)
    private func row(id: String = "a", kind: String = "trip", revision: Int = 1, vin: String? = nil) -> [String: Any] {
        let date = ISO8601DateFormatter().string(from: instant.addingTimeInterval(-3600))
        var value: [String: Any] = ["id": String(repeating: id, count: 64), "vin": vin ?? self.vin,
            "kind": kind, "source": "telemetry", "first_observed_at": date, "last_observed_at": date,
            "start_observed": false, "complete": false, "end_reason": "in_progress", "revision": revision,
            "energy_method": "insufficient_data"]
        if kind == "charge" { value["energy_basis"] = "battery_session_counter" }
        return value
    }
    private func record(_ value: [String: Any]) throws -> NativeHistoryRecord {
        try NativeHistoryDecoder.decode(NativeHistoryRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func page(_ rows: [[String: Any]], cursor: String? = "next+/=?&") throws -> NativeHistoryPage {
        var value: [String: Any] = ["records": rows, "retention_hours": 168, "source_policy": "telemetry_only"]
        if let cursor { value["next_cursor"] = cursor }
        return try NativeHistoryDecoder.decode(NativeHistoryPage.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func client() throws -> FixtureClient { try FixtureClient(page: page([row()]), detail: record(row())) }
    private func failure(_ work: () async throws -> Void) async {
        do { try await work(); XCTFail("Expected a rejected request") } catch { }
    }

    func testManualOnlyAndCapabilityAdmission() async throws {
        let client = try client()
        let store = NativeHistoryStore(now: { self.instant })
        XCTAssertEqual(client.sessionCalls, 0)
        XCTAssertNil(store.tripAvailable)
        try await store.loadMore(kind: .trip, vin: vin, client: client)
        XCTAssertEqual(client.listCalls.count, 0)
        client.tripsEnabled = false
        try await store.refresh(kind: .trip, vin: vin, client: client)
        XCTAssertEqual(store.tripAvailable, false)
        XCTAssertFalse(store.tripLoaded)
        XCTAssertEqual(client.listCalls.count, 0)
        client.tripsEnabled = true; client.verified = false
        try await store.refresh(kind: .trip, vin: vin, client: client)
        XCTAssertEqual(client.listCalls.count, 0)
        client.verified = true
        client.page = try page([], cursor: nil)
        try await store.refresh(kind: .trip, vin: vin, client: client)
        XCTAssertTrue(store.tripLoaded)
        XCTAssertFalse(store.tripFailed)
        XCTAssertTrue(store.tripRecords.isEmpty)
        XCTAssertNil(store.tripNextCursor)
    }

    func testCapabilityWithdrawalClearsOnlyItsKind() async throws {
        let client = try client()
        let store = NativeHistoryStore(now: { self.instant })
        try await store.refresh(kind: .trip, vin: vin, client: client)
        let selected = try XCTUnwrap(store.tripRecords.first)
        try await store.loadDetail(record: selected, vin: vin, client: client)
        client.page = try page([row(id: "b", kind: "charge")])
        try await store.refresh(kind: .charge, vin: vin, client: client)
        let charge = try XCTUnwrap(store.chargeRecords.first)
        client.detail = try record(row(id: "b", kind: "charge"))
        try await store.loadDetail(record: charge, vin: vin, client: client)
        let chargeFetched = store.chargeFetchedAt
        let chargeCursor = store.chargeNextCursor
        client.tripsEnabled = false
        try await store.refresh(kind: .trip, vin: vin, client: client)
        XCTAssertEqual(store.tripAvailable, false)
        XCTAssertEqual(store.chargeAvailable, true)
        XCTAssertTrue(store.tripRecords.isEmpty)
        XCTAssertFalse(store.tripLoaded)
        XCTAssertNil(store.tripFetchedAt)
        XCTAssertNil(store.tripNextCursor)
        XCTAssertNil(store.details[selected.id])
        XCTAssertEqual(store.details[charge.id]?.kind, .charge)
        XCTAssertEqual(store.chargeRecords.count, 1)
        XCTAssertEqual(store.chargeFetchedAt, chargeFetched)
        XCTAssertEqual(store.chargeNextCursor, chargeCursor)
        XCTAssertTrue(store.chargeLoaded)
        XCTAssertEqual(client.listCalls.count, 2)
    }

    func testAllowedRefreshCompletesWhileOtherKindIsWithdrawn() async throws {
        let client = try client()
        let store = NativeHistoryStore(now: { self.instant })
        let gate = Gate(); client.listGate = gate
        let pending = Task { try await store.refresh(kind: .trip, vin: vin, client: client) }
        await gate.waitUntilStarted()
        client.listGate = nil; client.tripsEnabled = false
        client.page = try page([row(id: "b", kind: "charge")])
        try await store.refresh(kind: .charge, vin: vin, client: client)
        XCTAssertFalse(store.tripLoading)
        XCTAssertEqual(store.chargeRecords.count, 1)
        XCTAssertTrue(store.chargeLoaded)
        gate.release(); try await pending.value
        XCTAssertTrue(store.tripRecords.isEmpty)
        XCTAssertFalse(store.tripLoaded)
        XCTAssertFalse(store.tripFailed)
    }

    func testDeploymentWithdrawalClearsBothAndDeniesLateResponsesAfterReenable() async throws {
        let client = try client()
        let store = NativeHistoryStore(now: { self.instant })
        try await store.refresh(kind: .trip, vin: vin, client: client)
        let trip = try XCTUnwrap(store.tripRecords.first)
        try await store.loadDetail(record: trip, vin: vin, client: client)
        client.page = try page([row(id: "b", kind: "charge")])
        client.detail = try record(row(id: "b", kind: "charge"))
        try await store.refresh(kind: .charge, vin: vin, client: client)
        let charge = try XCTUnwrap(store.chargeRecords.first)
        try await store.loadDetail(record: charge, vin: vin, client: client)
        let detailGate = Gate(); client.detailGate = detailGate
        client.detail = try record(row(revision: 2))
        let detail = Task { try await store.loadDetail(record: trip, vin: vin, client: client) }
        await detailGate.waitUntilStarted()
        let listGate = Gate(); client.listGate = listGate
        client.page = try page([row(id: "c", kind: "charge")], cursor: "later")
        let list = Task { try await store.loadMore(kind: .charge, vin: vin, client: client) }
        await listGate.waitUntilStarted()
        client.verified = false
        try await store.refresh(kind: .trip, vin: vin, client: client)
        XCTAssertEqual(store.tripAvailable, false)
        XCTAssertEqual(store.chargeAvailable, false)
        XCTAssertTrue(store.tripRecords.isEmpty)
        XCTAssertTrue(store.chargeRecords.isEmpty)
        XCTAssertTrue(store.details.isEmpty)
        XCTAssertTrue(store.detailLoading.isEmpty)
        XCTAssertTrue(store.detailFailed.isEmpty)
        XCTAssertFalse(store.tripLoading); XCTAssertFalse(store.chargeLoading)
        XCTAssertFalse(store.tripLoaded); XCTAssertFalse(store.chargeLoaded)
        XCTAssertFalse(store.tripFailed); XCTAssertFalse(store.chargeFailed)
        XCTAssertNil(store.tripFetchedAt); XCTAssertNil(store.chargeFetchedAt)
        XCTAssertNil(store.tripNextCursor); XCTAssertNil(store.chargeNextCursor)
        XCTAssertEqual(client.listCalls.count, 3)
        // Re-enabling does not authorize responses started before withdrawal.
        client.verified = true; client.listGate = nil
        client.page = try page([row()], cursor: nil)
        try await store.refresh(kind: .trip, vin: vin, client: client)
        detailGate.release(); listGate.release()
        try await detail.value; try await list.value
        XCTAssertEqual(store.tripRecords.map(\.id), [trip.id])
        XCTAssertTrue(store.chargeRecords.isEmpty)
        XCTAssertTrue(store.details.isEmpty)
        XCTAssertFalse(store.chargeLoaded)
        XCTAssertNil(store.chargeNextCursor)
        XCTAssertFalse(store.chargeFailed)
    }

    func testCrossKindIDCollisionsRejectWholePagesInBothDirections() async throws {
        for originalKind in [NativeHistoryKind.trip, .charge] {
            let incomingKind: NativeHistoryKind = originalKind == .trip ? .charge : .trip
            let originalName = originalKind == .trip ? "trip" : "charge"
            let incomingName = incomingKind == .trip ? "trip" : "charge"
            for revision in [1, 2] {
                // Also cover an identity held only by a cached detail, not a current list row.
                for detailOnly in [false, true] {
                    let originalRow = row(kind: originalName, revision: 2)
                    let client = try FixtureClient(page: page([originalRow]), detail: record(originalRow))
                    let store = NativeHistoryStore(now: { self.instant })
                    try await store.refresh(kind: originalKind, vin: vin, client: client)
                    let selected = try XCTUnwrap((originalKind == .trip ? store.tripRecords : store.chargeRecords).first)
                    try await store.loadDetail(record: selected, vin: vin, client: client)
                    if detailOnly {
                        client.page = try page([], cursor: nil)
                        try await store.refresh(kind: originalKind, vin: vin, client: client)
                    }
                    client.page = try page([row(id: "b", kind: incomingName)], cursor: "saved")
                    try await store.refresh(kind: incomingKind, vin: vin, client: client)
                    let fetched = incomingKind == .trip ? store.tripFetchedAt : store.chargeFetchedAt
                    // A valid update precedes the collision; neither may be committed.
                    client.page = try page([row(id: "b", kind: incomingName, revision: 3),
                        row(kind: incomingName, revision: revision)], cursor: "rejected")
                    await failure { try await store.loadMore(kind: incomingKind, vin: self.vin, client: client) }
                    let incoming = incomingKind == .trip ? store.tripRecords : store.chargeRecords
                    XCTAssertEqual(incoming.map(\.id), [String(repeating: "b", count: 64)])
                    XCTAssertEqual(incoming.map(\.revision), [1])
                    XCTAssertEqual(incomingKind == .trip ? store.tripNextCursor : store.chargeNextCursor, "saved")
                    XCTAssertEqual(incomingKind == .trip ? store.tripFetchedAt : store.chargeFetchedAt, fetched)
                    XCTAssertEqual(store.details[selected.id]?.kind, originalKind)
                    XCTAssertEqual(store.details[selected.id]?.revision, 2)
                    XCTAssertEqual((originalKind == .trip ? store.tripRecords : store.chargeRecords).count, detailOnly ? 0 : 1)
                    // The replacement path must reject atomically as well.
                    await failure { try await store.refresh(kind: incomingKind, vin: self.vin, client: client) }
                    XCTAssertEqual((incomingKind == .trip ? store.tripRecords : store.chargeRecords).map(\.revision), [1])
                    XCTAssertEqual(store.details[selected.id]?.kind, originalKind)
                }
            }
        }
    }

    func testCachedDetailFirstObservedIdentityCannotChangeAtLowOrEqualRevision() async throws {
        for kind in [NativeHistoryKind.trip, .charge] {
            let name = kind == .trip ? "trip" : "charge"
            for revision in [1, 2] {
                let original = row(kind: name, revision: 2)
                let client = try FixtureClient(page: page([original]), detail: record(original))
                let store = NativeHistoryStore(now: { self.instant })
                try await store.refresh(kind: kind, vin: vin, client: client)
                let selected = try XCTUnwrap((kind == .trip ? store.tripRecords : store.chargeRecords).first)
                try await store.loadDetail(record: selected, vin: vin, client: client)
                client.page = try page([], cursor: nil)
                try await store.refresh(kind: kind, vin: vin, client: client)
                var changed = row(kind: name, revision: revision)
                changed["first_observed_at"] = ISO8601DateFormatter().string(from: instant.addingTimeInterval(-7200))
                client.page = try page([row(id: "b", kind: name), changed])
                await failure { try await store.refresh(kind: kind, vin: self.vin, client: client) }
                XCTAssertTrue((kind == .trip ? store.tripRecords : store.chargeRecords).isEmpty)
                XCTAssertEqual(store.details[selected.id]?.firstObservedAt, selected.firstObservedAt)
                XCTAssertEqual(store.details[selected.id]?.revision, 2)
                XCTAssertNil(kind == .trip ? store.tripNextCursor : store.chargeNextCursor)
            }
        }
    }

    func testFailureRetainsRecordsCursorTimeAndDetail() async throws {
        let client = try client()
        let store = NativeHistoryStore(now: { self.instant })
        try await store.refresh(kind: .trip, vin: vin, client: client)
        let fetched = store.tripFetchedAt
        let cursor = store.tripNextCursor
        let record = try XCTUnwrap(store.tripRecords.first)
        try await store.loadDetail(record: record, vin: vin, client: client)
        client.fail = true
        await failure { try await store.refresh(kind: .trip, vin: self.vin, client: client) }
        XCTAssertEqual(store.tripRecords.map(\.id), [record.id])
        XCTAssertEqual(store.tripRecords.first?.endReason, "in_progress")
        XCTAssertFalse(try XCTUnwrap(store.tripRecords.first).complete)
        XCTAssertEqual(store.tripFetchedAt, fetched)
        XCTAssertEqual(store.tripNextCursor, cursor)
        XCTAssertTrue(store.tripFailed)
        await failure { try await store.loadDetail(record: record, vin: self.vin, client: client) }
        XCTAssertEqual(store.details[record.id]?.revision, 1)
        XCTAssertTrue(store.detailFailed.contains(record.id))
        XCTAssertFalse(store.tripLoading)
        XCTAssertTrue(store.detailLoading.isEmpty)
    }

    func testInvalidationDiscardsLateListsAcrossBothKindsAndSameVIN() async throws {
        let client = try client()
        let store = NativeHistoryStore(now: { self.instant })
        let tripGate = Gate()
        client.listGate = tripGate
        let trip = Task { try await store.refresh(kind: .trip, vin: vin, client: client) }
        await tripGate.waitUntilStarted()
        let chargeGate = Gate()
        client.listGate = chargeGate; client.page = try page([row(id: "b", kind: "charge")])
        let charge = Task { try await store.refresh(kind: .charge, vin: vin, client: client) }
        await chargeGate.waitUntilStarted()
        store.invalidate()
        // A new refresh for the exact same VIN is still a new generation.
        client.listGate = nil; client.page = try page([row(id: "c")], cursor: nil)
        try await store.refresh(kind: .trip, vin: vin, client: client)
        tripGate.release(); chargeGate.release()
        try await trip.value; try await charge.value
        XCTAssertEqual(store.tripRecords.map(\.id), [String(repeating: "c", count: 64)])
        XCTAssertTrue(store.chargeRecords.isEmpty)
        XCTAssertFalse(store.chargeLoaded)
        XCTAssertEqual(store.chargeAvailable, true)
    }

    func testRejectsWrongVINKindAndDetailIdentity() async throws {
        let client = try client()
        let store = NativeHistoryStore(now: { self.instant })
        client.page = try page([row(vin: otherVIN)])
        await failure { try await store.refresh(kind: .trip, vin: self.vin, client: client) }
        XCTAssertFalse(store.tripLoaded)
        client.page = try page([row(kind: "charge")])
        await failure { try await store.refresh(kind: .trip, vin: self.vin, client: client) }
        client.page = try page([row()])
        try await store.refresh(kind: .trip, vin: vin, client: client)
        let selected = try XCTUnwrap(store.tripRecords.first)
        client.detail = try record(row(id: "b"))
        await failure { try await store.loadDetail(record: selected, vin: self.vin, client: client) }
        XCTAssertTrue(store.details.isEmpty)
        client.detail = try record(row(kind: "charge"))
        await failure { try await store.loadDetail(record: selected, vin: self.vin, client: client) }
        XCTAssertTrue(store.details.isEmpty)
    }

    func testRetentionFiltersWithoutNetworkAndOfflineRefreshCannotRestore() async throws {
        let client = try client()
        var clock = instant
        let store = NativeHistoryStore(now: { clock })
        try await store.refresh(kind: .trip, vin: vin, client: client)
        let selected = try XCTUnwrap(store.tripRecords.first)
        try await store.loadDetail(record: selected, vin: vin, client: client)
        clock = instant.addingTimeInterval(NativeHistoryRecord.retention)
        XCTAssertTrue(store.tripRecords.isEmpty)
        XCTAssertTrue(store.details.isEmpty)
        client.fail = true
        await failure { try await store.refresh(kind: .trip, vin: self.vin, client: client) }
        XCTAssertTrue(store.tripRecords.isEmpty)
        XCTAssertTrue(store.details.isEmpty)
    }

    func testManualPaginationDeduplicatesAndDoesNotRegressRevision() async throws {
        let client = try client()
        let store = NativeHistoryStore(now: { self.instant })
        try await store.refresh(kind: .trip, vin: vin, client: client)
        XCTAssertEqual(client.listCalls.count, 1)
        client.page = try page([row(revision: 2), row(id: "b")], cursor: "second")
        try await store.loadMore(kind: .trip, vin: vin, client: client)
        XCTAssertEqual(client.listCalls.last?.2, "next+/=?&")
        XCTAssertEqual(store.tripRecords.map(\.revision), [2, 1])
        client.page = try page([row(revision: 1), row(id: "b")], cursor: nil)
        try await store.loadMore(kind: .trip, vin: vin, client: client)
        XCTAssertEqual(store.tripRecords.count, 2)
        XCTAssertEqual(store.tripRecords.first?.revision, 2)
        XCTAssertNil(store.tripNextCursor)
        try await store.loadMore(kind: .trip, vin: vin, client: client)
        XCTAssertEqual(client.listCalls.count, 3)
    }

    func testLostSessionClearsBothKindsAndLateDetail() async throws {
        let client = try client()
        let store = NativeHistoryStore(now: { self.instant })
        try await store.refresh(kind: .trip, vin: vin, client: client)
        let selected = try XCTUnwrap(store.tripRecords.first)
        let gate = Gate(); client.detailGate = gate
        let pending = Task { try await store.loadDetail(record: selected, vin: vin, client: client) }
        await gate.waitUntilStarted()
        client.page = try page([row(id: "b", kind: "charge")])
        try await store.refresh(kind: .charge, vin: vin, client: client)
        client.hasLocalSession = false
        gate.release()
        await failure { try await pending.value }
        XCTAssertTrue(store.tripRecords.isEmpty)
        XCTAssertTrue(store.chargeRecords.isEmpty)
        XCTAssertTrue(store.details.isEmpty)
        XCTAssertNil(store.tripAvailable)
        XCTAssertNil(store.chargeAvailable)
    }
}
