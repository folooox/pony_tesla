import SwiftUI
import Charts
import PonyCore

struct TripsView: View {
    @Environment(AppStore.self) private var store
    @State private var day: Date?
    private var filtered: [TripRecord] {
        guard let day else { return store.visibleTrips }
        return HistoryPolicy.onDay(day, trips: store.visibleTrips)
    }
    private var days: [Date] {
        let calendar = Calendar.current
        return (0...7).compactMap { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: store.now)) }
    }
    var body: some View {
        DashboardGate { _ in
            List {
                Section {
                    DemoNotice()
                    MetricRow(values: [("累计里程", Display.number(store.summary.distanceKM, digits: 1), "km"),
                                       ("平均能耗", Display.number(store.summary.averageWhPerKM), "Wh/km"),
                                       ("行程", "\(store.summary.count)", "段")])
                        .padding(.vertical, 8)
                    Picker("日期", selection: $day) {
                        Text("最近 7 天").tag(nil as Date?)
                        ForEach(days, id: \.self) { Text($0.formatted(date: .abbreviated, time: .omitted)).tag(Optional($0)) }
                    }
                } header: { Text("最近 7 天汇总") }
                if filtered.isEmpty {
                    ContentUnavailableView("暂无行程", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                           description: Text("所选范围内没有记录。连接车辆后才会开始积累行程。"))
                        .listRowBackground(Color.clear)
                } else {
                    Section(day == nil ? "所有行程" : "当日行程") {
                        ForEach(filtered) { trip in
                            NavigationLink { TripDetailView(tripID: trip.id) } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    TripMap(trip: trip, interactive: false).frame(height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 16)).allowsHitTesting(false).accessibilityHidden(true)
                                    Text(trip.title).font(.headline)
                                    Text(trip.start.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    MetricRow(values: [("里程", Display.number(trip.distanceKM, digits: 1), "km"),
                                                       ("时长", Display.duration(trip.duration), ""),
                                                       ("估算耗电", Display.number(trip.energyKWh, digits: 2), "kWh")])
                                    if !trip.tag.isEmpty { Label(trip.tag, systemImage: "tag").font(.caption).foregroundStyle(.secondary) }
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }
                Section {
                    Text("当前记录为本机模拟数据。正式版行程存于服务器，按结束时间滚动保留 168 小时。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .refreshable { await store.refresh() }
        }
        .navigationTitle("行程")
        .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
    }
}

struct TripDetailView: View {
    let tripID: UUID
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var metric: TripMetric = .speed
    @State private var elapsed = 0.0
    @State private var selectedTime: Date?
    @State private var playing = false
    @State private var editing = false
    @State private var exporting = false
    @State private var document: CSVDocument?
    private var trip: TripRecord? { store.visibleTrips.first { $0.id == tripID } }

    var body: some View {
        Group {
            if let trip { detail(trip) }
            else { ContentUnavailableView("行程已不可用", systemImage: "clock.badge.exclamationmark", description: Text("记录可能已超过 7 天保留期、被清除，或已切换演示场景。")) }
        }
        .navigationTitle(trip?.title ?? "行程详情").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("行程操作", systemImage: "ellipsis") {
                    Button("标签与备注", systemImage: "square.and.pencil") { editing = true }
                    Button("导出示例 CSV", systemImage: "square.and.arrow.up") {
                        guard let trip else { return }
                        document = CSVDocument(text: TripCSV.export([trip], now: store.now)); exporting = true
                    }
                }.disabled(trip == nil)
            }
        }
        .sheet(isPresented: $editing) { if let trip { TripMetadataEditor(trip: trip) } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText, defaultFilename: "Pony-示例行程") { result in
            if case .failure(let error) = result { store.message = UserMessage(title: "导出失败", detail: error.localizedDescription) }
        }
        .task(id: playing) {
            guard playing, !reduceMotion, let trip else { return }
            if elapsed >= trip.duration { elapsed = 0 }
            while !Task.isCancelled && playing {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard !Task.isCancelled, self.trip != nil else { playing = false; return }
                elapsed = min(elapsed + 30, trip.duration)
                if elapsed >= trip.duration { playing = false }
            }
        }
        .onChange(of: selectedTime) { _, date in
            if let date, let trip { playing = false; elapsed = min(max(0, date.timeIntervalSince(trip.start)), trip.duration) }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playing = false } }
        .onChange(of: reduceMotion) { _, value in if value { playing = false } }
        .onDisappear { playing = false }
    }
    private func detail(_ trip: TripRecord) -> some View {
        let currentTime = trip.start.addingTimeInterval(elapsed)
        let sample = trip.sample(at: currentTime)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DemoNotice().padding(.horizontal)
                TripMap(trip: trip, selected: sample).frame(height: 280)
                VStack(alignment: .leading, spacing: 24) {
                    Text("\(trip.start.formatted(date: .abbreviated, time: .shortened)) — \(trip.end.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    MetricRow(values: [("里程", Display.number(trip.distanceKM, digits: 1), "km"),
                                       ("时长", Display.duration(trip.duration), ""),
                                       ("估算耗电", Display.number(trip.energyKWh, digits: 2), "kWh")])
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            metricPicker
                            Text("\(Display.number(sample?.value(for: metric))) \(metric.unit)").font(.title2).monospacedDigit()
                            if sample?.value(for: metric) == nil { Text("此时段数据不足").font(.footnote).foregroundStyle(.secondary) }
                            Chart {
                                ForEach(trip.segments(metric: metric)) { segment in
                                    ForEach(segment.samples) { point in
                                        if let value = point.value(for: metric) {
                                            LineMark(x: .value("时间", point.time), y: .value(metric.rawValue, value), series: .value("连续段", String(segment.id)))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                                RuleMark(x: .value("当前时间", currentTime)).foregroundStyle(.secondary)
                            }
                            .chartXScale(domain: trip.start...trip.end)
                            .chartXSelection(value: $selectedTime)
                            .chartLegend(.hidden)
                            .frame(height: 190)
                            .accessibilityLabel("\(metric.rawValue)示例曲线，缺失数据不连线")
                            HStack {
                                Button(playing ? "暂停回放" : "播放回放", systemImage: playing ? "pause.fill" : "play.fill") { playing.toggle() }
                                    .labelStyle(.iconOnly).buttonStyle(.glass)
                                    .disabled(reduceMotion || trip.duration <= 0)
                                Slider(value: $elapsed, in: 0...max(1, trip.duration), step: 1, onEditingChanged: { if $0 { playing = false } }) { Text("回放进度") }
                                    .disabled(trip.duration <= 0)
                            }
                            Text(currentTime, style: .time).font(.caption).monospacedDigit()
                            if reduceMotion { Text("已跟随系统减少动态效果，可手动拖动查看。").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    if !trip.tag.isEmpty { Label(trip.tag, systemImage: "tag").font(.subheadline) }
                    if !trip.note.isEmpty { Text(trip.note).font(.body) }
                    Text("速度、功率、电量和位置共用时间轴。负功率表示回收；数据缺口不会补画轨迹。").font(.footnote).foregroundStyle(.secondary)
                }.padding(.horizontal)
            }.padding(.vertical)
        }
    }
    @ViewBuilder private var metricPicker: some View {
        let picker = Picker("曲线", selection: $metric) { ForEach(TripMetric.allCases) { Text($0.rawValue).tag($0) } }
        if typeSize.isAccessibilitySize { picker.pickerStyle(.menu) } else { picker.pickerStyle(.segmented) }
    }
}

struct TripMetadataEditor: View {
    let trip: TripRecord
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var tag: String
    @State private var note: String
    @State private var saving = false
    init(trip: TripRecord) { self.trip = trip; _tag = State(initialValue: trip.tag); _note = State(initialValue: trip.note) }
    var body: some View {
        NavigationStack {
            Form {
                Section("标签") { TextField("如：通勤", text: $tag) }
                Section("备注") { TextField("记录这段行程", text: $note, axis: .vertical).lineLimit(3...8) }
                Section { Text("模拟数据保存在当前演示会话中。标签最多 30 字，备注最多 500 字。").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("标签与备注").navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        saving = true
                        Task { if await store.saveMetadata(id: trip.id, tag: tag, note: note) { dismiss() }; saving = false }
                    }.disabled(saving || tag.count > 30 || note.count > 500)
                }
            }
        }
    }
}
