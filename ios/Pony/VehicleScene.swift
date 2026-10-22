import SwiftUI
import RealityKit
import ImageIO
import Combine
import PonyCore

enum VehicleCamera: String, CaseIterable, Identifiable {
    case exterior = "外观", overhead = "控制", cabin = "座舱"
    var id: String { rawValue }
}

/// Local, non-AR scene: no camera permission, network, or vehicle commands.
struct VehicleScene: UIViewRepresentable {
    let vehicle: VehicleSnapshot
    let camera: VehicleCamera
    let dark: Bool
    let animate: Bool
    let rotation: Float
    var grayStudy = false
    var darkStudy = false

    func makeCoordinator() -> VehicleSceneController { VehicleSceneController() }
    func makeUIView(context: Context) -> ARView { context.coordinator.makeView() }
    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.update(vehicle, camera: camera, dark: dark, animate: animate, rotation: rotation, grayStudy: grayStudy, darkStudy: darkStudy)
    }
    static func dismantleUIView(_ uiView: ARView, coordinator: VehicleSceneController) { coordinator.stop() }
}

@MainActor
final class VehicleSceneController {
    private let anchor = AnchorEntity(world: .zero)
    private let car = Entity()
    private let exteriorStudy = Entity()
    private var studyPaint: [ModelEntity] = []
    private var studyIsGray = false
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
    private var previousRotation: Float?
    private var cameraStart = Transform()
    private var cameraTarget = Transform()
    private var transition = VehicleTransition()
    private var shellStart: Float = 1
    private var shellOpacity: Float = 1
    private var shellTarget: Float = 1
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
        anchor.addChild(exteriorStudy)
        buildExteriorStudy()
        installStudyEnvironment(on: result)
        result.scene.addAnchor(anchor)
        return result
    }

    func stop() { subscription?.cancel(); subscription = nil }

    func update(_ vehicle: VehicleSnapshot, camera mode: VehicleCamera, dark: Bool, animate: Bool, rotation: Float, grayStudy: Bool = false, darkStudy: Bool = false) {
        self.animate = animate
        // A deliberately fixed closed exterior study, never used to imply opening articulation.
        let studyVisible = mode != .cabin && !vehicle.body.openings.values.contains(true) && vehicle.body.windowsVented != true
        if exteriorStudy.isEnabled != studyVisible { previousCamera = nil }
        exteriorStudy.isEnabled = studyVisible
        car.isEnabled = !studyVisible
        if studyIsGray != grayStudy {
            studyIsGray = grayStudy
            for panel in studyPaint { panel.model?.materials = [Self.studyFinish(gray: grayStudy)] }
        }
        cabinActive = mode == .cabin
        airActive = vehicle.cabinMode != .off && vehicle.canControl(at: .now)
        view?.environment.background = .color((dark || darkStudy) ? UIColor(red: 0.090, green: 0.094, blue: 0.098, alpha: 1) : UIColor(red: 0.925, green: 0.935, blue: 0.945, alpha: 1))
        if previousCamera != mode || (mode == .exterior && previousRotation != rotation) {
            let pose = Entity()
            switch mode {
            case .cabin:
                pose.look(at: [0, 0.55, 0], from: [0, 6.4, 2.0], relativeTo: nil)
            case .overhead:
                pose.look(at: [0, 0.65, 0], from: [0, 8.8, 0.01], relativeTo: nil)
            case .exterior:
                // Orbit the camera, not the vehicle: returning restores the user's exterior angle.
                let orbit = simd_quatf(angle: studyVisible ? 0 : -rotation, axis: [0, 1, 0])
                pose.look(at: [0, 0.65, 0], from: orbit.act(studyVisible ? [-4.9, 3.65, -4.7] : [-4.9, 3.5, -6.1]), relativeTo: nil)
            }
            // We own the rendered transform each frame; interruption starts exactly here.
            cameraStart = camera.transform
            cameraTarget = pose.transform
            shellStart = shellOpacity
            shellTarget = mode == .cabin ? 0 : 1
            transition.restart(animated: previousCamera != nil && animate)
            previousCamera = mode
            previousRotation = rotation
            renderTransition()
        }
        if !animate {
            transition.finish()
            renderTransition()
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
        if animate && (airActive || !transition.isComplete) && subscription == nil, let view {
            subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                MainActor.assumeIsolated { self?.advance(Float(event.deltaTime)) }
            }
        } else if !animate || (!airActive && transition.isComplete) { stop() }
        placeAir()
    }

    private func advance(_ delta: Float) {
        transition.advance(by: Double(min(delta, 0.05)))
        renderTransition()
        if airActive {
            phase = (phase + min(delta, 0.05) * 0.4).truncatingRemainder(dividingBy: 1)
            placeAir()
        }
        if transition.isComplete && !airActive { stop() }
    }

    private func renderTransition() {
        let t = Float(transition.progress)
        camera.transform = Transform(scale: .one,
            rotation: simd_slerp(cameraStart.rotation, cameraTarget.rotation, t),
            translation: cameraStart.translation + (cameraTarget.translation - cameraStart.translation) * t)
        shellOpacity = shellStart + (shellTarget - shellStart) * t
        // Fade the complete upper shell together, preserving door/window sensor transforms.
        for shell in [canopy] + windows {
            shell.components.set(OpacityComponent(opacity: shellOpacity))
            shell.isEnabled = shellOpacity > 0
        }
    }
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

    // MARK: - Closed exterior study (procedural approximation, not a production vehicle asset)
    private static func studyFinish(gray: Bool) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: gray ? UIColor(white: 0.43, alpha: 1) : UIColor(red: 0.018, green: 0.029, blue: 0.022, alpha: 1))
        material.metallic = .init(floatLiteral: gray ? 0 : 0.65)
        material.roughness = .init(floatLiteral: gray ? 0.62 : 0.27)
        material.clearcoat = .init(floatLiteral: gray ? 0 : 0.85)
        material.clearcoatRoughness = .init(floatLiteral: 0.22)
        material.faceCulling = .none
        return material
    }

    /// Cubic longitudinal stations keep hood, cowl, roof and rear quarters tangent-continuous.
    private static func station(_ z: Float, _ values: [(Float, Float)]) -> Float {
        let i = max(0, min(values.count - 2, (0..<(values.count - 1)).first { z <= values[$0 + 1].0 } ?? values.count - 2))
        let t = max(0, min(1, (z - values[i].0) / (values[i + 1].0 - values[i].0)))
        let before = max(0, i - 1), after = min(values.count - 1, i + 2)
        let span = values[i + 1].0 - values[i].0
        let m1 = (values[i + 1].1-values[before].1)/(values[i + 1].0-values[before].0)
        let m2 = (values[after].1-values[i].1)/(values[after].0-values[i].0)
        let t2 = t*t, t3 = t*t*t
        let a = (2*t3-3*t2+1)*values[i].1
        let b = (t3-2*t2+t)*span*m1
        let c = (-2*t3+3*t2)*values[i + 1].1
        let d = (t3-t2)*span*m2
        return a+b+c+d
    }

    /// Angle 0 is right rocker, pi/2 centerline and pi left rocker. Front is -Z.
    private static func skin(_ z: Float, _ angle: Float, lift: Float = 0) -> SIMD3<Float> {
        let width = station(z, [(-2.36,0.02),(-2.28,0.48),(-2.08,0.77),(-1.55,0.905),(-0.75,0.90),(0.5,0.90),(1.45,0.905),(2.10,0.78),(2.30,0.44),(2.36,0.02)])
        let crown = station(z, [(-2.36,0.48),(-2.18,0.71),(-1.55,0.85),(-1.05,0.92),(-0.50,1.30),(0.05,1.445),(0.60,1.43),(1.05,1.27),(1.55,0.93),(2.10,0.83),(2.36,0.56)])
        let cabin = max(0, crown - 0.92)
        let a = max(0, sin(angle))
        // Broad shoulders; narrower glasshouse. Not independent hood/roof boxes.
        let lateral = cos(angle)
        let x = width * (lateral < 0 ? -1 : 1) * pow(abs(lateral), 0.55) * (1 - 0.08 * cabin / 0.525 * a)
        let ramp = max(0, min(1, (a - 0.43) / 0.47))
        let roofBlend = ramp * ramp * (3 - 2 * ramp)
        let y = 0.26 + (crown - cabin - 0.26) * pow(a, 0.22) + cabin * roofBlend
        return [x, y + lift, z]
    }

    @discardableResult private func studySurface(_ name: String, u: Int = 100, v: Int = 40,
        material: PhysicallyBasedMaterial, painted: Bool = false,
        cutArches: Bool = false, point: (Float, Float) -> SIMD3<Float>) -> ModelEntity {
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], triangles: [UInt32] = []
        for i in 0...u { for j in 0...v { p.append(point(Float(i)/Float(u), Float(j)/Float(v))) } }
        n = Array(repeating: .zero, count: p.count)
        for i in 0..<u { for j in 0..<v {
            let a = i*(v+1)+j, b = a+v+1
            for tri in [[a,a+1,b],[a+1,b+1,b]] {
                let center = (p[tri[0]]+p[tri[1]]+p[tri[2]])/3
                let dz = min(abs(center.z + 1.43), abs(center.z - 1.43))
                if cutArches && abs(center.x) > 0.69 && dz < 0.375 && center.y < 0.35 + sqrt(max(0, 0.375*0.375 - dz*dz)) { continue }
                let normal = simd_cross(p[tri[1]]-p[tri[0]], p[tri[2]]-p[tri[0]])
                for k in tri { n[k] += normal; triangles.append(UInt32(k)) }
            }
        } }
        n = n.map { simd_length_squared($0) > 0.00000001 ? simd_normalize($0) : [0,1,0] }
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(p)
        descriptor.normals = MeshBuffers.Normals(n)
        descriptor.primitives = .triangles(triangles)
        let model: ModelEntity
        if let mesh = try? MeshResource.generate(from: [descriptor]) { model = ModelEntity(mesh: mesh, materials: [material]) }
        else { model = ModelEntity() }
        model.name = name; exteriorStudy.addChild(model)
        if painted { studyPaint.append(model) }
        return model
    }

    private func buildExteriorStudy() {
        exteriorStudy.name = "fixed_closed_exterior_study_not_production"
        let finish = Self.studyFinish(gray: false)
        var dark = PhysicallyBasedMaterial()
        dark.baseColor = .init(tint: UIColor(white: 0.025, alpha: 1))
        dark.roughness = .init(floatLiteral: 0.30); dark.faceCulling = .none
        var glazing = dark
        glazing.baseColor = .init(tint: UIColor(red: 0.035, green: 0.044, blue: 0.046, alpha: 1))
        glazing.roughness = .init(floatLiteral: 0.18)
        glazing.metallic = .init(floatLiteral: 0.22)
        studySurface("continuous_sedan_shell", u: 220, v: 96, material: finish, painted: true, cutArches: true) { u,v in
            Self.skin(-2.36 + 4.72*u, v * .pi)
        }
        // A connected windscreen, panoramic roof and backlight with a thin painted perimeter.
        studySurface("windscreen_roof_backlight", material: glazing) { u,v in
            let z = -1.01 + u*2.48
            let taper = sin(u * .pi)
            let half: Float = 0.57 + 0.035*taper
            return Self.skin(z, .pi/2 + (v*2-1)*half, lift: 0.009)
        }
        for side: Float in [-1,1] {
            studySurface("hood_panel_gap", u: 64, v: 2, material: dark) { u,v in
                let a: Float = 0.98 + (v-0.5)*0.005
                return Self.skin(-2.12+u*1.10,side > 0 ? a : .pi-a,lift: 0.004)
            }
        }
        var sideGlazing = glazing
        sideGlazing.baseColor = .init(tint: UIColor(red: 0.12, green: 0.13, blue: 0.135, alpha: 1))
        sideGlazing.roughness = .init(floatLiteral: 0.28)
        for sign: Float in [-1,1] {
            studySurface("side_window_2022", u: 84, v: 24, material: sideGlazing) { u,v in
                let z = -0.85 + u*2.14
                let height = pow(max(0, sin(u * .pi)), 0.65)
                let angle: Float = 0.52 + v*0.48*height
                return Self.skin(z, sign > 0 ? angle : .pi-angle, lift: 0.009)
            }
            studySurface("black_b_pillar", u: 3, v: 24, material: dark) { u,v in
                let a: Float = 0.52 + v*0.47
                return Self.skin(0.22 + (u-0.5)*0.044, sign > 0 ? a : .pi-a, lift: 0.015)
            }
            for wheelZ: Float in [-1.43,1.43] {
                // The lip follows the cutout in the very same skin, not a separate box fender.
                studySurface("wheel_arch_lip", u: 70, v: 3, material: finish, painted: true) { u,v in
                    let t = u * .pi
                    let z = wheelZ + cos(t)*(0.376+v*0.014)
                    let y = 0.35 + sin(t)*(0.376+v*0.014)
                    var low: Float = 0, high: Float = .pi/2
                    for _ in 0..<14 {
                        let mid = (low+high)/2
                        if Self.skin(z,mid).y < y { low = mid } else { high = mid }
                    }
                    return Self.skin(z,sign > 0 ? (low+high)/2 : .pi-(low+high)/2,lift: 0.004)
                }
            }
            // Narrow actual panel gaps, not reflection marks.
            for z: Float in [-0.87,0.24,1.27] {
                studySurface("door_gap", u: 2, v: 24, material: dark) { u,v in
                    Self.skin(z + (u-0.5)*0.007, sign > 0 ? 0.08+v*0.25 : .pi-(0.08+v*0.25), lift: 0.004)
                }
            }
            for z: Float in [-0.02,0.99] {
                let handle = ModelEntity(mesh: .generateBox(size: [0.012,0.018,0.14], cornerRadius: 0.007), materials: [dark])
                handle.position = [sign*0.884,0.875,z]; exteriorStudy.addChild(handle)
            }
            let stalk = ModelEntity(mesh: .generateBox(size: [0.13,0.035,0.07], cornerRadius: 0.015), materials: [dark])
            stalk.position = [sign*0.79,1.00,-0.62]; exteriorStudy.addChild(stalk)
            let mirror = ModelEntity(mesh: .generateSphere(radius: 1), materials: [finish])
            mirror.scale = [0.15,0.063,0.115]; mirror.position = [sign*0.88,1.025,-0.62]
            exteriorStudy.addChild(mirror); studyPaint.append(mirror)
            // Pre-refresh lamps are broad tapered teardrops swept back over the front fenders.
            var lens = glazing
            lens.baseColor = .init(tint: UIColor(white: 0.47, alpha: 1)); lens.metallic = .init(floatLiteral: 0.45)
            studySurface("2022_teardrop_headlamp", u: 40, v: 20, material: lens) { u,v in
                let z = -2.19 + u*0.63
                let span = 0.10 + 0.31*pow(sin(u * .pi),0.8)
                let a = 0.63 + (v-0.5)*span
                return Self.skin(z, sign > 0 ? a : .pi-a, lift: 0.012)
            }
            var red = dark; red.baseColor = .init(tint: UIColor(red: 0.38,green: 0.012,blue: 0.015,alpha: 1))
            studySurface("rear_lamp", u: 24, v: 8, material: red) { u,v in
                Self.skin(1.94+u*0.30, sign > 0 ? 0.48+v*0.12 : .pi-(0.48+v*0.12), lift: 0.008)
            }
            for z: Float in [-1.43,1.43] { studyWheel(sign: sign,z: z) }
        }
        studySurface("curved_lower_intake", u: 60, v: 8, material: dark) { u,v in
            let a: Float = 0.84 + u*1.46
            let p = Self.skin(-2.30+0.065*abs(u*2-1),a)
            return [p.x,0.335+v*0.055,p.z-0.012]
        }
        // No opaque proxy floor: the simulator cannot render grounded shadows reliably.
        // A soft grounding treatment remains a known visual gap for this study.

    }

    private func studyWheel(sign: Float, z: Float) {
        let tire = ModelEntity(mesh: .generateCylinder(height: 0.215,radius: 0.345),materials: [rubber])
        tire.position = [sign*0.815,0.35,z]
        tire.orientation = simd_quatf(angle: .pi/2,axis: [0,0,1]); exteriorStudy.addChild(tire)
        var gray = PhysicallyBasedMaterial()
        gray.baseColor = .init(tint: UIColor(white: 0.28,alpha: 1))
        gray.metallic = .init(floatLiteral: 0.65); gray.roughness = .init(floatLiteral: 0.43)
        let disc = ModelEntity(mesh: .generateCylinder(height: 0.018,radius: 0.267),materials: [gray])
        disc.position = [0,-sign*0.114,0]; tire.addChild(disc)
        for i in 0..<10 {
            let spoke = ModelEntity(mesh: .generateBox(size: [0.055,0.012,0.225],cornerRadius: 0.013), materials: [gray])
            let angle = Float(i)*2 * .pi/10
            spoke.position = [sin(angle)*0.12,-sign*0.129,cos(angle)*0.12]
            spoke.orientation = simd_quatf(angle: angle+0.16,axis: [0,1,0]); tire.addChild(spoke)
        }
        let hub = ModelEntity(mesh: .generateCylinder(height: 0.025,radius: 0.065),materials: [gray])
        hub.position = [0,-sign*0.13,0]; tire.addChild(hub)
    }

    /// Original analytic studio lighting, generated locally; never uses a user photograph.
    /// A Radiance RGBE panorama provides real broad PBR reflections instead of painted bands.
    private func installStudyEnvironment(on view: ARView) {
        let width = 256, height = 128
        var data = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y \(height) +X \(width)\n".utf8)
        for y in 0..<height { for x in 0..<width {
            let u = Float(x)/Float(width), v = Float(y)/Float(height)
            let key = exp(-pow((u-0.24)/0.13, 4)-pow((v-0.26)/0.12, 4))
            let fill = exp(-pow((u-0.73)/0.20, 4)-pow((v-0.35)/0.16, 4))
            let value: Float = 0.13 + 3.5*key + 1.5*fill
            var exponent: Int32 = 0
            let fraction = frexpf(value, &exponent)*256/value
            data.append(contentsOf: [UInt8(min(255,value*fraction)),UInt8(min(255,value*fraction)),UInt8(min(255,value*fraction)),UInt8(max(0,min(255,exponent+128)))])
        } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pony-original-softboxes.hdr")
        do {
            try data.write(to: url, options: .atomic)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            Task { @MainActor [weak view] in
                guard let resource = try? await EnvironmentResource(equirectangular: image) else { return }
                view?.environment.lighting.resource = resource
                view?.environment.lighting.intensityExponent = 0
            }
        } catch {
            // Directional key and point fill remain available if HDR decoding is unsupported.
        }
    }

}
