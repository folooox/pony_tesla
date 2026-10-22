import SwiftUI
import MapKit
import Charts
import PonyCore

// History-only supporting text: opaque colors, independent of inherited secondary styles.
private var historySecondaryColor: Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 152.0 / 255, green: 152.0 / 255, blue: 159.0 / 255, alpha: 1)
            : UIColor(red: 99.0 / 255, green: 99.0 / 255, blue: 102.0 / 255, alpha: 1)
    })
}

/// History is read only in response to an explicit refresh/detail action.
struct NativeTripsHistoryView: View {
    @Environment(NativeAccountState.self) private var account
    @State private var day: Date?
    private var days: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Calendar.current.startOfDay(for: Date())) }
    }
    var body: some View {
        List {
            NativeHistoryRows(kind: .trip, day: day)
        }
        .navigationTitle("行程")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("最近 7 天") { day = nil }
                    ForEach(days, id: \.self) { date in
                        Button(date.formatted(date: .abbreviated, time: .omitted)) { day = date }
                    }
                } label: { Label(day?.formatted(date: .abbreviated, time: .omitted) ?? "最近 7 天", systemImage: "calendar") }
                .accessibilityLabel("日期筛选")
            }
        }
        .refreshable { await account.refreshHistory(.trip) }
        .onChange(of: account.selectedVIN) { _, _ in day = nil }
    }
}

/// Embed directly in the existing charging List, outside its current-reading gate.
struct NativeChargeHistorySection: View {
    var body: some View { NativeHistoryRows(kind: .charge, day: nil) }
}

private struct NativeHistoryRows: View {
    let kind: NativeHistoryKind
    let day: Date?
    @Environment(NativeAccountState.self) private var account
    private var records: [NativeHistoryRecord] { kind == .trip ? account.history.tripRecords : account.history.chargeRecords }
    private var visible: [NativeHistoryRecord] {
        let owned = records.filter { $0.vin == account.selectedVIN }
        guard let day else { return owned }
        // This is the date of known data, not an invented departure time.
        return owned.filter { Calendar.current.isDate($0.start ?? $0.firstObservedAt, inSameDayAs: day) }
    }
    private var loading: Bool { kind == .trip ? account.history.tripLoading : account.history.chargeLoading }
    private var loaded: Bool { kind == .trip ? account.history.tripLoaded : account.history.chargeLoaded }
    private var failed: Bool { kind == .trip ? account.history.tripFailed : account.history.chargeFailed }
    private var available: Bool? { kind == .trip ? account.history.tripAvailable : account.history.chargeAvailable }
    private var fetchedAt: Date? { kind == .trip ? account.history.tripFetchedAt : account.history.chargeFetchedAt }
    private var nextCursor: String? { kind == .trip ? account.history.tripNextCursor : account.history.chargeNextCursor }
    private var title: String { kind == .trip ? "行程记录" : "最近充电" }
    var body: some View {
        Section {
            if account.storageUnavailable {
                Text("无法读取安全会话存储，请前往账号页面重试。")
                NavigationLink("前往账号") { AccountView() }
            } else if !account.hasLocalSession {
                ContentUnavailableView("连接后查看记录", systemImage: "key", description: Text("连接 Tesla 账号，查看当前车辆可用的记录。").foregroundColor(historySecondaryColor))
                NavigationLink("连接 Tesla 账号") { AccountView() }
            } else if account.selectedVIN == nil {
                ContentUnavailableView("选择车辆后查看记录", systemImage: "car")
                NavigationLink("选择车辆") { AccountView() }
            } else {
                historyContent
            }
        } header: { Text(title) } footer: {
            Text("手动读取服务中的最近 7 天记录，不唤醒车辆。日期按开始时间筛选；开始未知时按首次获取数据的日期筛选。未提供全量汇总。").foregroundStyle(historySecondaryColor)
        }
    }
    @ViewBuilder private var historyContent: some View {
        if failed {
            NativeHistoryReadNotice(hasRecords: !records.isEmpty, fetchedAt: fetchedAt)
        }
        if available == false && records.isEmpty {
            NativeHistoryEmptyState(state: .unavailable)
        } else if loading && records.isEmpty {
            ProgressView("正在读取记录…")
        } else if visible.isEmpty && loaded && !failed {
            NativeHistoryEmptyState(state: day == nil ? (kind == .trip ? .tripEmpty : .chargeEmpty) : .filteredEmpty)
        } else if !loaded && !failed && !loading {
            Text("点击“刷新记录”读取当前车辆可用的历史。").foregroundStyle(historySecondaryColor)
        }
        ForEach(visible) { record in
            NativeHistoryEntry(record: record)
        }
        Button { Task { await account.refreshHistory(kind) } } label: {
            Label("刷新记录", systemImage: "arrow.clockwise").frame(minHeight: 44)
        }.disabled(loading || account.busy)
        if loading && !records.isEmpty { ProgressView("正在读取记录…") }
        if nextCursor != nil {
            Button { Task { await account.loadMoreHistory(kind) } } label: { Text("加载更多记录").frame(minHeight: 44) }
                .disabled(loading || account.busy)
        }
    }
}

private struct NativeHistoryEntry: View {
    let record: NativeHistoryRecord
    @Environment(NativeAccountState.self) private var account
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if record.kind == .trip {
                NavigationLink {
                    NativeTripHistoryDetailView(recordID: record.id, vin: record.vin, firstObservedAt: record.firstObservedAt)
                } label: { NativeHistorySummary(record: record) }
                .accessibilityHint("查看记录详情")
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    NativeHistoryDetailContent(record: historyMatchingDetail(account.history.details[record.id], record: record) ?? record)
                    NativeHistoryDetailReadButton(record: record)
                } label: { NativeHistorySummary(record: record) }
                .accessibilityHint("展开充电记录说明")
            }
        }.padding(.vertical, 8)
    }
}

private struct NativeHistorySummary: View {
    let record: NativeHistoryRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if record.kind == .trip { NativeHistoryMap(record: record, height: 150) }
            Text(record.kind == .trip ? "行程记录" : "充电记录").font(.headline)
            NativeHistoryBadges(record: record)
            Text(record.start.map(historyDate) ?? "开始时间未获取").font(.subheadline).foregroundStyle(historySecondaryColor)
            Text(historyConfirmedEnd(record).map { "结束时间 \(historyDate($0))" } ?? "结束时间尚未确认")
                .font(.subheadline).foregroundStyle(historySecondaryColor)
            if record.kind == .trip {
                historyValue("已记录里程", value: record.distanceKM, unit: "km")
                historyValue("已记录估算净耗电", value: record.netEnergyKWh, unit: "kWh")
            } else {
                historyValue("已记录充电量", value: record.energyAddedKWh, unit: "kWh")
            }
            Text("最后获取数据 \(historyDate(record.lastObservedAt))").font(.footnote).foregroundStyle(historySecondaryColor)
            if let tag = record.tag, !tag.isEmpty { Label(tag, systemImage: "tag").font(.caption) }
        }
    }
}

// Open-ended records alone are not evidence of a quality defect or active collection.
private func historyReasons(_ record: NativeHistoryRecord) -> [String] {
    var reasons: [String] = []
    if !record.startObserved { reasons.append("缺少开始时的数据：未获取完整的开始数据，部分时间或数值无法确定。") }
    if record.endReason == "data_gap" { reasons.append("记录中途出现数据中断：中断期间的数据缺失，部分统计无法完整计算。") }
    if record.endReason == "counter_reset" { reasons.append("充电计数已重置：无法据此计算完整充电量。") }
    if reasons.isEmpty && !record.complete && historyConfirmedEnd(record) != nil {
        reasons.append("部分记录数据缺失：当前记录未包含完整数据，部分统计无法计算。")
    }
    return reasons
}
private func historyConfirmedEnd(_ record: NativeHistoryRecord) -> Date? {
    let witnessed = record.kind == .trip ? ["parked"] : ["Stopped", "Complete", "Disconnected", "NoPower"]
    return witnessed.contains(record.endReason) ? record.end : nil
}
private func historyDate(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

private struct NativeHistoryBadges: View {
    let record: NativeHistoryRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if historyConfirmedEnd(record) == nil { badge("状态待确认", symbol: "questionmark.circle", color: historySecondaryColor) }
            if !historyReasons(record).isEmpty { badge("记录不完整", symbol: "exclamationmark.triangle", color: .orange) }
        }.accessibilityElement(children: .combine)
    }
    private func badge(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(.primary)
        }.font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
    }
}

private func historyMatchingDetail(_ detail: NativeHistoryRecord?, record: NativeHistoryRecord) -> NativeHistoryRecord? {
    guard let detail, detail.id == record.id, detail.vin == record.vin,
          detail.kind == record.kind, detail.source == record.source,
          detail.firstObservedAt == record.firstObservedAt, detail.revision >= record.revision else { return nil }
    return detail
}

private struct NativeTripHistoryDetailView: View {
    let recordID: String
    let vin: String
    let firstObservedAt: Date
    @Environment(NativeAccountState.self) private var account
    private var record: NativeHistoryRecord? {
        guard account.hasLocalSession, !account.storageUnavailable, account.selectedVIN == vin else { return nil }
        let summary = account.history.tripRecords.first {
            $0.id == recordID && $0.vin == vin && $0.kind == .trip && $0.firstObservedAt == firstObservedAt
        }
        if let summary { return historyMatchingDetail(account.history.details[recordID], record: summary) ?? summary }
        guard let detail = account.history.details[recordID], detail.id == recordID,
              detail.vin == vin, detail.kind == .trip, detail.source == .telemetry,
              detail.firstObservedAt == firstObservedAt else { return nil }
        return detail
    }
    var body: some View {
        List {
            if let record {
                Section { NativeHistoryDetailContent(record: record) }
                Section { NativeHistoryDetailReadButton(record: record) }
            } else {
                ContentUnavailableView("记录当前不可查看", systemImage: "clock", description: Text("请返回列表，确认账号与所选车辆。").foregroundColor(historySecondaryColor))
            }
        }.navigationTitle("行程详情").navigationBarTitleDisplayMode(.inline)
    }
}

private struct NativeHistoryDetailReadButton: View {
    let record: NativeHistoryRecord
    @Environment(NativeAccountState.self) private var account
    private var loading: Bool { account.history.detailLoading.contains(record.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if account.history.detailFailed.contains(record.id) {
                Label("未能读取记录详情", systemImage: "clock.badge.exclamationmark").font(.headline)
                Text("保留已获取的数据，请稍后重试。历史列表状态未改变。 ").font(.subheadline).foregroundStyle(historySecondaryColor)
            }
            if loading { ProgressView("正在读取记录详情…") }
            Button { Task { await account.loadHistoryDetail(record) } } label: {
                Text(account.history.detailFailed.contains(record.id) ? "重新读取" : "读取记录详情").frame(minHeight: 44)
            }.disabled(loading || account.busy || account.selectedVIN != record.vin || !account.hasLocalSession || account.storageUnavailable)
        }
    }
}

private struct NativeHistoryDetailContent: View {
    let record: NativeHistoryRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeHistoryBadges(record: record)
            if historyConfirmedEnd(record) == nil {
                Label("记录状态尚未确认", systemImage: "questionmark.circle").font(.headline)
                Text(record.kind == .trip ? "尚未确认这次行程是否结束，以下为已获取的数据。" : "尚未确认这次充电是否结束，以下为已获取的数据。")
            }
            ForEach(historyReasons(record), id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle").font(.subheadline)
            }
            LabeledContent("数据来源") { Text(record.source.label).foregroundStyle(historySecondaryColor) }
            LabeledContent("开始时间") { Text(record.start.map(historyDate) ?? "未获取").foregroundStyle(historySecondaryColor) }
            LabeledContent("结束时间") { Text(historyConfirmedEnd(record).map(historyDate) ?? "尚未确认").foregroundStyle(historySecondaryColor) }
            LabeledContent("首次获取数据") { Text(historyDate(record.firstObservedAt)).foregroundStyle(historySecondaryColor) }
            LabeledContent("最后获取数据") { Text(historyDate(record.lastObservedAt)).foregroundStyle(historySecondaryColor) }
            if let start = record.start, let end = historyConfirmedEnd(record), record.complete {
                LabeledContent("时长") { Text("\(Int(end.timeIntervalSince(start) / 60)) 分钟").foregroundStyle(Color.primary) }
            } else {
                LabeledContent("完整时长") { Text("—").foregroundStyle(historySecondaryColor) }.accessibilityLabel("完整时长，无法计算")
                Text("缺少完整的开始或结束数据，无法计算完整时长。 ").font(.footnote).foregroundStyle(historySecondaryColor)
            }
            if record.kind == .trip {
                historyValue("已记录里程", value: record.distanceKM, unit: "km")
                historyValue("已记录估算净耗电", value: record.netEnergyKWh, unit: "kWh")
                NativeHistoryMap(record: record, height: 220)
                NativeHistorySampleChart(record: record)
            } else {
                historyValue("已记录充电量", value: record.energyAddedKWh, unit: "kWh")
                LabeledContent("充电类型") {
                    Text(record.chargerType == "ac" ? "交流" : record.chargerType == "dc" ? "直流" : "未获取")
                        .foregroundStyle(record.chargerType == "ac" || record.chargerType == "dc" ? Color.primary : historySecondaryColor)
                }
                // Session samples do not establish start/end battery values unless those boundaries were witnessed.
                historyValue("开始电量", value: record.samples?.first?.at == record.start ? record.samples?.first?.batteryPercent : nil, unit: "%")
                historyValue("结束电量", value: record.samples?.last?.at == historyConfirmedEnd(record) ? record.samples?.last?.batteryPercent : nil, unit: "%")
                LabeledContent("费用") { Text("—").foregroundStyle(historySecondaryColor) }.accessibilityLabel("费用，未获取")
                Text("费用未获取，不代表免费。 ").font(.footnote).foregroundStyle(historySecondaryColor)
            }
            if let tag = record.tag, !tag.isEmpty { Label(tag, systemImage: "tag") }
            if let note = record.note, !note.isEmpty { Text(note) }
        }.padding(.vertical, 8)
    }
}

private func historyValue(_ label: String, value: Double?, unit: String) -> some View {
    let text = value.map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) \(unit)" } ?? "—"
    return LabeledContent {
        // Set the value itself: a parent style does not override LabeledContent's secondary value style.
        Text(text).foregroundStyle(value == nil ? historySecondaryColor : Color.primary)
    } label: {
        Text(label).foregroundStyle(Color.primary)
    }.accessibilityLabel("\(label)，\(value == nil ? "未获取" : text)")
}

private struct NativeHistoryMap: View {
    let record: NativeHistoryRecord
    let height: CGFloat
    private var segments: [[NativeHistorySample]] { record.traceSegments() }
    var body: some View {
        VStack(alignment: .leading) {
            if segments.isEmpty {
                Label(record.samples == nil ? "路线详情尚未读取" : "未获取路线", systemImage: "map").font(.subheadline).foregroundStyle(historySecondaryColor)
            } else {
                Map(interactionModes: []) {
                    ForEach(segments, id: \.first?.at) { segment in
                        MapPolyline(coordinates: segment.compactMap { sample in
                            sample.coordinate.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                        }).stroke(.blue, lineWidth: 3)
                    }
                }.frame(height: height).clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("已获取的路线片段，缺口不连线，不标记终点")
            }
        }
    }
}

private struct NativeHistorySampleChart: View {
    let record: NativeHistoryRecord
    private var points: [NativeHistorySample] { (record.samples ?? []).filter { $0.speedKPH != nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已获取速度样本").font(.headline)
            if points.count < 2 { Text("数据不足").foregroundStyle(historySecondaryColor) }
            else {
                // Point marks only: no interpolation, gap bridging or extending to the present.
                Chart(points, id: \.at) { point in
                    if let value = point.speedKPH {
                        PointMark(x: .value("时间", point.at), y: .value("速度 km/h", value))
                    }
                }.frame(height: 190).accessibilityLabel("真实速度样本，单位千米每小时，不插值")
            }
        }
    }
}

private struct NativeHistoryReadNotice: View {
    let hasRecords: Bool
    let fetchedAt: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(hasRecords ? "记录未更新" : "未能读取记录", systemImage: "clock.badge.exclamationmark").font(.headline)
            Text(hasRecords ? "以下为上次获取的记录。" : "请稍后刷新。")
            if let fetchedAt { Text("上次获取于 \(historyDate(fetchedAt))").font(.footnote).foregroundStyle(historySecondaryColor) }
        }.padding(.vertical, 8)
    }
}

private struct NativeHistoryEmptyState: View {
    enum State { case tripEmpty, chargeEmpty, filteredEmpty, unavailable }
    let state: State
    private var title: String {
        switch state {
        case .tripEmpty: "暂无行程记录"
        case .chargeEmpty: "暂无充电记录"
        case .filteredEmpty: "没有符合条件的记录"
        case .unavailable: "历史记录暂不可用"
        }
    }
    private var message: String {
        switch state {
        case .tripEmpty, .chargeEmpty: "当前没有可显示的记录。"
        case .filteredEmpty: "试试其他筛选条件。"
        case .unavailable: "当前版本尚未接通真实历史记录。"
        }
    }
    var body: some View { ContentUnavailableView(title, systemImage: "clock", description: Text(message).foregroundColor(historySecondaryColor)) }
}

#if DEBUG
/// Offline visual-validation seam. No account/client/store is created or injected.
/// Uses the very same summary, status, detail, map, chart and list-state views as production.
struct NativeHistoryFixtureView: View {
    private let scenario: String = {
        let arguments = ProcessInfo.processInfo.arguments
        if let value = arguments.first(where: { $0.hasPrefix("--history-case=") }) {
            return String(value.dropFirst("--history-case=".count))
        }
        if let index = arguments.firstIndex(of: "--history-case"), arguments.indices.contains(index + 1) { return arguments[index + 1] }
        return "trip-open-partial"
    }()
    @State private var expanded = true
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("隔离界面验证 · 模拟数据 · 未连接车辆")
                    .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity).padding(12)
                    .background(Color(uiColor: .secondarySystemBackground))
                List {
                    if scenario == "empty" {
                        NativeHistoryEmptyState(state: .tripEmpty)
                    } else if scenario == "failed" {
                        NativeHistoryReadNotice(hasRecords: false, fetchedAt: nil)
                    } else if scenario == "unavailable" {
                        NativeHistoryEmptyState(state: .unavailable)
                    } else if let record = fixtureRecord {
                        if scenario == "refresh-failed" {
                            NativeHistoryReadNotice(hasRecords: true, fetchedAt: record.lastObservedAt)
                        }
                        if scenario == "trip-detail" {
                            NativeHistoryDetailContent(record: record)
                        } else if record.kind == .charge {
                            DisclosureGroup(isExpanded: $expanded) {
                                NativeHistoryDetailContent(record: record)
                            } label: { NativeHistorySummary(record: record) }
                            .accessibilityHint("展开充电记录说明")
                        } else {
                            NavigationLink {
                                List { NativeHistoryDetailContent(record: record) }.navigationTitle("行程详情")
                            } label: { NativeHistorySummary(record: record) }
                            if scenario == "missing-start" { NativeHistoryDetailContent(record: record) }
                        }
                    } else {
                        Text("隔离样本解析失败；未发起网络请求。")
                    }
                }
            }.navigationTitle(scenario.hasPrefix("charge") ? "充电" : scenario == "trip-detail" ? "行程详情" : "行程")
        }
    }
    private var fixtureRecord: NativeHistoryRecord? {
        let charge = scenario.hasPrefix("charge")
        let ended = scenario == "trip-ended" || scenario == "charge-zero"
        let missingStart = scenario == "missing-start" || scenario == "trip-open-partial" || scenario == "trip-detail"
        let formatter = ISO8601DateFormatter()
        let first = Date().addingTimeInterval(-3600)
        let last = first.addingTimeInterval(600)
        let firstText = formatter.string(from: first)
        let lastText = formatter.string(from: last)
        var object: [String: Any] = [
            "id": String(repeating: "a", count: 64), "vin": "5YJ3E1EA7KF000001",
            "kind": charge ? "charge" : "trip", "source": "simulation",
            "first_observed_at": firstText, "last_observed_at": lastText,
            "start_observed": !missingStart, "complete": ended,
            "end_reason": ended ? (charge ? "Stopped" : "parked") : (charge ? "counter_reset" : scenario == "trip-open-partial" ? "data_gap" : "in_progress"),
            "revision": 1, "sample_count": 2, "retention_hours": 168
        ]
        if !missingStart { object["start"] = firstText }
        if ended { object["end"] = lastText }
        if charge {
            object["energy_basis"] = "battery_session_counter"
            object["energy_method"] = ended ? "observed_session_counter_delta" : "insufficient_data"
            if ended { object["energy_added_kwh"] = 0 }
            object["charger_type"] = "ac"
            object["samples"] = [["at": firstText, "battery_percent": 50], ["at": lastText, "battery_percent": 50]]
        } else {
            object["energy_method"] = "trapezoid_power_estimate"
            object["distance_km"] = 3.2
            object["net_energy_kwh"] = 0.4
            // Deliberately no coordinates: do not manufacture a route from a fixture.
            object["samples"] = [["at": firstText, "speed_kph": 0], ["at": lastText, "speed_kph": 30]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? NativeHistoryDecoder.decode(NativeHistoryRecord.self, from: data, allowSimulation: true)
    }
}
#endif

#if DEBUG
/// Separate offline entry: shares production rendering + store, never account state.
struct NativeHistoryPipelineView: View {
    @State private var client: NativeHistoryPipelineClient?
    @State private var history = NativeHistoryStore()
    @State private var failed = false
    @State private var loaded = false
    @State private var selection: String?
    private var records: [NativeHistoryRecord] {
        client?.kind == .charge ? history.chargeRecords : history.tripRecords
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("离线接收链路验证")
                    .font(.headline).accessibilityIdentifier("pipeline.banner")
                Text("合成输入 · 未连接车辆 · 无账号 · 非真实行驶证据")
                    .font(.caption).foregroundStyle(historySecondaryColor)
                if let client {
                    Text("记录 \(records.count) · 列表读取 \(client.listCalls) · 详情读取 \(client.detailCalls)")
                        .font(.caption.monospaced()).accessibilityIdentifier("pipeline.count")
                    Text("list SHA256 \(client.listSHA256)")
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("pipeline.list.sha256")
                }
                List {
                    if failed {
                        Text("导出证据校验或读取失败；未使用替代数据，未发起网络请求。")
                            .accessibilityIdentifier("pipeline.error")
                    }
                    if let client {
                        Button("重新读取已校验列表") { Task { await refresh(client) } }
                            .accessibilityIdentifier("pipeline.load")
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            NavigationLink(value: record.id) {
                                VStack(alignment: .leading) {
                                    Text("记录 \(index) · \(record.id)")
                                        .font(.system(size: 10, design: .monospaced))
                                    NativeHistorySummary(record: record)
                                }
                            }.accessibilityIdentifier("pipeline.record.\(index)")
                        }
                    }
                }.accessibilityIdentifier("pipeline.list")
            }
            .navigationTitle(selection == nil ? "离线历史记录" : "离线记录详情")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in detail(id) }
            .navigationDestination(item: $selection) { id in detail(id) }
            .task {
                guard !loaded else { return }; loaded = true
                do {
                    let args = ProcessInfo.processInfo.arguments
                    guard let flag = args.firstIndex(of: "--native-history-pipeline"), args.indices.contains(flag + 1) else {
                        throw NativeHistoryPipelineClient.Failure.invalidBundle
                    }
                    let client = try NativeHistoryPipelineClient(directory: args[flag + 1])
                    self.client = client
                    history = NativeHistoryStore(now: { client.clock })
                    await refresh(client)
                    if !args.contains("--pipeline-list-only"),
                       let argument = args.first(where: { $0.hasPrefix("--pipeline-record-index=") }) {
                        guard let index = Int(argument.dropFirst("--pipeline-record-index=".count)), records.indices.contains(index) else {
                            throw NativeHistoryPipelineClient.Failure.invalidBundle
                        }
                        let row = records[index]
                        try await history.loadDetail(record: row, vin: client.vin, client: client)
                        guard history.details[row.id] != nil else { throw NativeHistoryPipelineClient.Failure.invalidBundle }
                        selection = row.id
                    }
                } catch { failed = true }
            }
        }
    }
    private func refresh(_ client: NativeHistoryPipelineClient) async {
        do { try await history.refresh(kind: client.kind, vin: client.vin, client: client); failed = false }
        catch { failed = true }
    }
    @ViewBuilder private func detail(_ id: String) -> some View {
        List {
            Text("离线接收链路验证").font(.headline)
            Text("合成输入 · 未连接车辆 · 非真实行驶证据").font(.caption)
            Text(id).font(.system(size: 10, design: .monospaced)).accessibilityIdentifier("pipeline.detail.id")
            if let client, let row = records.first(where: { $0.id == id }) {
                if let hash = client.hashes["details/\(id).json"] {
                    Text("detail SHA256 \(hash)").font(.system(size: 10, design: .monospaced))
                        .accessibilityIdentifier("pipeline.detail.sha256")
                }
                if history.details[id] != nil {
                    Text("详情已通过真实 Store 读取").font(.caption).accessibilityIdentifier("pipeline.detail.loaded")
                }
                NativeHistoryDetailContent(record: historyMatchingDetail(history.details[id], record: row) ?? row)
                Button("读取已校验详情") {
                    Task {
                        do { try await history.loadDetail(record: row, vin: client.vin, client: client) }
                        catch { failed = true }
                    }
                }.accessibilityIdentifier("pipeline.detail.load")
                if history.detailFailed.contains(id) { Text("详情读取失败；未使用替代数据。") }
            }
        }.accessibilityIdentifier("pipeline.detail")
            .navigationTitle("离线记录详情").navigationBarTitleDisplayMode(.inline)
    }
}
#endif
