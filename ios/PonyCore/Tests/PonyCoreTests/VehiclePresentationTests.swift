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
