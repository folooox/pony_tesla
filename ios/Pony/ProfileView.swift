import SwiftUI
import PonyCore

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(NativeAccountState.self) private var account
    @State private var editingControls = false
    private var privacyMessage: String {
        if account.storageUnavailable {
            return "安全会话存储尚未读取成功，请前往账号页面重试。不会自动访问服务器或清除安全存储。模拟数据与真实账号分离。"
        }
        if account.hasLocalSession {
            return "应用会话凭据保存在本机 Keychain。手动加载列表、读取状态或查看缓存会请求账号所属的后端服务，并可能由后端请求 Tesla；无自动轮询或控车。缓存可能过期，真实行程与充电历史尚未采集。退出不等于撤销 Tesla 授权或删除数据。演示记录与真实账号分离。地图搜索文字会提交给地图服务。"
        }
        return "当前显示本机模拟车辆、行程与操作记录，演示控制不会操作真实车辆。连接账号后才可手动加载真实车辆与只读状态；不自动轮询。退出后不代表服务器数据已删除或 Tesla 授权已撤销。地图搜索文字会提交给地图服务。"
    }
    var body: some View {
        List {
            Section {
                Label {
                    Text("Pony 车主").font(.headline)
                    Text(account.status).font(.subheadline).foregroundStyle(.secondary)
                } icon: { Image(systemName: "person.crop.circle.fill").font(.largeTitle) }
            }
            Section("车辆与账号") {
                NavigationLink { AccountView() } label: { Label("账号与车辆授权", systemImage: "key") }
            }
            Section("演示功能与设置（非真实账号数据）") {
                NavigationLink("演示车辆与控制") { VehicleView() }
                NavigationLink("演示行程") { TripsView() }
                NavigationLink("演示充电") { ChargingView() }
                Button("演示首页快捷控制", systemImage: "slider.horizontal.3") { editingControls = true }
                NavigationLink { OperationLogView() } label: { Label("模拟操作记录", systemImage: "clock.arrow.circlepath") }
            }
            Section("数据与隐私") {
                NavigationLink { DataSettingsView() } label: { Label("模拟行程管理与导出", systemImage: "externaldrive.badge.icloud") }
                NavigationLink {
                    PreviewInfoView(title: "隐私与权限", message: privacyMessage)
                } label: {
                    Label("隐私与权限", systemImage: "hand.raised")
                }
            }
            Section("应用") {
                NavigationLink {
                    PreviewInfoView(title: "显示与辅助功能", message: "跟随系统字体大小、深浅色、对比度、减少透明度及减少动态效果设置。导航栏与控件采用系统 Liquid Glass。")
                } label: {
                    Label("显示与辅助功能", systemImage: "textformat.size")
                }
                LabeledContent("版本", value: "0.3 · 原生只读接入")
            }
            Section {
                Picker("测试场景", selection: Binding(get: { store.scenario }, set: { next in Task { await store.changeScenario(next) } })) {
                    ForEach(DemoScenario.allCases) { Text($0.title).tag($0) }
                }
                Button("重置当前演示") { Task { await store.changeScenario(store.scenario) } }
                    .disabled(store.loading || store.commandInFlight)
            } header: { Text("演示场景（仅影响模拟数据）") } footer: { Text("切换场景会重置模拟车辆及历史，不影响快捷控制布局，也不会操作真实账号。") }
        }
        .navigationTitle("我的")
        .sheet(isPresented: $editingControls) { ControlEditor() }
    }
}

struct OperationLogView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        List {
            Section { DemoNotice() }
            if store.operations.isEmpty {
                ContentUnavailableView("暂无操作", systemImage: "clock", description: Text("模拟执行控车或充电操作后，会在这里看到结果。"))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(store.operations) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(entry.title, systemImage: entry.outcome == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.headline)
                        Text(entry.message).font(.subheadline).foregroundStyle(.secondary)
                        Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("模拟操作记录")
    }
}

struct DataSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var exporting = false
    @State private var deleting = false
    @State private var document: CSVDocument?
    var body: some View {
        Form {
            Section("当前数据") {
                LabeledContent("数据来源", value: "本机内存 · 模拟")
                LabeledContent("可见行程", value: "\(store.visibleTrips.count) 段")
                LabeledContent("保留窗口", value: "最近 168 小时")
            }
            Section {
                Button("导出示例 CSV", systemImage: "square.and.arrow.up") {
                    store.tick()
                    document = CSVDocument(text: TripCSV.export(store.visibleTrips, now: store.now)); exporting = true
                }.disabled(store.visibleTrips.isEmpty)
                Button("清空模拟历史", role: .destructive) { deleting = true }
                    .disabled(store.loading || store.commandInFlight || (store.trips.isEmpty && store.charges.isEmpty && store.operations.isEmpty))
            } footer: { Text("当前不会删除或导出任何真实车辆数据。模拟记录中的备注与标签只在当前演示会话中保存。") }
            Section("正式接入后的规则") {
                Text("服务器按行程结束时间保留最近 7 天历史，已有查询与到期清理接口。本演示尚未接入这些接口，真实持续采集仍待实现。用户导出到自己设备的文件由用户管理。")
            }
        }
        .navigationTitle("行程数据")
        .confirmationDialog("清空当前模拟历史？", isPresented: $deleting, titleVisibility: .visible) {
            Button("清空模拟历史", role: .destructive) { Task { await store.deleteDemoHistory() } }
        } message: { Text("清空演示行程、充电记录及操作记录。可以从“我的”重置演示场景恢复。") }
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText, defaultFilename: "Pony-模拟行程") { result in
            if case .failure(let error) = result { store.message = UserMessage(title: "导出失败", detail: error.localizedDescription) }
        }
    }
}
