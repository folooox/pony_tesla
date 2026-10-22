import Foundation
import Observation
import PonyCore

struct OperationEntry: Identifiable {
    enum Outcome: Equatable { case succeeded, failed }
    let id = UUID()
    let date: Date
    let title: String
    let outcome: Outcome
    let message: String
}

struct UserMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

@Observable @MainActor
final class AppStore {
    private(set) var vehicle: VehicleSnapshot?
    private(set) var trips: [TripRecord] = []
    private(set) var charges: [ChargingRecord] = []
    private(set) var operations: [OperationEntry] = []
    private(set) var loading = false
    private(set) var commandInFlight = false
    private(set) var pendingCommand: VehicleCommand?
    private(set) var failure: ServiceError?
    private(set) var scenario: DemoScenario
    private(set) var layout: ControlLayout
    var message: UserMessage?
    var now = Date.now
    private var service: any VehicleService
    private var generation = UUID()
    private let defaults: UserDefaults

    init(scenario: DemoScenario = .normal, defaults: UserDefaults = .standard, service: (any VehicleService)? = nil) {
        self.defaults = defaults
        self.scenario = scenario
        self.service = service ?? DemoVehicleService(scenario: scenario)
        self.layout = ControlLayout(rawValues: defaults.stringArray(forKey: "native.controls.v1"))
    }

    var visibleTrips: [TripRecord] { HistoryPolicy.visible(trips, now: now) }
    var summary: TripSummary { TripSummary(trips: visibleTrips) }
    var visibleControls: [QuickControl] { layout.controls.filter { vehicle?.supported.contains($0) == true } }
    var canControl: Bool { failure == nil && !commandInFlight && vehicle?.canControl(at: now) == true }
    var controlUnavailableReason: String? {
        if commandInFlight { return "正在等待操作结果…" }
        if let failure { return failure.localizedDescription }
        guard let vehicle else { return "正在获取车辆状态。" }
        if vehicle.status == .asleep { return "车辆休眠中，当前不能操作。" }
        if vehicle.status == .offline { return "车辆离线，显示上次获取的数据。" }
        if !vehicle.isFresh(at: now) { return "数据已过期，下拉刷新后再操作。" }
        return nil
    }

    func refresh() async {
        guard !loading, !commandInFlight else { return }
        let requestGeneration = generation
        loading = true
        defer { if generation == requestGeneration { loading = false } }
        do {
            let result = try await service.dashboard(now: .now)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            vehicle = result.vehicle; trips = result.trips; charges = result.charges
            failure = nil; tick()
        } catch is CancellationError { }
        catch {
            guard generation == requestGeneration else { return }
            failure = error as? ServiceError ?? .unavailable
        }
    }

    func tick() {
        now = .now
        // Query visibility expires immediately; this is not a replacement for server cleanup.
        trips = HistoryPolicy.visible(trips, now: now)
        charges.removeAll { $0.end <= now.addingTimeInterval(-HistoryPolicy.retention) }
        operations.removeAll { $0.date <= now.addingTimeInterval(-HistoryPolicy.retention) }
    }

    func execute(_ command: VehicleCommand, announceSuccess: Bool = true) async {
        tick()
        guard canControl, !loading else {
            message = UserMessage(title: "暂时无法操作", detail: controlUnavailableReason ?? "正在刷新，请稍后重试。")
            return
        }
        let requestGeneration = generation
        commandInFlight = true
        pendingCommand = command
        defer {
            if generation == requestGeneration {
                commandInFlight = false
                pendingCommand = nil
            }
        }
        do {
            let updated = try await service.execute(command, now: .now)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            vehicle = updated; now = .now
            let detail = "模拟服务已返回结果。没有向真实车辆发送指令。"
            operations.insert(OperationEntry(date: now, title: command.title, outcome: .succeeded, message: detail), at: 0)
            if announceSuccess { message = UserMessage(title: "\(command.title) · 模拟完成", detail: detail) }
        } catch is CancellationError { }
        catch {
            guard generation == requestGeneration else { return }
            let issue = error as? ServiceError ?? .unavailable
            operations.insert(OperationEntry(date: .now, title: command.title, outcome: .failed, message: issue.localizedDescription), at: 0)
            if issue == .unauthorized { failure = issue }
            message = UserMessage(title: "操作未完成", detail: issue.localizedDescription)
        }
    }

    func changeScenario(_ next: DemoScenario) async {
        generation = UUID() // Ignore old in-flight responses when switching scenarios.
        scenario = next; service = DemoVehicleService(scenario: next)
        vehicle = nil; trips = []; charges = []; operations = []
        loading = false; commandInFlight = false; pendingCommand = nil; failure = nil; message = nil
        await refresh()
    }

    func addControl(_ control: QuickControl) { layout.add(control); saveControls() }
    func removeControls(_ offsets: IndexSet) { layout.remove(at: offsets); saveControls() }
    func moveControls(_ offsets: IndexSet, to destination: Int) { layout.move(from: offsets, to: destination); saveControls() }
    func restoreControls() { layout = ControlLayout(); saveControls() }
    private func saveControls() { defaults.set(layout.controls.map(\.rawValue), forKey: "native.controls.v1") }

    func saveMetadata(id: UUID, tag: String, note: String) async -> Bool {
        tick()
        guard visibleTrips.contains(where: { $0.id == id }) else {
            message = UserMessage(title: "记录已不可用", detail: "行程已到期或被清除，无法继续保存备注。")
            return false
        }
        let requestGeneration = generation
        do {
            try await service.saveTrip(id: id, tag: tag, note: note)
            guard generation == requestGeneration else { return false }
            if let index = trips.firstIndex(where: { $0.id == id }) {
                trips[index].tag = String(tag.prefix(30)); trips[index].note = String(note.prefix(500))
            }
            return true
        } catch {
            if generation == requestGeneration { message = UserMessage(title: "保存失败", detail: error.localizedDescription) }
            return false
        }
    }

    func deleteDemoHistory() async {
        guard !commandInFlight, !loading else {
            message = UserMessage(title: "请稍后重试", detail: "请等待当前刷新或操作完成后再清空模拟历史。")
            return
        }
        let requestGeneration = generation
        do {
            try await service.deleteHistory()
            guard generation == requestGeneration else { return }
            trips = []; charges = []; operations = []
            message = UserMessage(title: "模拟记录已清空", detail: "已清除当前演示会话的数据，未删除任何服务器或真实车辆数据。")
        } catch {
            if generation == requestGeneration { message = UserMessage(title: "清除失败", detail: error.localizedDescription) }
        }
    }
}
