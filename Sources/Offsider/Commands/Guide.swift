import ArgumentParser
import Foundation
import OffsiderCore

struct Guide: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guide",
        abstract: "Print a topic of the Offsider skill that matches this version, or list the topics.",
        discussion: """
        --project prints the repository's own OFFSIDER.md, found in the path or its parents up to the \
        repository root (the first directory holding .git), your home directory or /.
        """
    )

    @Argument(help: "The topic to print. Omit it to list the topics.")
    var topic: GuideTopic?

    @Option(name: .customLong("project"), help: ArgumentHelp("Print the OFFSIDER.md found from this path upwards instead of a topic.", valueName: "path"))
    var project: String?

    func validate() throws {
        if project != nil, topic != nil {
            throw ValidationError("--project prints the project's OFFSIDER.md; pass a topic or --project, not both.")
        }
    }

    func run() async throws {
        let console = Console.current
        if let project {
            let found = try Self.projectGuide(from: project)
            Console.current.line("Project guide: \(found.path)", person: .note("From \(TerminalText.homePath(found.path))", mark: .guide))
            console.data(found.text)
            return
        }
        guard let topic else {
            let found = try? ProjectGuide.locate(from: ".")
            let agent = Self.topicList() + (found.map { "Project guide: \($0.path) (offsider guide --project .)\n" } ?? "")
            console.show(StartPersonView.guideTopics(GuideTopic.allCases.map { ($0.rawValue, $0.readItWhen) }, agentText: agent, projectGuide: found != nil))
            return
        }
        console.data(try Self.content(of: topic))
    }

    static func projectGuide(from path: String, home: String = NSHomeDirectory()) throws -> ProjectGuide.Found {
        do {
            return try ProjectGuide.locate(from: path, home: home)
        } catch ProjectGuide.Failure.missingPath(let missing) {
            throw CLIError(errorDescription: "--project \(missing) does not exist. Pass the repository or a path inside it, such as --project .", reason: .usage)
        } catch ProjectGuide.Failure.notFound(let start, let stop) {
            throw CLIError(errorDescription: "No \(ProjectGuide.fileName) in \(start) or its parents up to \(stop). Add one to give agents this project's recipes.")
        } catch ProjectGuide.Failure.unreadable(let path, let detail) {
            throw CLIError(errorDescription: "Could not read \(path): \(detail).")
        }
    }

    static func topicList() -> String {
        let width = GuideTopic.allCases.map(\.rawValue.count).max() ?? 0
        let rows = GuideTopic.allCases.map { topic in
            topic.rawValue.padding(toLength: width + 2, withPad: " ", startingAt: 0) + topic.readItWhen.replacingOccurrences(of: "`", with: "")
        }
        return (rows + ["Run offsider guide <topic> to print one."]).joined(separator: "\n") + "\n"
    }

    static func content(of topic: GuideTopic) throws -> String {
        let data = try BundleIntegrity.verifiedData("skills/offsider/references/\(topic.rawValue).md")
        return String(decoding: data, as: UTF8.self)
    }
}
