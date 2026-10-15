import Foundation

public enum QuickControl: String, CaseIterable, Identifiable, Codable, Sendable {
    case lock, unlock, climate, frunk, trunk, sentry, horn, lights, windows, closeWindows, chargePort
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lock: "锁车"
        case .unlock: "解锁"
        case .climate: "空调"
        case .frunk: "前备箱"
        case .trunk: "后备箱"
        case .sentry: "哨兵"
        case .horn: "鸣笛"
        case .lights: "闪灯"
        case .windows: "车窗通风"
        case .closeWindows: "关闭车窗"
        case .chargePort: "充电口"
        }
    }
    public var symbol: String {
        switch self {
        case .lock: "lock"
        case .unlock: "lock.open"
        case .climate: "fan"
        case .frunk: "car.side.front.open"
        case .trunk: "car.side.rear.open"
        case .sentry: "shield"
        case .horn: "speaker.wave.2"
        case .lights: "light.beacon.max"
        case .windows, .closeWindows: "car.side"
        case .chargePort: "ev.plug.ac.type.2"
        }
    }
}

public struct ControlLayout: Equatable, Sendable {
    public static let defaults: [QuickControl] = [.lock, .climate, .trunk, .sentry]
    public private(set) var controls: [QuickControl]
    public init(rawValues: [String]? = nil) {
        var seen = Set<QuickControl>()
        controls = rawValues.map { values in
            Array(values.compactMap(QuickControl.init(rawValue:)).filter { seen.insert($0).inserted }.prefix(4))
        } ?? Self.defaults
    }
    public mutating func add(_ control: QuickControl) {
        guard controls.count < 4, !controls.contains(control) else { return }
        controls.append(control)
    }
    public mutating func remove(at offsets: IndexSet) {
        controls = controls.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }
    public mutating func move(from offsets: IndexSet, to destination: Int) {
        guard destination >= 0, destination <= controls.count,
              offsets.allSatisfy({ controls.indices.contains($0) }) else { return }
        let moving = offsets.sorted().map { controls[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        remove(at: offsets)
        controls.insert(contentsOf: moving, at: insertion)
    }
}

public enum VehicleStatus: String, Codable, Sendable { case online, asleep, offline }
public enum CabinMode: String, CaseIterable, Identifiable, Sendable {
    case off = "关闭", normal = "常规", dog = "宠物", camp = "露营", defrost = "除霜"
    public var id: String { rawValue }
}

public struct VehicleSnapshot: Sendable, Equatable {
    public var name = "我的 Model 3"
    public var status: VehicleStatus = .online
    public var fetchedAt: Date
    public var battery: Double? = 62
    public var rangeKM: Double? = 276
    public var locked: Bool? = true
    public var sentry: Bool? = false
    public var cabinTemperature: Double? = 24
    public var outsideTemperature: Double? = 21
    public var targetTemperature: Double? = 22
    public var cabinMode: CabinMode = .off
    public var charging = true
    public var chargeLimit = 80.0
    public var chargingKW: Double? = 7
    public var energyAdded: Double? = 12.4
    public var supported = Set(QuickControl.allCases)
    public var coordinate: Coordinate? = Coordinate(latitude: 30.278, longitude: 120.195)
    public init(now: Date) { fetchedAt = now }
    public func isFresh(at now: Date, maximumAge: TimeInterval = 120) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < maximumAge
    }
    public func canControl(at now: Date) -> Bool { status == .online && isFresh(at: now) }
}

public enum VehicleCommand: Sendable, Equatable {
    case quick(QuickControl)
    case setClimate(temperature: Double, mode: CabinMode)
    case setChargeLimit(Double)
    case setCharging(Bool)
    public var title: String {
        switch self {
        case .quick(let control): control.title
        case .setClimate: "应用空调设置"
        case .setChargeLimit: "应用充电上限"
        case .setCharging(let active): active ? "开始充电" : "暂停充电"
        }
    }
}

public enum ServiceError: Error, LocalizedError, Sendable, Equatable {
    case offline, unsupported, unauthorized, unavailable, busy, invalidValue
    public var errorDescription: String? {
        switch self {
        case .offline: "车辆当前不在线。请先在车内或官方 App 中使车辆在线。"
        case .unsupported: "当前车辆或账号不支持此功能。"
        case .unauthorized: "授权已失效，需要重新连接账号。"
        case .unavailable: "服务暂时不可用，请稍后重试。"
        case .busy: "有操作正在执行，请等待车辆反馈。"
        case .invalidValue: "设置值超出允许范围。"
        }
    }
}

public enum DemoScenario: String, CaseIterable, Identifiable, Sendable {
    case normal, empty, asleep, offline, error, expired, missingData
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .normal: "正常数据"
        case .empty: "无历史记录"
        case .asleep: "车辆休眠"
        case .offline: "车辆离线"
        case .error: "服务错误"
        case .expired: "授权失效"
        case .missingData: "字段缺失"
        }
    }
}
