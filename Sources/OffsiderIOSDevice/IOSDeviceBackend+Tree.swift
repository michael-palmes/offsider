import Foundation
import OffsiderCore

extension IOSDeviceBackend: RawAccessibilitySource {
    /// The runner's snapshot JSON before mapping.
    public func rawAccessibilitySource(for id: DeviceID) async throws -> Data {
        try requirePermittedPin(id)
        if state.drivesWhole { try await prepareWholeDevice(id) }
        let client = try await runner(for: id)
        let app = targetApp
        do {
            return try await host.timing.measure("accessibility") { try await client.snapshot(app: app) }
        } catch let error as IOSDeviceError where state.drivesWhole && error.kind == .otherAppInFront {
            guard let app else { throw error }
            // A test device can open it itself, so nobody needs to be asked.
            throw IOSDeviceError(
                .otherAppInFront,
                "\(app) is not in front on \(id.rawValue), so Offsider read nothing. Leave out --app to read what is in front, or run `offsider app launch --app \(app) --device \(id.rawValue)` first."
            )
        }
    }

    /// The runner's snapshot through the one iOS mapper; with `point`, the deepest node there as the only root.
    func runnerTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        let startedAt = Date()
        let tree = try Self.tree(fromSnapshot: try await rawAccessibilitySource(for: id), device: id.rawValue)
        guard let point else {
            DeviceActivityLedger.current.recordTreeRead(tree, on: id, startedAt: startedAt)
            return tree
        }
        return Self.filter(tree, to: point)
    }

    static func tree(fromSnapshot data: Data, device: String) throws -> UITree {
        do {
            let parsed = try IOSAccessibilityMapping.tree(fromJSON: data)
            return UITree(platform: .ios, device: device, roots: parsed.roots, sourceTruncated: parsed.truncated)
        } catch {
            throw IOSDeviceError(.runnerFailed, "The runner on \(device) sent a tree Offsider could not read. Run `offsider runner stop --device \(device)` and retry.")
        }
    }

    static func filter(_ tree: UITree, to point: UIPoint) -> UITree {
        UITree(platform: .ios, device: tree.device, roots: tree.deepestNode(at: point).map { [$0] } ?? [], sourceTruncated: tree.sourceTruncated)
    }
}
