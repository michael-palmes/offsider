import ArgumentParser
import Foundation
import OffsiderCore

extension UITreeFormat: ExpressibleByArgument {}

struct DescribeUIOutputOptions: ParsableArguments {
    @Flag(name: .customLong("flat"), help: "List matching nodes without nesting, each with index, parent and depth.")
    var flat = false

    @Flag(name: .customLong("on-screen"), help: "Keep nodes whose frame is at least partly on screen (nested output keeps their ancestors).")
    var onScreen = false

    @Flag(name: .customLong("labelled"), help: "Keep nodes with a label, id or value.")
    var labelled = false

    @Flag(name: .customLong("actionable"), help: "Keep buttons, fields, switches, sliders, cells and other controls.")
    var actionable = false

    @Option(
        name: .customLong("fields"),
        help: ArgumentHelp("Comma-separated keys to print: role,id,label,value,frame,enabled,state,native.", valueName: "keys")
    )
    var fields: String?

    @Option(name: .customLong("format"), help: "json (default), ndjson (one node per line after a screen line) or text.")
    var format: UITreeFormat?

    @Flag(name: .customLong("compact"), help: "Print JSON on one line.")
    var compact = false

    @Flag(name: .customLong("summary"), help: "Short view for agents: same as --flat --on-screen --labelled --format text.")
    var summary = false

    func validate() throws {
        _ = try renderOptions()
    }

    func renderOptions() throws -> UITreeRenderOptions {
        var options = summary ? UITreeRenderOptions.summary : UITreeRenderOptions()
        options.flat = options.flat || flat
        options.filter.onScreen = options.filter.onScreen || onScreen
        options.filter.labelled = options.filter.labelled || labelled
        options.filter.actionable = options.filter.actionable || actionable
        if let format {
            options.format = format
        }
        if let fields {
            do {
                options.fields = try UITreeRenderOptions.parseFields(fields)
            } catch let error as UIFieldError {
                throw ValidationError(error.description)
            }
        }
        if compact {
            guard options.format != .text else {
                throw ValidationError("--compact applies to json and ndjson only.")
            }
            options.compact = true
        }
        return options
    }

    func render(_ tree: UITree) throws -> Data {
        UITreeRenderer.render(tree, try renderOptions())
    }
}
