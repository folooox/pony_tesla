import SwiftUI
import MapKit
import PonyCore

struct VehicleView: View {
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var allControls = false
    @State private var pending: QuickControl?
    @State private var confirming = false

    var body: some View {
        DashboardGate { vehicle in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DemoNotice()
                    StatusNotice()
                    overview(vehicle)
                    quickControls
                    NavigationLink { ClimateView() } label: {
                        GroupBox {
                            LabeledContent {
                                Text("\(Display.number(vehicle.targetTemperature)) °C").font(.title2).monospacedDigit()
                            } label: {
                                Label("空调", systemImage: "fan")
                                Text("车内 \(Display.number(vehicle.cabinTemperature)) °C · 车外 \(Display.number(vehicle.outsideTemperature)) °C")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                    NavigationLink { LocationView() } label: {
                        GroupBox { LabeledContent("车辆位置", value: vehicle.coordinate == nil ? "暂无位置" : "查看地图") }
                    }.buttonStyle(.plain)
                    NavigationLink("车况与设置", systemImage: "slider.horizontal.3") { VehicleSettingsView() }
                        .buttonStyle(.glass)
                }.padding()
            }
            .refreshable { await store.refresh() }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(store.vehicle?.name ?? "车辆")
        .toolbar {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                Menu("车辆操作", systemImage: "ellipsis") {
                    Button("编辑快捷控制", systemImage: "slider.horizontal.3") { editing = true }
                    Button("全部控制", systemImage: "square.grid.2x2") { allControls = true }
                    Button("刷新状态", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                        .disabled(store.loading || store.commandInFlight)
                }
            }
        }
        .sheet(isPresented: $editing) { ControlEditor() }
        .sheet(isPresented: $allControls) { AllControlsView() }
        .confirmationDialog(pending?.title ?? "车辆操作", isPresented: $confirming, titleVisibility: .visible) {
            Button("模拟\(pending?.title ?? "操作")") {
                if let pending { Task { await store.execute(.quick(pending)) } }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { Text("将修改本机模拟车辆状态，不向真实车辆发送指令。") }
    }
    private func overview(_ vehicle: VehicleSnapshot) -> some View {
        VStack(spacing: 20) {
            Label(vehicle.locked.map { $0 ? "已锁车" : "未锁车" } ?? "锁车状态未知", systemImage: vehicle.locked == false ? "lock.open" : "lock")
                .font(.subheadline).foregroundStyle(.secondary)
            Image(systemName: "car.side.fill").resizable().scaledToFit().foregroundStyle(.secondary)
                .frame(maxWidth: 280, minHeight: 100, maxHeight: 160).padding(.vertical)
                .accessibilityLabel("车辆造型占位图")
            Text("2022 · 后轮驱动").font(.subheadline).foregroundStyle(.secondary)
            MetricRow(values: [("当前电量", Display.number(vehicle.battery), "%"), ("预计续航", Display.number(vehicle.rangeKM), "km")])
            Text("数据时间：\(vehicle.fetchedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷控制").font(.headline)
            GlassEffectContainer {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 16) {
                    ForEach(store.visibleControls) { control in
                        VStack(spacing: 8) {
                            Button { pending = control; confirming = true } label: {
                                Image(systemName: control.symbol).font(.title3).frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.glass).buttonBorderShape(.circle)
                            .disabled(!store.canControl || store.loading)
                            .accessibilityLabel(control.title)
                            .accessibilityIdentifier("control.\(control.rawValue)")
                            Text(control.title).font(.caption)
                        }
                    }
                }
            }
            if store.visibleControls.isEmpty { Button("添加快捷控制") { editing = true }.buttonStyle(.glass) }
            if store.commandInFlight { ProgressView("等待模拟服务反馈…").font(.footnote) }
        }
    }
}

struct ControlEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.layout.controls) { control in
                        HStack {
                            Label(control.title, systemImage: control.symbol)
                            if store.vehicle?.supported.contains(control) == false {
                                Spacer(); Text("当前不可用").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { store.moveControls($0, to: $1) }
                    .onDelete { store.removeControls($0) }
                } header: { Text("首页显示") } footer: { Text("最多 4 项，可拖动排序。修改自动保存。") }
                Section("添加控制") {
                    ForEach(QuickControl.allCases.filter { !store.layout.controls.contains($0) }) { control in
                        Button(control.title, systemImage: control.symbol) { store.addControl(control) }
                            .disabled(store.layout.controls.count >= 4 || store.vehicle?.supported.contains(control) != true)
                    }
                }
                Section { Button("恢复默认布局") { store.restoreControls() } }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("快捷控制").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct AllControlsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pending: QuickControl?
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            List {
                Section { DemoNotice(); StatusNotice() }
                Section {
                    ForEach(QuickControl.allCases) { control in
                        Button(control.title, systemImage: control.symbol) { pending = control; confirming = true }
                            .disabled(!store.canControl || store.vehicle?.supported.contains(control) != true)
                    }
                }
            }
            .navigationTitle("全部控制").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog(pending?.title ?? "车辆操作", isPresented: $confirming, titleVisibility: .visible) {
                Button("模拟执行") { if let pending { Task { await store.execute(.quick(pending)); dismiss() } } }
            } message: { Text("不会发送真实车辆指令。执行结果会记录在模拟操作记录中。") }
        }
    }
}

struct ClimateView: View {
    @Environment(AppStore.self) private var store
    @State private var temperature = 22.0
    @State private var mode: CabinMode = .normal
    var body: some View {
        Form {
            Section { DemoNotice(); StatusNotice() }
            Section("温度") {
                LabeledContent("车辆设定", value: "\(Display.number(store.vehicle?.targetTemperature, digits: 1)) °C")
                LabeledContent("待应用温度", value: "\(Display.number(temperature, digits: 1)) °C")
                Slider(value: $temperature, in: 16...28, step: 0.5) { Text("温度") }
            }
            Section("空调模式") {
                Picker("模式", selection: $mode) { ForEach(CabinMode.allCases) { Text($0.rawValue).tag($0) } }
                Text("车辆当前模式：\(store.vehicle?.cabinMode.rawValue ?? "未知")")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("应用到模拟车辆") { Task { await store.execute(.setClimate(temperature: temperature, mode: mode)) } }
                    .disabled(!store.canControl)
            } footer: { Text("座椅加热、方向盘加热、过热保护与预约出发将在实际车辆能力验证后接入。") }
        }
        .navigationTitle("空调")
        .onAppear { temperature = store.vehicle?.targetTemperature ?? 22; mode = store.vehicle?.cabinMode ?? .normal }
    }
}

struct VehicleSettingsView: View {
    private let entries = [("轮胎与车况", "gauge.with.dots.needle.50percent"), ("电池与动力", "battery.100percent"), ("安全与驾驶", "shield"), ("软件与更新", "arrow.triangle.2.circlepath"), ("驾驶员与访问", "person.2")]
    var body: some View {
        List {
            Section { DemoNotice() }
            Section {
                ForEach(entries, id: \.0) { item in
                    NavigationLink(item.0, systemImage: item.1) {
                        PreviewInfoView(title: item.0, message: "此入口已预留。接入真实车辆后按硬件、固件和账号权限展示有效字段；不会用零值代替未取得的数据。")
                    }
                }
            }
        }.navigationTitle("车况与设置")
    }
}

struct LocationView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var issue: String?
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        List {
            Section { DemoNotice() }
            Section("示例车辆位置") {
                if let coordinate = store.vehicle?.coordinate, coordinate.isValid {
                    Map { Marker("示例车辆", systemImage: "car", coordinate: coordinate.mapCoordinate) }
                        .frame(height: 260)
                } else { Text("暂无有效位置数据").foregroundStyle(.secondary) }
            }
            Section("地点搜索") {
                if searching { ProgressView("正在搜索…") }
                if let issue { Text(issue).foregroundStyle(.secondary) }
                ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                    Button(item.name ?? "地点") {
                        store.message = UserMessage(title: "目的地预览", detail: "已选择 \(item.name ?? "地点")。发送到车机尚未接入。")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜索目的地")
        .onSubmit(of: .search) {
            searchTask?.cancel()
            searchTask = Task { await search() }
        }
        .onDisappear { searchTask?.cancel(); searching = false }
        .navigationTitle("找车与导航")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; searching = false; issue = nil; return }
        searching = true; issue = nil; results = []
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = text
        if let coordinate = store.vehicle?.coordinate {
            request.region = MKCoordinateRegion(center: coordinate.mapCoordinate, latitudinalMeters: 20000, longitudinalMeters: 20000)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            results = response.mapItems
            if results.isEmpty { issue = "没有找到地点，请尝试其他关键词。" }
        } catch { if !Task.isCancelled { issue = "搜索暂时不可用，请检查网络后重试。" } }
        if !Task.isCancelled { searching = false }
    }
}
