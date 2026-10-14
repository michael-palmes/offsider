import Foundation
import PackagePlugin

/// Runs before every build: Version.swift follows the checkout's commits and tags, and BundleDigests.swift holds the
/// sha256 of every bundled resource; each script rewrites its file only when the content changes.
@main
struct VersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target _: Target) async throws -> [Command] {
        let versionDirectory = context.pluginWorkDirectory.appending("Generated", "Version")
        let digestsDirectory = context.pluginWorkDirectory.appending("Generated", "Digests")
        // The command runs with an empty environment, so the release override is passed through explicitly.
        let environment = ProcessInfo.processInfo.environment["OFFSIDER_VERSION"].map { ["OFFSIDER_VERSION": $0] } ?? [:]

        return [
            .prebuildCommand(
                displayName: "Stamp Version.swift",
                executable: Path("/bin/sh"),
                arguments: [
                    context.package.directory.appending("scripts", "version-stamp.sh").string,
                    versionDirectory.appending("Version.swift").string,
                    context.package.directory.string,
                ],
                environment: environment,
                outputFilesDirectory: versionDirectory
            ),
            .prebuildCommand(
                displayName: "Stamp BundleDigests.swift",
                executable: Path("/bin/sh"),
                arguments: [
                    context.package.directory.appending("scripts", "bundle-digests.sh").string,
                    digestsDirectory.appending("BundleDigests.swift").string,
                    context.package.directory.string,
                ],
                outputFilesDirectory: digestsDirectory
            ),
        ]
    }
}
