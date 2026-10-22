import Foundation
import XCTest
import PonyCore
@testable import HistoryStoreHarness

#if DEBUG
/// Opt-in integration evidence: consumes exact backend exports, never builds fixture DTOs.
@MainActor final class ExportedPipelineTests: XCTestCase {
    private func bundle() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["NATIVE_HISTORY_PIPELINE_BUNDLE"], !path.isEmpty else {
            throw XCTSkip("Set NATIVE_HISTORY_PIPELINE_BUNDLE to the exact exported bundle directory")
        }
        return path
    }
    func testExactExportThroughRealStoreAndReplay() async throws {
        let client = try NativeHistoryPipelineClient(directory: bundle())
        let store = NativeHistoryStore(now: { client.clock })
        XCTAssertEqual(client.listCalls, 0)
        XCTAssertEqual(client.detailCalls, 0)
        try await store.refresh(kind: client.kind, vin: client.vin, client: client)
        let rows = client.kind == .trip ? store.tripRecords : store.chargeRecords
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.map(\.id), client.page.records.map(\.id))
        XCTAssertEqual(client.listCalls, 1)
        var details: [NativeHistoryRecord] = []
        for row in rows {
            try await store.loadDetail(record: row, vin: client.vin, client: client)
            let detail = try XCTUnwrap(store.details[row.id])
            XCTAssertEqual(detail.id, row.id)
            XCTAssertEqual(detail.vin, client.vin)
            XCTAssertEqual(detail.source, .telemetry)
            XCTAssertEqual(detail.firstObservedAt, row.firstObservedAt)
            XCTAssertGreaterThanOrEqual(detail.revision, row.revision)
            XCTAssertNotNil(detail.samples, "Exporter must supply actual detail DTO, not summary")
            details.append(detail)
        }
        // Exact backend scenarios required for screenshot evidence.
        let open = try XCTUnwrap(details.first { $0.kind == .trip && $0.endReason == "in_progress" && !$0.startObserved })
        XCTAssertNil(open.start); XCTAssertNil(open.end)
        XCTAssertFalse(open.complete)
        XCTAssertNil(open.distanceKM); XCTAssertNil(open.netEnergyKWh)
        XCTAssertTrue(open.traceSegments().isEmpty, "Never fabricate a route")
        let ended = try XCTUnwrap(details.first { $0.kind == .trip && $0.endReason == "parked" && !$0.complete })
        XCTAssertNotNil(ended.end)
        XCTAssertFalse(ended.startObserved)
        let revisions = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0.revision) })
        // Replay the exact same bytes through refresh + detail, not a reconstructed response.
        try await store.refresh(kind: client.kind, vin: client.vin, client: client)
        let replay = client.kind == .trip ? store.tripRecords : store.chargeRecords
        XCTAssertEqual(replay.map(\.id), rows.map(\.id))
        XCTAssertEqual(Set(replay.map(\.id)).count, rows.count)
        for row in replay { try await store.loadDetail(record: row, vin: client.vin, client: client) }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: store.details.values.map { ($0.id, $0.revision) }), revisions)
        XCTAssertEqual(client.listCalls, 2)
        XCTAssertEqual(client.detailCalls, rows.count * 2)
        print("PIPELINE EXACT list SHA256=\(client.listSHA256) manifest SHA256=\(client.manifestSHA256) records=\(rows.count)")
    }

    func testTamperedBytesAndUnsafeManifestFailClosed() throws {
        let source = try bundle()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let list = root.appendingPathComponent("list.json")
        let original = try Data(contentsOf: list)
        var changed = original; changed.append(0x20) // Still valid JSON: hash, not decoder, must reject.
        try changed.write(to: list)
        XCTAssertThrowsError(try NativeHistoryPipelineClient(directory: root.path))
        try original.write(to: list)
        _ = try NativeHistoryPipelineClient(directory: root.path)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let originalManifest = try Data(contentsOf: manifestURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: originalManifest) as? [String: Any])
        var files = try XCTUnwrap(object["files"] as? [String: String])
        files["../escape.json"] = String(repeating: "a", count: 64)
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        XCTAssertThrowsError(try NativeHistoryPipelineClient(directory: root.path))
        try originalManifest.write(to: manifestURL)
        let removed = try XCTUnwrap(files.keys.first { $0.hasPrefix("details/") })
        try FileManager.default.removeItem(at: root.appendingPathComponent(removed))
        XCTAssertThrowsError(try NativeHistoryPipelineClient(directory: root.path))
    }
}
#endif
