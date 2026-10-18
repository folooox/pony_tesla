import SwiftUI
import RealityKit
import Combine
import PonyCore

enum VehicleCamera: String, CaseIterable, Identifiable {
    case exterior = "外观", cabin = "座舱"
    var id: String { rawValue }
}

/// Local, non-AR scene: no camera permission, network, or vehicle commands.
struct VehicleScene: UIViewRepresentable {
    let vehicle: VehicleSnapshot
    let camera: VehicleCamera
    let dark: Bool
    let animate: Bool
    let rotation: Float

    func makeCoordinator() -> VehicleSceneController { VehicleSceneController() }
    func makeUIView(context: Context) -> ARView { context.coordinator.makeView() }
    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.update(vehicle, camera: camera, dark: dark, animate: animate, rotation: rotation)
    }
    static func dismantleUIView(_ uiView: ARView, coordinator: VehicleSceneController) { coordinator.stop() }
}

@MainActor
final class VehicleSceneController {
    private let anchor = AnchorEntity(world: .zero)
    private let car = Entity()
    private let camera = PerspectiveCamera()
    private let canopy = Entity()
    private var joints: [VehicleOpening: Entity] = [:]
    private var seats: [SeatPosition: ModelEntity] = [:]
    private var steering: ModelEntity?
    private var windows: [Entity] = []
    private var air: [ModelEntity] = []
    private var subscription: Cancellable?
    private weak var view: ARView?
    private var previous: VehicleSnapshot?
    private var previousCamera: VehicleCamera?
    private var phase: Float = 0
    private var cabinActive = false
    private var airActive = false
    private var animate = false
    private let paint = SimpleMaterial(color: UIColor(red: 0.72, green: 0.75, blue: 0.77, alpha: 1), roughness: 0.42, isMetallic: true)
    private let rubber = SimpleMaterial(color: UIColor(white: 0.045, alpha: 1), roughness: 0.9, isMetallic: false)
    private let trim = SimpleMaterial(color: UIColor(white: 0.10, alpha: 1), roughness: 0.45, isMetallic: true)
    private let glass = SimpleMaterial(color: UIColor(red: 0.065, green: 0.11, blue: 0.145, alpha: 1), roughness: 0.12, isMetallic: true)
    private let leather = SimpleMaterial(color: UIColor(white: 0.16, alpha: 1), roughness: 0.85, isMetallic: false)
    private let alloy = SimpleMaterial(color: UIColor(white: 0.63, alpha: 1), roughness: 0.22, isMetallic: true)

    func makeView() -> ARView {
        let result = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        result.isUserInteractionEnabled = false
        result.environment.background = .color(.clear)
        result.isOpaque = false
        result.renderOptions.insert(.disableMotionBlur)
        result.renderOptions.insert(.disableDepthOfField)
        #if targetEnvironment(simulator)
        // The simulator GPU rejects RealityKit's programmable shadow blending pipeline.
        result.renderOptions.insert(.disableGroundingShadows)
        #endif
        view = result
        anchor.addChild(car)
        anchor.addChild(camera)
        camera.camera.fieldOfViewInDegrees = 34
        let key = DirectionalLight()
        key.light.intensity = 2600
        key.light.color = UIColor(white: 1, alpha: 1)
        #if !targetEnvironment(simulator)
        key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 12, depthBias: 1)
        #endif
        key.look(at: .zero, from: [-3, 7, -4], relativeTo: nil)
        anchor.addChild(key)
        let fill = PointLight()
        fill.light.intensity = 1600
        fill.light.attenuationRadius = 12
        fill.position = [4, 3, 1]
        anchor.addChild(fill)
        buildCar()
        result.scene.addAnchor(anchor)
        return result
    }

    func stop() { subscription?.cancel(); subscription = nil }

    func update(_ vehicle: VehicleSnapshot, camera mode: VehicleCamera, dark: Bool, animate: Bool, rotation: Float) {
        self.animate = animate
        cabinActive = mode == .cabin
        airActive = vehicle.cabinMode != .off && vehicle.canControl(at: .now)
        car.orientation = simd_quatf(angle: rotation, axis: [0, 1, 0])
        view?.environment.background = .color(dark ? UIColor(red: 0.10, green: 0.115, blue: 0.135, alpha: 1) : UIColor(red: 0.925, green: 0.935, blue: 0.945, alpha: 1))
        if previousCamera != mode {
            var target = Transform()
            let pose = Entity()
            if mode == .cabin { pose.look(at: [0, 0.55, 0], from: [0, 6.4, 2.0], relativeTo: nil) }
            else { pose.look(at: [0, 0.65, 0], from: [-4.6, 2.8, -5.7], relativeTo: nil) }
            target = pose.transform
            camera.move(to: target, relativeTo: anchor, duration: previousCamera == nil || !animate ? 0 : 0.55, timingFunction: .easeInOut)
            canopy.isEnabled = mode == .exterior
            previousCamera = mode
        }
        if previous?.body != vehicle.body || previous?.cabinMode != vehicle.cabinMode {
            for (opening, joint) in joints {
                let open = vehicle.body.openings[opening] == true
                let angle: Float
                let axis: SIMD3<Float>
                switch opening {
                case .frunk: angle = open ? 0.70 : 0; axis = [1, 0, 0]
                case .trunk: angle = open ? -0.95 : 0; axis = [1, 0, 0]
                case .frontLeft, .rearLeft: angle = open ? -0.95 : 0; axis = [0, 1, 0]
                case .frontRight, .rearRight: angle = open ? 0.95 : 0; axis = [0, 1, 0]
                case .chargePort: angle = open ? -1.15 : 0; axis = [0, 0, 1]
                }
                var next = joint.transform
                next.rotation = simd_quatf(angle: angle, axis: axis)
                joint.move(to: next, relativeTo: car, duration: previous == nil || !animate ? 0 : 0.65, timingFunction: .easeInOut)
            }
            for (seat, model) in seats {
                let heat = vehicle.body.seatHeat[seat] ?? 0
                let material = heat > 0 ? SimpleMaterial(color: UIColor(red: 0.50 + Double(heat) * 0.13, green: 0.23, blue: 0.10, alpha: 1), roughness: 0.7, isMetallic: false) : leather
                model.model?.materials = [material]
                (model.children.first { $0.name == "backrest" } as? ModelEntity)?.model?.materials = [material]
            }
            steering?.model?.materials = [vehicle.body.steeringHeat ?? 0 > 0 ? SimpleMaterial(color: .systemOrange, roughness: 0.5, isMetallic: false) : trim]
            for window in windows { window.position.y = vehicle.body.windowsVented == true ? -0.10 : 0 }
            previous = vehicle
        }
        for particle in air { particle.isEnabled = airActive }
        // A stationary particle trail remains available with Reduce Motion enabled.
        if animate && airActive && subscription == nil, let view {
            subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                MainActor.assumeIsolated { self?.advance(Float(event.deltaTime)) }
            }
        } else if !animate || !airActive { stop() }
        placeAir()
    }

    private func advance(_ delta: Float) { phase = (phase + min(delta, 0.05) * 0.4).truncatingRemainder(dividingBy: 1); placeAir() }
    private func placeAir() {
        for (index, particle) in air.enumerated() {
            let t = (Float(index % 6) / 6 + phase).truncatingRemainder(dividingBy: 1)
            particle.position = [index < 6 ? -0.39 : 0.39, cabinActive ? 0.98 : 1.53 + sin(t * .pi) * 0.1, -0.85 + t * 1.65]
        }
    }

    private func buildCar() {
        car.name = "vehicle"
        // A replaceable procedural rig, intentionally not represented as a production asset.
        box("floor", [1.66, 0.10, 3.85], [0, 0.27, 0], rubber)
        for sign: Float in [-1, 1] {
            box("sill", [0.10, 0.14, 2.42], [sign * 0.86, 0.35, 0.02], paint)
            for z: Float in [-1.43, 1.43] { wheel(sign: sign, z: z) }
        }
        // Bumpers taper in plan view; wheel apertures are cut out of side surfaces.
        for (start, end) in [(Float(-2.32), Float(-0.92)), (Float(1.22), Float(2.32))] {
            surface("body", u: 56, v: 40, material: paint, parent: car, reverse: true, skip: { a, b, c in
                let p = (a + b + c) / 3
                let wheelZ: Float = p.z < 0 ? -1.43 : 1.43
                if p.y > 0.72 && abs(p.x) < Self.width(p.z) * 0.91 { return true }
                return abs(p.x) > 0.68 && abs(p.z - wheelZ) < 0.37 && p.y < 0.38 + sqrt(max(0, 0.37 * 0.37 - pow(p.z - wheelZ, 2)))
            }) { u, v in
                let z = start + (end - start) * u
                let a = v * 2 * Float.pi
                let w = Self.width(z)
                let x = w * copysign(pow(abs(cos(a)), 0.45), cos(a))
                let y: Float = 0.56 + 0.30 * copysign(pow(abs(sin(a)), 0.65), sin(a))
                // Upper middle is separately rigged as hood / deck.
                return [x, y - max(0, abs(z) - 1.85) * 0.20, z]
            }
        }
        for sign: Float in [-1, 1] {
            surface("bumper_end", u: 24, v: 12, material: paint, parent: car, reverse: sign > 0) { u, v in
                let x = (u * 2 - 1) * 0.67
                return [x, 0.30 + v * 0.47, sign * (2.30 - 0.08 * pow(abs(u * 2 - 1), 3))]
            }
        }
        box("frunk_cavity", [1.15, 0.14, 0.80], [0, 0.65, -1.50], rubber)
        box("trunk_cavity", [1.20, 0.14, 0.70], [0, 0.65, 1.69], rubber)
        let hood = joint(.frunk, at: [0, 0.88, -0.93])
        surface("hood", u: 22, v: 18, material: paint, parent: hood, reverse: true) { u, v in
            let z = -0.01 - u * 1.36
            let x = (v * 2 - 1) * Self.width(z - 0.93) * 0.91
            return [x, -0.02 - u * 0.10 + 0.045 * (1 - pow(v * 2 - 1, 2)), z]
        }
        let trunk = joint(.trunk, at: [0, 0.89, 1.24])
        surface("deck", u: 16, v: 16, material: paint, parent: trunk) { u, v in
            let z = u * 1.06
            return [(v * 2 - 1) * Self.width(z + 1.24) * 0.92, -u * 0.09 + 0.025 * sin(v * .pi), z]
        }
        for sign: Float in [-1, 1] {
            makeDoor(sign: sign, front: true)
            makeDoor(sign: sign, front: false)
            box("headlamp", [0.42, 0.055, 0.09], [sign * 0.56, 0.75, -2.16], SimpleMaterial(color: UIColor(white: 0.95, alpha: 1), roughness: 0.15, isMetallic: false))
            box("taillamp", [0.45, 0.06, 0.07], [sign * 0.56, 0.77, 2.18], SimpleMaterial(color: UIColor(red: 0.55, green: 0.025, blue: 0.025, alpha: 1), roughness: 0.18, isMetallic: false))
            box("mirror", [0.22, 0.11, 0.22], [sign * 1.00, 1.04, -0.65], paint)
        }
        box("lower_intake", [1.19, 0.065, 0.06], [0, 0.40, -2.30], rubber)
        box("rear_diffuser", [1.45, 0.10, 0.08], [0, 0.33, 2.27], trim)
        car.addChild(canopy)
        surface("glass_roof", u: 34, v: 24, material: glass, parent: canopy) { u, v in
            let z = -1.02 + u * 2.47
            let arch = pow(max(0, sin(u * .pi)), 0.72)
            let x = (v * 2 - 1) * (0.84 - 0.17 * arch)
            return [x, 0.97 + 0.45 * arch + 0.045 * (1 - pow(v * 2 - 1, 2)), z]
        }
        for sign: Float in [-1, 1] {
            surface("roof_rail", u: 36, v: 2, material: paint, parent: canopy) { u, v in
                let arch = pow(max(0, sin(u * .pi)), 0.72)
                return [sign * (0.84 - 0.17 * arch + v * 0.028), 0.97 + 0.45 * arch, -1.02 + u * 2.47]
            }
        }
        let port = joint(.chargePort, at: [-0.88, 0.78, 1.95])
        box("charge_port", [0.035, 0.13, 0.19], [0, 0, 0], trim, parent: port)
        buildInterior()
        for _ in 0..<12 {
            let particle = ModelEntity(mesh: .generateBox(size: [0.016, 0.012, 0.15], cornerRadius: 0.006), materials: [UnlitMaterial(color: UIColor(red: 0.27, green: 0.68, blue: 0.89, alpha: 1))])
            particle.isEnabled = false
            car.addChild(particle); air.append(particle)
        }
    }

    private func makeDoor(sign: Float, front: Bool) {
        let opening: VehicleOpening = front ? (sign < 0 ? .frontLeft : .frontRight) : (sign < 0 ? .rearLeft : .rearRight)
        let zStart: Float = front ? -0.91 : 0.23
        let length: Float = front ? 1.12 : 0.97
        let root = joint(opening, at: [sign * 0.87, 0.42, zStart])
        surface("door_panel", u: 14, v: 12, material: paint, parent: root, reverse: sign > 0) { u, v in
            [sign * (0.025 * sin(v * .pi) - 0.04 * pow(1 - v, 2)), v * 0.56, u * length]
        }
        box("door_lining", [0.055, 0.42, length - 0.05], [-sign * 0.06, 0.29, length / 2], leather, parent: root)
        box("handle", [0.012, 0.025, 0.15], [sign * 0.03, 0.45, length * 0.80], trim, parent: root)
        let window = Entity(); root.addChild(window); windows.append(window)
        surface("side_glass", u: 18, v: 10, material: glass, parent: window, reverse: sign > 0) { u, v in
            let z = zStart + u * length
            let t = (z + 1.02) / 2.47
            let arch = pow(max(0, sin(t * .pi)), 0.72)
            return [-sign * 0.20 * arch * v, 0.56 + 0.44 * arch * v, u * length]
        }
        box("b_pillar", [0.035, 0.32, 0.045], [-sign * 0.08, 0.70, front ? length : 0], trim, parent: window)
    }

    private func buildInterior() {
        box("dashboard", [1.54, 0.17, 0.27], [0, 0.91, -0.78], leather)
        box("wood_trim_2022", [1.50, 0.045, 0.038], [0, 0.97, -0.625], SimpleMaterial(color: UIColor(red: 0.43, green: 0.29, blue: 0.18, alpha: 1), roughness: 0.75, isMetallic: false))
        let screen = box("screen", [0.35, 0.22, 0.025], [0, 1.05, -0.57], trim)
        screen.orientation = simd_quatf(angle: -0.18, axis: [1, 0, 0])
        box("display", [0.31, 0.18, 0.006], [0, 0, 0.017], SimpleMaterial(color: UIColor(red: 0.51, green: 0.60, blue: 0.64, alpha: 1), roughness: 0.5, isMetallic: false), parent: screen)
        box("console", [0.28, 0.25, 0.93], [0, 0.54, -0.01], trim)
        box("armrest", [0.27, 0.065, 0.36], [0, 0.70, 0.30], leather)
        for seat in SeatPosition.allCases {
            let front = seat == .frontLeft || seat == .frontRight
            let x: Float = seat == .rearCenter ? 0 : (seat == .frontLeft || seat == .rearLeft ? -0.44 : 0.44)
            let z: Float = front ? -0.10 : 0.94
            let width: Float = front ? 0.49 : 0.40
            let cushion = box("seat_\(seat.rawValue)", [width, 0.14, 0.48], [x, 0.48, z], leather)
            let back = box("backrest", [width, 0.53, 0.14], [0, 0.26, 0.22], leather, parent: cushion)
            back.orientation = simd_quatf(angle: 0.12, axis: [1, 0, 0])
            box("headrest", [width * 0.56, 0.19, 0.15], [0, 0.60, 0.25], leather, parent: cushion)
            seats[seat] = cushion
        }
        let wheel = surface("steering", u: 40, v: 10, material: trim, parent: car) { u, v in
            let a = u * 2 * Float.pi, b = v * 2 * Float.pi
            let radius = 0.16 + 0.021 * cos(b)
            return [-0.44 + radius * cos(a), 0.97 + radius * sin(a), -0.49 + 0.021 * sin(b)]
        }
        steering = wheel
        box("steering_hub", [0.19, 0.065, 0.035], [-0.44, 0.97, -0.48], trim)
    }

    private func wheel(sign: Float, z: Float) {
        let tire = ModelEntity(mesh: .generateCylinder(height: 0.22, radius: 0.34), materials: [rubber])
        tire.position = [sign * 0.82, 0.35, z]
        tire.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        car.addChild(tire)
        let rim = ModelEntity(mesh: .generateCylinder(height: 0.015, radius: 0.255), materials: [trim])
        rim.position = [0, -sign * 0.115, 0]; tire.addChild(rim)
        for i in 0..<5 {
            let spoke = box("aero_spoke", [0.09, 0.018, 0.41], [0, -sign * 0.13, 0], alloy, parent: tire)
            spoke.orientation = simd_quatf(angle: Float(i) * .pi * 2 / 5, axis: [0, 1, 0])
        }
    }

    private func joint(_ opening: VehicleOpening, at position: SIMD3<Float>) -> Entity {
        let entity = Entity(); entity.name = "hinge_\(opening.rawValue)"; entity.position = position
        car.addChild(entity); joints[opening] = entity; return entity
    }
    @discardableResult private func box(_ name: String, _ size: SIMD3<Float>, _ position: SIMD3<Float>, _ material: SimpleMaterial, parent: Entity? = nil) -> ModelEntity {
        let model = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(size.x, size.y, size.z) * 0.22), materials: [material])
        model.name = name; model.position = position; (parent ?? car).addChild(model); return model
    }
    private static func width(_ z: Float) -> Float { 0.91 - 0.25 * pow(max(0, (abs(z) - 1.60) / 0.74), 1.6) }

    @discardableResult private func surface(_ name: String, u: Int, v: Int, material: SimpleMaterial, parent: Entity, reverse: Bool = false,
        skip: ((SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Bool)? = nil,
        point: (Float, Float) -> SIMD3<Float>) -> ModelEntity {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0...u { for j in 0...v { positions.append(point(Float(i) / Float(u), Float(j) / Float(v))) } }
        normals = Array(repeating: .zero, count: positions.count)
        for i in 0..<u { for j in 0..<v {
            let a = i * (v + 1) + j, b = a + v + 1
            for triangle in [[a, b, a + 1], [a + 1, b, b + 1]] {
                let p = positions[triangle[0]], q = positions[triangle[1]], r = positions[triangle[2]]
                if skip?(p, q, r) == true { continue }
                let normal = simd_cross(q - p, r - p) * (reverse ? -1 : 1)
                for index in triangle { normals[index] += normal; indices.append(UInt32(index)) }
            }
        } }
        normals = normals.map { simd_length_squared($0) > 0.0000001 ? simd_normalize($0) : [0, 1, 0] }
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        var doubleSided = material
        doubleSided.faceCulling = .none
        // Generated geometry is deterministic; leave an empty node if an SDK rejects it.
        let model: ModelEntity
        if let mesh = try? MeshResource.generate(from: [descriptor]) { model = ModelEntity(mesh: mesh, materials: [doubleSided]) }
        else { model = ModelEntity() }
        model.name = name; parent.addChild(model); return model
    }
}
