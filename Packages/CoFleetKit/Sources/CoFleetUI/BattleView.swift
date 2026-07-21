import CoFleetCore
import SwiftUI

#if !os(watchOS)
import SceneKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#endif

public struct CoFleetBattleView: View {
    public var projects: [CoFleetProject]
    public var hosts: [CoFleetHostInfo]

    public init(projects: [CoFleetProject], hosts: [CoFleetHostInfo]) {
        self.projects = projects
        self.hosts = hosts
    }

    public var body: some View {
        #if os(watchOS)
        CoFleetWatchBattleView(projects: projects)
        #else
        ZStack(alignment: .top) {
            SceneView(
                scene: makeScene(),
                pointOfView: nil,
                options: [.allowsCameraControl, .autoenablesDefaultLighting]
            )
            .ignoresSafeArea()

            HStack(spacing: 10) {
                ForEach(projects.prefix(3)) { project in
                    battleStatus(project)
                }
            }
            .padding(14)
        }
        .background(CoFleetTheme.background)
        #endif
    }

    #if !os(watchOS)
    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColorLike.background

        let floor = SCNFloor()
        floor.reflectivity = 0.08
        floor.firstMaterial?.diffuse.contents = NSColorLike.floor
        floor.firstMaterial?.roughness.contents = 0.82
        let floorNode = SCNNode(geometry: floor)
        scene.rootNode.addChildNode(floorNode)

        for index in 0..<8 {
            let line = SCNBox(width: 0.025, height: 0.01, length: 12, chamferRadius: 0)
            line.firstMaterial?.diffuse.contents = NSColorLike.grid
            let node = SCNNode(geometry: line)
            node.position = SCNVector3(Float(index - 4) * 1.5, 0.012, 0)
            scene.rootNode.addChildNode(node)
        }

        for (index, project) in projects.prefix(4).enumerated() {
            let pet = SCNSphere(radius: 0.42)
            pet.segmentCount = 24
            pet.firstMaterial?.diffuse.contents = NSColorLike.pet(index: index)
            pet.firstMaterial?.roughness.contents = 0.42
            let petNode = SCNNode(geometry: pet)
            petNode.name = project.displayName
            petNode.position = SCNVector3(Float(index) * 1.4 - 2.1, 0.46, Float(index % 2) * 1.3 - 0.7)
            scene.rootNode.addChildNode(petNode)

            let bounce = SCNAction.sequence([
                .moveBy(x: 0, y: 0.12, z: 0, duration: 0.55),
                .moveBy(x: 0, y: -0.12, z: 0, duration: 0.55),
            ])
            petNode.runAction(.repeatForever(bounce))
        }

        let camera = SCNCamera()
        camera.fieldOfView = 47
        camera.wantsDepthOfField = true
        camera.focusDistance = 8
        camera.fStop = 4.2
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 6.4, 8.8)
        cameraNode.eulerAngles = SCNVector3(-0.56, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        let light = SCNLight()
        light.type = .area
        light.intensity = 850
        light.castsShadow = true
        light.shadowRadius = 7
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(-2, 7, 3)
        scene.rootNode.addChildNode(lightNode)
        return scene
    }

    private func battleStatus(_ project: CoFleetProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.displayName.uppercased())
                .font(.caption2.bold())
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.45))
                    Capsule().fill(project.state == .unavailable ? Color.gray : CoFleetTheme.green)
                        .frame(width: proxy.size.width * health(for: project))
                }
            }
            .frame(height: 7)
        }
        .padding(10)
        .frame(maxWidth: 190)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
    }

    private func health(for project: CoFleetProject) -> CGFloat {
        switch project.state {
        case .unavailable: 0.18
        case .waitingForApproval, .waitingForAnswer: 0.55
        default: 0.92
        }
    }
    #endif
}

#if os(watchOS)
public struct CoFleetWatchBattleView: View {
    public var projects: [CoFleetProject]

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                battleSide(projects.first, alignment: .leading)
                Image(systemName: "bolt.fill")
                    .font(.caption.bold())
                    .foregroundStyle(CoFleetTheme.orange)
                battleSide(projects.dropFirst().first, alignment: .trailing)
            }
            HStack {
                Label("Dictate", systemImage: "mic.fill")
                Spacer()
                Label("Todos", systemImage: "checklist")
            }
            .font(.caption2.bold())
            .padding(.horizontal, 4)
        }
    }

    private func battleSide(_ project: CoFleetProject?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            CoFleetPetPlaceholder(name: project?.displayName ?? "?", size: 48)
            Text(project?.displayName ?? "No rival")
                .font(.caption2.bold())
                .lineLimit(1)
            Capsule()
                .fill(project?.state == .unavailable ? Color.gray : CoFleetTheme.green)
                .frame(width: 54, height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif

#if os(macOS)
private enum NSColorLike {
    static let background = NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.05, alpha: 1)
    static let floor = NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.16, alpha: 1)
    static let grid = NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.48, alpha: 0.75)
    static func pet(index: Int) -> NSColor {
        let palette: [NSColor] = [.systemTeal, .systemPurple, .systemOrange, .systemGreen]
        return palette[index % palette.count]
    }
}
#elseif os(iOS)
private enum NSColorLike {
    static let background = UIColor(red: 0.02, green: 0.04, blue: 0.05, alpha: 1)
    static let floor = UIColor(red: 0.08, green: 0.18, blue: 0.16, alpha: 1)
    static let grid = UIColor(red: 0.12, green: 0.55, blue: 0.48, alpha: 0.75)
    static func pet(index: Int) -> UIColor {
        let palette: [UIColor] = [.systemTeal, .systemPurple, .systemOrange, .systemGreen]
        return palette[index % palette.count]
    }
}
#endif
