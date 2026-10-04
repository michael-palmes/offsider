import ArgumentParser
import Foundation

struct Guide: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guide",
        abstract: "Print a topic of the Offsider skill that matches this version, or list the topics."
    )

    @Argument(help: "The topic to print. Omit it to list the topics.")
    var topic: GuideTopic?

    func run() async throws {
        guard let topic else {
            Swift.print(Self.topicList(), terminator: "")
            return
        }
        Swift.print(try Self.content(of: topic), terminator: "")
    }

    static func topicList() -> String {
        let width = GuideTopic.allCases.map(\.rawValue.count).max() ?? 0
        let rows = GuideTopic.allCases.map { topic in
            topic.rawValue.padding(toLength: width + 2, withPad: " ", startingAt: 0) + topic.readItWhen.replacingOccurrences(of: "`", with: "")
        }
        return (rows + ["Run offsider guide <topic> to print one."]).joined(separator: "\n") + "\n"
    }

    static func content(of topic: GuideTopic) throws -> String {
        guard let url = Bundle.module.url(forResource: topic.rawValue, withExtension: "md", subdirectory: "skills/offsider/references"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw CLIError(errorDescription: "The bundled guide topic '\(topic.rawValue)' is missing from this install. Reinstall Offsider.", reason: .initFailed)
        }
        return text
    }
}
