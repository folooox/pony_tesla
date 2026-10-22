import Foundation
import Testing
@testable import PonyCore

struct FeatureStatusPresentationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyConfirmedOnAppearsInStableOrder() {
        let p = FeatureStatusPresentation(readings: [.charging: .on, .sentry: .on, .valet: .unknown, .climate: .off], fetchedAt: now, online: true, now: now)
        #expect(p.current.map(\.feature) == [.sentry, .charging])
        #expect(p.previous.isEmpty)
        #expect(p.current[0].title == "哨兵模式已开启")
        #expect(p.current[1].title == "正在充电")
    }
    @Test func allOffAndUnknownDoNotInventActiveCards() {
        let p = FeatureStatusPresentation(readings: [.valet: .unknown, .sentry: .off, .climate: .unknown], fetchedAt: now, online: true, now: now)
        #expect(p.current.isEmpty && p.previous.isEmpty)
    }
    @Test func staleOfflineAndFutureUsePreviousNotCurrent() {
        for (date, online) in [(now.addingTimeInterval(-120), true), (now, false), (now.addingTimeInterval(1), true)] {
            let p = FeatureStatusPresentation(readings: [.sentry: .on], fetchedAt: date, online: online, now: now)
            #expect(p.current.isEmpty)
            #expect(p.previous.count == 1)
            #expect(p.previous.first?.title == "哨兵模式")
            #expect(p.previous.first?.cachedStatus == "上次状态：已开启")
            #expect(p.previous.first?.timestamp == date)
        }
    }
    @Test func justBeforeFreshnessBoundaryIsCurrent() {
        let p = FeatureStatusPresentation(readings: [.sentry: .on], fetchedAt: now.addingTimeInterval(-119.9), online: true, now: now)
        #expect(p.current.count == 1 && p.previous.isEmpty)
    }
    @Test func demoAdapterDoesNotInventValetOrUnknownSeats() {
        var v = VehicleSnapshot(now: now)
        v.sentry = nil
        let readings = FeatureStatusPresentation.readings(from: v)
        #expect(readings[.valet] == .unknown)
        #expect(readings[.sentry] == .unknown)
        #expect(readings[.seats] == .unknown)
    }
    @Test func specialClimateModesProduceOneClimateCard() {
        var v = VehicleSnapshot(now: now)
        v.charging = false
        for mode in [CabinMode.normal, .dog, .camp, .defrost] {
            v.cabinMode = mode
            let p = FeatureStatusPresentation(vehicle: v, now: now)
            #expect(p.current.count == 1)
        }
        v.cabinMode = .off
        #expect(FeatureStatusPresentation(vehicle: v, now: now).current.isEmpty)
    }
    @Test func currentOnChangesOnlyWhenSnapshotChanges() {
        let on = FeatureStatusPresentation(readings: [.sentry: .on], fetchedAt: now, online: true, now: now)
        let pending = CommandStatusPresentation(commandTitle: "关闭哨兵模式", phase: .pending)
        #expect(pending.title == "正在处理")
        #expect(on.current.count == 1)
        let off = FeatureStatusPresentation(readings: [.sentry: .off], fetchedAt: now, online: true, now: now)
        #expect(off.current.isEmpty)
    }
    @Test func unknownOutcomeNotRejectedAndEventsNeverBecomeFeatures() {
        #expect(CommandStatusPresentation(commandTitle: "闪灯", phase: .unknown).title == "结果未知")
        #expect(CommandStatusPresentation(commandTitle: "鸣笛", phase: .rejected).title == "操作被拒绝")
        #expect(!VehicleFeature.allCases.map(\.rawValue).contains("horn"))
        #expect(!VehicleFeature.allCases.map(\.rawValue).contains("lights"))
        #expect(VehicleFeature.valet.title == "酒保模式")
    }
}
