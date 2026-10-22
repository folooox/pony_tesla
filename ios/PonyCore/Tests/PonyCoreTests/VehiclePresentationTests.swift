import Foundation
import Testing
@testable import PonyCore

private let presentationNow = Date(timeIntervalSince1970: 1_790_000_000)

@Test func absentBodyReadingsRemainUnknown() {
    let body = VehicleBodyState()
    #expect(body.unknownOpenings)
    #expect(body.openings[.frontLeft] == nil)
    #expect(body.seatHeat[.frontLeft] == nil)
    #expect(body.heatedSeats.isEmpty)
}

@Test func demoOpeningsAreIndependentAndUnlockDoesNotOpenDoors() async throws {
    let service = DemoVehicleService(now: presentationNow, latency: .zero)
    let unlocked = try await service.execute(.quick(.unlock), now: presentationNow)
    #expect(unlocked.body.openLabels.isEmpty)
    let opened = try await service.execute(.simulateOpening(.frontLeft, true), now: presentationNow)
    #expect(opened.body.openings[.frontLeft] == true)
    #expect(opened.body.openings[.rearLeft] == false)
    #expect(opened.body.openLabels == ["左前门"])
    let trunk = try await service.execute(.quick(.trunk), now: presentationNow)
    #expect(trunk.body.openings[.trunk] == true)
    #expect(trunk.body.openings[.frontLeft] == true)
    let closed = try await service.execute(.quick(.trunk), now: presentationNow)
    #expect(closed.body.openings[.trunk] == false)
}

@Test func frunkCommandNeverPretendsToPowerClose() async throws {
    let service = DemoVehicleService(now: presentationNow, latency: .zero)
    _ = try await service.execute(.quick(.frunk), now: presentationNow)
    let again = try await service.execute(.quick(.frunk), now: presentationNow)
    #expect(again.body.openings[.frunk] == true)
    let manuallyClosed = try await service.execute(.simulateOpening(.frunk, false), now: presentationNow)
    #expect(manuallyClosed.body.openings[.frunk] == false)
}

@Test func seatHeatValidatesCapabilityAndRangeWithoutChangingOtherSeats() async throws {
    let service = DemoVehicleService(now: presentationNow, latency: .zero)
    let heated = try await service.execute(.setSeatHeat(.rearRight, 3), now: presentationNow)
    #expect(heated.body.seatHeat[.rearRight] == 3)
    #expect(heated.body.seatHeat[.frontLeft] == 0)
    await #expect(throws: ServiceError.invalidValue) { try await service.execute(.setSeatHeat(.rearRight, 4), now: presentationNow) }
    #expect(try await service.dashboard(now: presentationNow).vehicle.body.seatHeat[.rearRight] == 3)
    let missing = DemoVehicleService(scenario: .missingData, now: presentationNow, latency: .zero)
    await #expect(throws: ServiceError.unsupported) { try await missing.execute(.setSeatHeat(.frontLeft, 1), now: presentationNow) }
    await #expect(throws: ServiceError.unsupported) { try await missing.execute(.setSteeringHeat(1), now: presentationNow) }
}

@Test func offlineCannotInjectBodyChanges() async throws {
    let service = DemoVehicleService(scenario: .offline, now: presentationNow, latency: .zero)
    await #expect(throws: ServiceError.offline) { try await service.execute(.simulateOpening(.frunk, true), now: presentationNow) }
    #expect(try await service.dashboard(now: presentationNow).vehicle.body.openings[.frunk] == false)
}

@Test func presentationTransitionClampsAndEases() {
    var motion = VehicleTransition()
    #expect(motion.isComplete)
    motion.restart(animated: true)
    #expect(motion.progress == 0)
    motion.advance(by: 0.275)
    #expect(abs(motion.progress - 0.5) < 0.0001)
    motion.advance(by: 10)
    #expect(motion.progress == 1)
    #expect(motion.isComplete)
}

@Test func presentationRetargetAndReduceMotion() {
    var motion = VehicleTransition()
    motion.restart(animated: true)
    motion.advance(by: 0.2)
    #expect(motion.progress > 0 && motion.progress < 1)
    motion.restart(animated: true)
    #expect(motion.progress == 0)
    motion.advance(by: -1)
    #expect(motion.progress == 0)
    motion.finish()
    #expect(motion.progress == 1)
    motion.restart(animated: false)
    #expect(motion.isComplete)
}

@Test func fixedArtworkDemoUsesExplicitStableStyle() async throws {
    let service = DemoVehicleService(now: presentationNow, latency: .zero)
    let vehicle = try await service.dashboard(now: presentationNow).vehicle
    #expect(vehicle.vehicleStyleID == "model3_cn_2022")
    #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: .homeClosed) == "VehicleModel3CN2022HomeClosed")
    let style = try #require(VehicleArtworkCatalog.style(for: vehicle.vehicleStyleID))
    #expect(style.assetVersion == "static-home-v2")
    #expect(style.canvasWidth == 1536 && style.canvasHeight == 1024)
    #expect(style.vehicleBounds.minX == 104 && style.vehicleBounds.maxY == 937)
    #expect(style.hasAlpha)
    #expect(style.lampAnchors.isEmpty)
    #expect(style.supportedStates == ["closed"])
}

@Test func fixedArtworkNeverInfersStyleFromDisplayName() {
    var vehicle = VehicleSnapshot(now: presentationNow)
    vehicle.body = .demo
    for name in ["我的 Model 3", "MODEL 3", "model3_cn_2022", "Model Y"] {
        vehicle.name = name
        #expect(vehicle.vehicleStyleID == nil)
        #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: .homeClosed) == nil)
    }
    for unknownID in ["model_y", "model3_cn_2024", "", "MODEL3_CN_2022"] {
        vehicle.vehicleStyleID = unknownID
        vehicle.name = "我的 Model 3"
        #expect(VehicleArtworkCatalog.style(for: unknownID) == nil)
        for slot in VehicleArtworkSlot.allCases {
            #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: slot) == nil)
        }
    }
    vehicle.vehicleStyleID = VehicleArtworkCatalog.demoStyleID
    vehicle.name = "任意昵称"
    #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: .homeClosed) != nil)
}

@Test func fixedArtworkMissingSlotsNeverReuseExterior() throws {
    var vehicle = VehicleSnapshot(now: presentationNow, vehicleStyleID: VehicleArtworkCatalog.demoStyleID)
    vehicle.body = .demo
    let style = try #require(VehicleArtworkCatalog.style(for: vehicle.vehicleStyleID))
    for slot in [VehicleArtworkSlot.homeLamps, .controlTop, .cabinTop] {
        #expect(style.slots[slot]?.support == .unavailable)
        #expect(style.slots[slot]?.assetName == nil)
        #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: slot) == nil)
    }
}

@Test func fixedArtworkRequiresEveryOpeningAndWindowKnownClosed() {
    var vehicle = VehicleSnapshot(now: presentationNow, vehicleStyleID: VehicleArtworkCatalog.demoStyleID)
    #expect(!vehicle.body.supportsClosedArtwork)
    #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: .homeClosed) == nil)
    for opening in VehicleOpening.allCases {
        vehicle.body = .demo
        vehicle.body.openings[opening] = true
        #expect(!vehicle.body.supportsClosedArtwork)
        #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: .homeClosed) == nil)
        vehicle.body.openings[opening] = nil
        #expect(!vehicle.body.supportsClosedArtwork)
        #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: .homeClosed) == nil)
    }
    vehicle.body = .demo
    vehicle.body.windowsVented = true
    #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: .homeClosed) == nil)
    vehicle.body.windowsVented = nil
    #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: .homeClosed) == nil)
    vehicle.body.windowsVented = false
    #expect(vehicle.body.supportsClosedArtwork)
    #expect(VehicleArtworkCatalog.assetName(for: vehicle, slot: .homeClosed) != nil)
}
