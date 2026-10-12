import Foundation
import OffsiderCore

/// Finds a prompt another process draws over an iOS app, which only the simulator's point read reaches.
@MainActor
enum SystemPromptProbe {
    /// With its host in `tree`, a point read at the screen's middle, reusing `centre` when describe-ui already read there; the prompt when another process answers.
    static func find(in tree: UITree, backend: any DeviceBackend, device: DeviceID, centre: (point: UIPoint, hit: UINode)? = nil) async -> SystemPrompt? {
        guard let hitTester = backend as? any PointHitTesting, !SystemPrompt.hosts(in: tree).isEmpty, let viewport = tree.viewport else { return nil }
        let point = SystemPrompt.probePoint(in: viewport)
        let read: UINode? = if let centre, centre.point == point {
            centre.hit
        } else {
            try? await hitTester.hitTest(at: point, on: device, appPIDs: SystemPrompt.pids(in: tree.roots))
        }
        guard let hit = read, SystemPrompt.isForeign(hit, in: tree.roots), let pid = hit.iosPID else { return nil }
        return SystemPrompt(title: SystemPrompt.title(of: hit), process: await hitTester.processName(of: pid, on: device), pid: pid)
    }

    /// The prompt a tap's foreign `hit` belongs to, titled by a read at the screen's middle when the hit has no text.
    static func prompt(of hit: UINode, pid: Int, in tree: UITree, hitTester: any PointHitTesting, device: DeviceID) async -> SystemPrompt {
        var title = SystemPrompt.title(of: hit)
        if title == nil, let viewport = tree.viewport,
           let middle = try? await hitTester.hitTest(at: SystemPrompt.probePoint(in: viewport), on: device, appPIDs: SystemPrompt.pids(in: tree.roots)),
           middle.iosPID == pid {
            title = SystemPrompt.title(of: middle)
        }
        return SystemPrompt(title: title, process: await hitTester.processName(of: pid, on: device), pid: pid)
    }
}
