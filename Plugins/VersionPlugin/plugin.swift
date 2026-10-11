import Foundation
import PackagePlugin

/// Runs before every build, so `--version` follows the checkout's commits and tags; the script rewrites Version.swift only when it changes.
@main
struct VersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target _: Target) async throws -> [Command] {
        let outputDirectory = context.pluginWorkDirectory.appending("Generated")
        // The command runs with an empty environment, so the release override is passed through explicitly.
        let environment = ProcessInfo.processInfo.environment["OFFSIDER_VERSION"].map { ["OFFSIDER_VERSION": $0] } ?? [:]

        return [
            .prebuildCommand(
                displayName: "Stamp Version.swift",
                executable: Path("/bin/sh"),
                arguments: [
                    context.package.directory.appending("scripts", "version-stamp.sh").string,
                    outputDirectory.appending("Version.swift").string,
                    context.package.directory.string,
                ],
                environment: environment,
                outputFilesDirectory: outputDirectory
            ),
        ]
    }
}
