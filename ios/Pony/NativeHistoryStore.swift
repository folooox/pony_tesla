import Foundation
import Observation
import PonyCore

@MainActor
protocol NativeHistoryFetching: AnyObject {
    var hasLocalSession: Bool { get }
    func sessionInfo() async throws -> NativeTeslaSessionInfo
    func historyList(vin: String, kind: NativeHistoryKind, before: String?) async throws -> NativeHistoryPage
    func historyDetail(vin: String, id: String) async throws -> NativeHistoryRecord
}

/// Memory-only, owner/selection-bound history. No constructor, timer or observer performs HTTP.
@MainActor @Observable
final class NativeHistoryStore {
    private var trips: [NativeHistoryRecord] = []
    private var charges: [NativeHistoryRecord] = []
    private var cachedDetails: [String: NativeHistoryRecord] = [:]
    // Filter at read time as well as request boundaries: an expired row cannot reappear
    // after an offline refresh, or remain visible when navigating back much later.
    var tripRecords: [NativeHistoryRecord] { retained(trips) }
    var chargeRecords: [NativeHistoryRecord] { retained(charges) }
    var details: [String: NativeHistoryRecord] { cachedDetails.filter { valid($0.value) } }
    private(set) var tripLoading = false
    private(set) var chargeLoading = false
    private(set) var tripLoaded = false
    private(set) var chargeLoaded = false
    private(set) var tripFailed = false
    private(set) var chargeFailed = false
    private(set) var tripFetchedAt: Date?
    private(set) var chargeFetchedAt: Date?
    private(set) var tripNextCursor: String?
    private(set) var chargeNextCursor: String?
    private(set) var tripAvailable: Bool?
    private(set) var chargeAvailable: Bool?
    private(set) var detailLoading: Set<String> = []
    private(set) var detailFailed: Set<String> = []
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var tripGeneration = UUID()
    @ObservationIgnored private var chargeGeneration = UUID()
    @ObservationIgnored private var detailRequestKinds: [String: NativeHistoryKind] = [:]
    @ObservationIgnored private var boundVIN: String?
    @ObservationIgnored private var boundClient: ObjectIdentifier?

    init(now: @escaping () -> Date = { Date() }) { self.now = now }

    func invalidate() {
        generation = UUID()
        boundVIN = nil; boundClient = nil
        trips = []; charges = []; cachedDetails = [:]
        tripLoading = false; chargeLoading = false
        tripLoaded = false; chargeLoaded = false
        tripFailed = false; chargeFailed = false
        tripFetchedAt = nil; chargeFetchedAt = nil
        tripNextCursor = nil; chargeNextCursor = nil
        tripAvailable = nil; chargeAvailable = nil
        detailLoading = []; detailFailed = []; detailRequestKinds = [:]
    }

    /// The only capability check, called solely by an explicit refresh button.
    func refresh(kind: NativeHistoryKind, vin: String, client: any NativeHistoryFetching) async throws {
        bind(vin, client)
        guard !loading(kind), client.hasLocalSession else { return }
        prune()
        let attempt = generation
        let kindAttempt = kindGeneration(kind)
        setLoading(kind, true); setFailed(kind, false)
        defer { if attempt == generation && kindAttempt == kindGeneration(kind) { setLoading(kind, false) } }
        do {
            let info = try await client.sessionInfo()
            guard attempt == generation && kindAttempt == kindGeneration(kind) else { return }
            guard client.hasLocalSession else { invalidate(); throw NativeTeslaError.signInRequired }
            // sessionInfo is a complete snapshot, not a capability response for just this kind.
            tripAvailable = info.native_deployment_verified && info.features.trips
            chargeAvailable = info.native_deployment_verified && info.features.charge_history
            if tripAvailable == false { clearUnavailable(.trip) }
            if chargeAvailable == false { clearUnavailable(.charge) }
            guard (kind == .trip ? tripAvailable : chargeAvailable) == true else { return }
            let page = try await client.historyList(vin: vin, kind: kind, before: nil)
            guard attempt == generation && kindAttempt == kindGeneration(kind) else { return }
            guard client.hasLocalSession else { invalidate(); throw NativeTeslaError.signInRequired }
            try accept(page, kind: kind, vin: vin, append: false)
        } catch {
            guard attempt == generation && kindAttempt == kindGeneration(kind) else { throw error }
            if !client.hasLocalSession { invalidate() }
            else { prune(); setFailed(kind, true) }
            throw error
        }
    }

    /// Pagination never discovers capabilities and never runs automatically.
    func loadMore(kind: NativeHistoryKind, vin: String, client: any NativeHistoryFetching) async throws {
        guard matches(vin, client), client.hasLocalSession, !loading(kind),
              (kind == .trip ? tripAvailable : chargeAvailable) == true,
              let cursor = kind == .trip ? tripNextCursor : chargeNextCursor else { return }
        prune()
        let attempt = generation
        let kindAttempt = kindGeneration(kind)
        setLoading(kind, true); setFailed(kind, false)
        defer { if attempt == generation && kindAttempt == kindGeneration(kind) { setLoading(kind, false) } }
        do {
            let page = try await client.historyList(vin: vin, kind: kind, before: cursor)
            guard attempt == generation && kindAttempt == kindGeneration(kind) else { return }
            guard client.hasLocalSession else { invalidate(); throw NativeTeslaError.signInRequired }
            guard page.nextCursor != cursor else { throw NativeTeslaError.invalidResponse }
            try accept(page, kind: kind, vin: vin, append: true)
        } catch {
            guard attempt == generation && kindAttempt == kindGeneration(kind) else { throw error }
            if !client.hasLocalSession { invalidate() }
            else { prune(); setFailed(kind, true) }
            throw error
        }
    }

    /// Invoke on explicit detail navigation/retry, never on a list row mounting.
    func loadDetail(record: NativeHistoryRecord, vin: String, client: any NativeHistoryFetching) async throws {
        guard matches(vin, client), client.hasLocalSession, record.vin == vin,
              (record.kind == .trip ? tripAvailable : chargeAvailable) == true,
              !detailLoading.contains(record.id) else { return }
        prune()
        try record.validate(expectedVIN: vin, now: now())
        guard record.source == .telemetry,
              (record.kind == .trip ? trips : charges).contains(where: { $0.id == record.id }) else { return }
        let kind = record.kind
        let attempt = generation
        let kindAttempt = kindGeneration(kind)
        detailLoading.insert(record.id); detailFailed.remove(record.id)
        detailRequestKinds[record.id] = kind
        defer {
            if attempt == generation && kindAttempt == kindGeneration(kind) {
                detailLoading.remove(record.id)
                if !detailFailed.contains(record.id) { detailRequestKinds.removeValue(forKey: record.id) }
            }
        }
        do {
            let detail = try await client.historyDetail(vin: vin, id: record.id)
            guard attempt == generation && kindAttempt == kindGeneration(kind) else { return }
            guard client.hasLocalSession else { invalidate(); throw NativeTeslaError.signInRequired }
            guard (record.kind == .trip ? tripAvailable : chargeAvailable) == true,
                  (record.kind == .trip ? trips : charges).contains(where: { $0.id == record.id }) else { return }
            try detail.validate(expectedVIN: vin, now: now())
            guard detail.id == record.id, detail.source == .telemetry,
                  detail.kind == record.kind, detail.firstObservedAt == record.firstObservedAt,
                  detail.revision >= record.revision else { throw NativeTeslaError.invalidResponse }
            if let previous = cachedDetails[detail.id], detail.revision <= previous.revision { return }
            cachedDetails[detail.id] = detail
            prune()
        } catch {
            guard attempt == generation && kindAttempt == kindGeneration(kind) else { throw error }
            if !client.hasLocalSession { invalidate() }
            else { prune(); detailFailed.insert(record.id) }
            throw error
        }
    }

    private func accept(_ page: NativeHistoryPage, kind: NativeHistoryKind, vin: String, append: Bool) throws {
        let now = now()
        try page.validate(expectedVIN: vin, now: now)
        guard page.records.count <= 30, page.sourcePolicy == "telemetry_only", page.records.allSatisfy({ $0.kind == kind && $0.source == .telemetry }) else {
            throw NativeTeslaError.invalidResponse
        }
        // Validate the entire page against every retained identity before merging, including
        // cached details whose list row may have disappeared on a previous refresh.
        for row in page.records {
            var previousRecords = (trips + charges).filter { $0.id == row.id }
            if let detail = cachedDetails[row.id] { previousRecords.append(detail) }
            for previous in previousRecords {
                guard previous.vin == row.vin, previous.kind == row.kind,
                      previous.firstObservedAt == row.firstObservedAt else { throw NativeTeslaError.invalidResponse }
            }
        }
        let old = kind == .trip ? trips : charges
        var merged = append ? old : []
        var updatedDetails = cachedDetails
        for row in page.records {
            // Stable IDs cannot migrate vehicle, kind or first-observed identity.
            if let previous = old.first(where: { $0.id == row.id }) {
                guard previous.vin == row.vin, previous.kind == row.kind,
                      previous.firstObservedAt == row.firstObservedAt else { throw NativeTeslaError.invalidResponse }
                // Never regress a revision or overwrite same-revision content from an overlapping page.
                if row.revision <= previous.revision {
                    if !append { merged.append(previous) }
                    continue
                }
            }
            if let index = merged.firstIndex(where: { $0.id == row.id }) { merged[index] = row }
            else { merged.append(row) }
            if let detail = updatedDetails[row.id], detail.revision < row.revision { updatedDetails.removeValue(forKey: row.id) }
        }
        cachedDetails = updatedDetails
        if kind == .trip {
            trips = merged; tripLoaded = true; tripFetchedAt = now; tripNextCursor = page.nextCursor
        } else {
            charges = merged; chargeLoaded = true; chargeFetchedAt = now; chargeNextCursor = page.nextCursor
        }
        prune()
    }

    private func clearUnavailable(_ kind: NativeHistoryKind) {
        let ids = Set((kind == .trip ? trips : charges).map(\.id))
            .union(cachedDetails.values.filter { $0.kind == kind }.map(\.id))
            .union(detailRequestKinds.filter { $0.value == kind }.map(\.key))
        detailRequestKinds = detailRequestKinds.filter { $0.value != kind }
        cachedDetails = cachedDetails.filter { $0.value.kind != kind }
        detailFailed.subtract(ids)
        detailLoading.subtract(ids)
        // Only the withdrawn kind advances: an allowed refresh applying this snapshot
        // must remain current, while its withdrawn sibling's late responses cannot revive data.
        if kind == .trip {
            tripGeneration = UUID(); tripLoading = false
            trips = []; tripLoaded = false; tripFailed = false
            tripFetchedAt = nil; tripNextCursor = nil
        } else {
            chargeGeneration = UUID(); chargeLoading = false
            charges = []; chargeLoaded = false; chargeFailed = false
            chargeFetchedAt = nil; chargeNextCursor = nil
        }
    }

    private func matches(_ vin: String, _ client: any NativeHistoryFetching) -> Bool {
        boundVIN == vin && boundClient == ObjectIdentifier(client)
    }
    private func bind(_ vin: String, _ client: any NativeHistoryFetching) {
        if !matches(vin, client) { invalidate(); boundVIN = vin; boundClient = ObjectIdentifier(client) }
    }
    private func valid(_ record: NativeHistoryRecord) -> Bool {
        guard let vin = boundVIN, record.source == .telemetry else { return false }
        return (try? record.validate(expectedVIN: vin, now: now())) != nil
    }
    private func retained(_ records: [NativeHistoryRecord]) -> [NativeHistoryRecord] { records.filter { valid($0) } }
    private func prune() {
        trips = retained(trips); charges = retained(charges)
        cachedDetails = cachedDetails.filter { valid($0.value) }
    }
    private func kindGeneration(_ kind: NativeHistoryKind) -> UUID { kind == .trip ? tripGeneration : chargeGeneration }
    private func loading(_ kind: NativeHistoryKind) -> Bool { kind == .trip ? tripLoading : chargeLoading }
    private func setLoading(_ kind: NativeHistoryKind, _ value: Bool) {
        if kind == .trip { tripLoading = value } else { chargeLoading = value }
    }
    private func setFailed(_ kind: NativeHistoryKind, _ value: Bool) {
        if kind == .trip { tripFailed = value } else { chargeFailed = value }
    }
}

