import Foundation
import OffsiderCore

extension IOSBackend: AppPromptReading {
    func appPrompt(for app: String, on id: DeviceID) async throws -> (prompt: AppPrompt, tree: UITree) {
        let tree = try await accessibilityTree(for: id)
        guard let pid = SimulatorAppLiveness.applicationPID(in: tree), let path = Int32(exactly: pid).flatMap(ProcessPath.of(pid:)) else {
            throw AppPromptRefusal.notShown(front: nil)
        }
        guard SimulatorHomePress.isSpringBoard(path: path) else {
            // A sheet another process draws over the app, such as Save Password?, is never a permission prompt.
            if let prompt = await SystemPromptProbe.find(in: tree, backend: self, device: id) {
                throw AppPromptRefusal.notPermission(what: prompt.summary)
            }
            throw AppPromptRefusal.notShown(front: ForegroundApp.bundleIdentifier(atExecutable: path))
        }
        return (try IOSPermissionAlert.read(tree, app: app), tree)
    }

    func stillInFront(_ prompt: AppPrompt, on id: DeviceID) async throws -> Bool {
        (try? await appPrompt(for: prompt.app, on: id))?.prompt.token == prompt.token
    }
}
