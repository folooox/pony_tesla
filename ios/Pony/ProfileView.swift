import SwiftUI
import PonyCore

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @State private var editingControls = false
    var body: some View {
        List {
            Section {
                Label {
                    Text("Pony 车主").font(.headline)
                    Text("演示模式 · 尚未连接 Tesla").font(.subheadline).foregroundStyle(.secondary)
                } icon: { Image(systemName: "person.crop.circle.fill").font(.largeTitle) }
            }
            Section("车辆与账号") {
                NavigationLink { AccountView() } label: { Label("账号与车辆授权", systemImage: "key") }
                Button("首页快捷控制", systemImage: "slider.horizontal.3") { editingControls = true }
                NavigationLink { OperationLogView() } label: { Label("操作记录", systemImage: "clock.arrow.circlepath") }
            }
            Section("数据与隐私") {
                NavigationLink { DataSettingsView() } label: { Label("行程管理与导出", systemImage: "externaldrive.badge.icloud") }
                NavigationLink {
                    PreviewInfoView(title: "隐私与权限", message: "本版本只保存本机快捷控制布局；车辆、行程和操作记录均为内存中的模拟数据。地图与地点搜索使用 MapKit，搜索文字会提交给地图服务。尚未向 Tesla 发送任何请求。")
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
                LabeledContent("版本", value: "0.2 · 原生演示")
            }
            Section {
                Picker("测试场景", selection: Binding(get: { store.scenario }, set: { next in Task { await store.changeScenario(next) } })) {
                    ForEach(DemoScenario.allCases) { Text($0.title).tag($0) }
                }
                Button("重置当前演示") { Task { await store.changeScenario(store.scenario) } }
                    .disabled(store.loading || store.commandInFlight)
            } header: { Text("模拟器测试") } footer: { Text("切换场景会重置模拟车辆及历史，不影响快捷控制布局，也不会操作真实账号。") }
        }
        .navigationTitle("我的")
        .sheet(isPresented: $editingControls) { ControlEditor() }
    }
}

struct AccountView: View {
    var body: some View {
        Form {
            Section("当前状态") {
                LabeledContent("数据来源", value: "本机模拟服务")
                LabeledContent("Tesla 账号", value: "尚未连接")
            }
            Section {
                Button("使用 Tesla 账号连接", systemImage: "person.crop.circle.badge.checkmark") { }
                    .disabled(true)
            } footer: { Text("开发者应用凭据、后端用户会话和原生 OAuth 回调尚未接入，因此当前不开放真实登录。后续会在 Tesla 官方页面完成授权。") }
        }.navigationTitle("账号与授权")
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
