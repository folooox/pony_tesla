import SwiftUI
import MapKit
import UniformTypeIdentifiers
import PonyCore

extension Coordinate {
    var mapCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

enum Display {
    static func number(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
    }
}

struct DemoNotice: View {
    var body: some View {
        Label("演示模式 · 不控制真实车辆", systemImage: "info.circle")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("demo.notice")
    }
}

struct DashboardGate<Content: View>: View {
    @Environment(AppStore.self) private var store
    @ViewBuilder var content: (VehicleSnapshot) -> Content
    var body: some View {
        if let vehicle = store.vehicle {
            content(vehicle)
        } else if let failure = store.failure {
            ContentUnavailableView {
                Label(failure == .unauthorized ? "需要重新授权" : "暂时无法获取数据", systemImage: failure == .unauthorized ? "key" : "wifi.exclamationmark")
            } description: { Text(failure.localizedDescription + " 当前为模拟测试场景，可在“我的”中切换。") }
            actions: { Button("重试") { Task { await store.refresh() } }.buttonStyle(.glass) }
        } else {
            ProgressView("正在获取示例数据…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StatusNotice: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let reason = store.controlUnavailableReason {
            Label(reason, systemImage: store.commandInFlight ? "hourglass" : "exclamationmark.circle")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("vehicle.status-notice")
        }
    }
}

struct Metric: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title2).fontWeight(.semibold).monospacedDigit()
            Text(unit.isEmpty ? title : "\(title) · \(unit)").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value == "—" ? "\(title)，数据不足" : "\(title)，\(value) \(unit)")
    }
}

struct MetricRow: View {
    let values: [(String, String, String)]
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            ForEach(values.indices, id: \.self) { i in Metric(title: values[i].0, value: values[i].1, unit: values[i].2) }
        }
    }
}

struct TripMap: View {
    let trip: TripRecord
    var selected: TripSample? = nil
    var interactive = true
    var body: some View {
        Map(interactionModes: interactive ? .all : []) {
            ForEach(trip.segments()) { segment in
                MapPolyline(coordinates: segment.samples.compactMap { $0.coordinate?.mapCoordinate })
                    .stroke(.blue, lineWidth: 5)
            }
            if let start = trip.samples.first?.coordinate, start.isValid {
                Marker("示例起点", systemImage: "circle", coordinate: start.mapCoordinate).tint(.green)
            }
            if let end = trip.samples.last?.coordinate, end.isValid {
                Marker("示例终点", systemImage: "flag.checkered", coordinate: end.mapCoordinate)
            }
            if let coordinate = selected?.coordinate, coordinate.isValid {
                Annotation("回放位置", coordinate: coordinate.mapCoordinate) {
                    Image(systemName: "location.circle.fill").font(.title).foregroundStyle(.blue, .white)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityLabel("示例行程地图，缺失路段不连线")
    }
}

struct PreviewInfoView: View {
    let title: String
    let message: String
    var body: some View {
        List { Section { Text(message) }; Section { DemoNotice() } }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

nonisolated struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
