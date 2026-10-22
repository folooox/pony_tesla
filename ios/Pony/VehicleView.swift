import SwiftUI
import MapKit
import PonyCore

struct VehicleView: View {
    @Environment(AppStore.self) private var store
    @ScaledMetric(relativeTo: .caption) private var quickControlMinimumWidth: CGFloat = 64
    @State private var editing = false
    @State private var pending: QuickControl?
    @State private var confirming = false
    @State private var bodyDemo = false

    var body: some View {
        DashboardGate { vehicle in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("演示模式，不控制真实车辆", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("demo.notice")
                    overview(vehicle)
                    if !store.commandInFlight { StatusNotice() }
                    activeStates(vehicle)
                    commandFeedback
                    quickControls
                    VStack(spacing: 0) {
                        NavigationLink { ClimateView() } label: {
                            homeRow("空调、座椅与方向盘加热", symbol: "fan")
                        }.accessibilityIdentifier("vehicle.openClimate")
                        Divider().padding(.leading, 16)
                        NavigationLink { AllControlsView(embedded: true) } label: {
                            homeRow("全部控制", symbol: "square.grid.2x2")
                        }.accessibilityIdentifier("vehicle.openControls")
                        Divider().padding(.leading, 16)
                        NavigationLink { LocationView() } label: {
                            homeRow("车辆位置", symbol: "location")
                        }
                        Divider().padding(.leading, 16)
                        NavigationLink { VehicleSettingsView() } label: {
                            homeRow("车况与设置", symbol: "slider.horizontal.3")
                        }
                    }
                    .buttonStyle(.plain)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(16)
            }
            .refreshable { await store.refresh() }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(store.vehicle?.name ?? "车辆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                Menu("车辆操作", systemImage: "ellipsis") {
                    Button("编辑快捷控制", systemImage: "slider.horizontal.3") { editing = true }
                    Button("车况模拟（仅演示测试）", systemImage: "wrench.and.screwdriver") { bodyDemo = true }
                    Button("刷新状态", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                        .disabled(store.loading || store.commandInFlight)
                }
            }
        }
        .sheet(isPresented: $editing) { ControlEditor() }
        .sheet(isPresented: $bodyDemo) { VehicleBodyDemoView() }
        .confirmationDialog(pending?.title ?? "车辆操作", isPresented: $confirming, titleVisibility: .visible) {
            Button("模拟\(pending?.title ?? "操作")") {
                if let pending { Task { await store.execute(.quick(pending)) } }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { Text("将修改本机模拟车辆状态，不向真实车辆发送指令。") }
    }

    private func overview(_ vehicle: VehicleSnapshot) -> some View {
        let current = vehicle.status == .online && vehicle.isFresh(at: store.now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(vehicle.battery.map { "\(Display.number($0))%" } ?? "电量未知")
                    .font(.title2.weight(.semibold)).monospacedDigit()
                Text(vehicle.rangeKM.map { "预计续航 \(Display.number($0)) km" } ?? "续航未知")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text(current ? "演示快照 · 在线" : "上次演示快照 · \(vehicle.status == .offline ? "离线" : vehicle.status == .asleep ? "休眠" : "数据已过期")")
                .font(.caption).foregroundStyle(.secondary)
            Text((current ? "" : "上次状态：") + (vehicle.locked.map { $0 ? "已锁车" : "未锁车" } ?? "锁车状态未知"))
                .font(.subheadline)
            bodySummary(vehicle.body, current: current)
            Text("数据时间：\(vehicle.fetchedAt.formatted(date: .numeric, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func bodySummary(_ body: VehicleBodyState, current: Bool) -> some View {
        var parts: [String] = []
        if !body.openLabels.isEmpty { parts.append(body.openLabels.joined(separator: "、") + "已打开") }
        if body.unknownOpenings { parts.append("部分车门与舱盖状态未知") }
        else if body.openLabels.isEmpty { parts.append("车门与舱盖均已关闭") }
        if let vented = body.windowsVented { parts.append(vented ? "车窗通风中" : "车窗已关闭") }
        else { parts.append("车窗状态未知") }
        return Text((current ? "" : "上次车身状态：") + parts.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func activeStates(_ vehicle: VehicleSnapshot) -> some View {
        let presentation = FeatureStatusPresentation(vehicle: vehicle, now: store.now)
        if !presentation.current.isEmpty {
            statusSection("已开启", cards: presentation.current, vehicle: vehicle)
        }
        if !presentation.previous.isEmpty {
            statusSection("上次状态", cards: presentation.previous, vehicle: vehicle)
        }
    }

    private func statusSection(_ title: String, cards: [FeatureStatusCard], vehicle: VehicleSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(cards) { card in
                NavigationLink { featureDestination(card.feature) } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: card.feature.symbol).font(.title3)
                            .frame(minWidth: 28).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.title).font(.headline)
                            if let cached = card.cachedStatus {
                                Text(cached).font(.subheadline).foregroundStyle(.secondary)
                                Text(card.timestamp.formatted(date: .numeric, time: .standard))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if [.climate, .dog, .camp, .defrost].contains(card.feature), let temperature = vehicle.targetTemperature {
                                Text("设定温度：\(Display.number(temperature)) °C")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vehicle.status.\(card.feature.rawValue)")
            }
        }
        // Snapshot updates deliberately have no animated insert/remove transition,
        // including when Reduce Motion is enabled.
    }

    @ViewBuilder private func featureDestination(_ feature: VehicleFeature) -> some View {
        switch feature {
        case .climate, .dog, .camp, .defrost, .seats, .wheel: ClimateView()
        case .charging: ChargingView()
        case .sentry: AllControlsView(embedded: true)
        case .valet: VehicleSettingsView() // No valet reading is synthesized by the snapshot adapter.
        }
    }

    @ViewBuilder private var commandFeedback: some View {
        if let command = store.pendingCommand {
            let feedback = CommandStatusPresentation(commandTitle: command.title, phase: .pending)
            VStack(alignment: .leading, spacing: 8) {
                Text(feedback.title).font(.headline).accessibilityAddTraits(.isHeader)
                ProgressView("\(feedback.commandTitle) · \(feedback.detail)")
                    .font(.subheadline)
                Text("正在等待模拟服务返回；不代表真实车辆状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("vehicle.command.pending")
        }
        if !store.operations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("最近模拟操作").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(Array(store.operations.prefix(3))) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(operation.title) · \(operation.outcome == .succeeded ? "模拟完成" : "模拟操作未完成")")
                            .font(.subheadline.weight(.semibold))
                        Text(operation.message).font(.caption).foregroundStyle(.secondary)
                        Text(operation.date.formatted(date: .numeric, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func homeRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷控制").font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: quickControlMinimumWidth), spacing: 12)], spacing: 16) {
                ForEach(store.visibleControls) { control in
                    Button { pending = control; confirming = true } label: {
                        VStack(spacing: 8) {
                            Image(systemName: control.symbol).font(.title3)
                                .frame(minWidth: 44, minHeight: 44)
                            Text(control.title).font(.caption)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canControl || store.loading)
                    .accessibilityLabel(control.title)
                    .accessibilityIdentifier("control.\(control.rawValue)")
                }
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            if store.visibleControls.isEmpty {
                Button("添加快捷控制") { editing = true }.frame(minHeight: 44)
            }
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
    var embedded = false
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pending: QuickControl?
    @State private var confirming = false
    var body: some View {
        if embedded { controls } else { NavigationStack { controls } }
    }
    private var controls: some View {
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
            .toolbar { if !embedded { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }
            .confirmationDialog(pending?.title ?? "车辆操作", isPresented: $confirming, titleVisibility: .visible) {
                Button("模拟执行") { if let pending { Task { await store.execute(.quick(pending)); if !embedded { dismiss() } } } }
            } message: { Text("不会发送真实车辆指令。执行结果会记录在模拟操作记录中。") }
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
            } footer: { Text("座椅与方向盘加热目前仅模拟；实际能力与操作前提仍需实车验证。过热保护与预约出发待接入。") }
            SeatHeatControls()
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
                    NavigationLink {
                        PreviewInfoView(title: item.0, message: "此入口已预留。接入真实车辆后按硬件、固件和账号权限展示有效字段；不会用零值代替未取得的数据。")
                    } label: {
                        Label(item.0, systemImage: item.1)
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
        .onChange(of: query) { _, next in
            if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchTask?.cancel(); results = []; issue = nil; searching = false
            }
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
