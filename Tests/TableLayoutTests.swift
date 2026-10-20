import Foundation
import OffsiderCore
import Testing

@Suite("Table layout")
struct TableLayoutTests {
    static let widths = [30, 40, 56, 72, 80, 100, 160, 220]

    /// The mixed devices plus one name long enough to need cutting.
    static var devices: [DeviceSummary] {
        ScreenFixtures.devices + [ScreenFixtures.simulator(4, "iPad Pro 13-inch (M5) with a very long name for testing", os: "iOS 26.0")]
    }

    static func lines(_ columns: Int) -> [String] {
        PersonRenderer.table(DevicesScreen.table(devices), canvas: Canvas(columns: columns, style: .plain))
    }

    static let ids = devices.map(\.id)

    @Test("every line fits the usable width, except a stacked line holding a whole ID", arguments: widths)
    func fits(columns: Int) {
        let usable = Canvas(columns: columns, style: .plain).usable
        for line in Self.lines(columns) where TerminalText.width(line) > usable {
            #expect(line.hasPrefix("    ") && Self.ids.contains(line.trimmingCharacters(in: .whitespaces)), "\(columns): \(line)")
        }
    }

    @Test("each ID appears whole exactly once", arguments: widths)
    func idsWhole(columns: Int) {
        let text = Self.lines(columns).joined(separator: "\n")
        for id in Self.ids {
            #expect(text.components(separatedBy: id).count == 2, "\(columns): \(id)")
        }
    }

    @Test("rows stack below 60 columns and sit on one line from 60 up", arguments: widths)
    func stacking(columns: Int) {
        let layout = DevicesScreen.table(Self.devices).layout(width: Canvas(columns: columns, style: .plain).usable)
        #expect(layout.stacked == (columns < 60))
        let rows = Self.lines(columns).filter { $0.hasPrefix("  ") && !$0.hasPrefix("    ") && !DevicesScreen.groups.contains($0.trimmingCharacters(in: .whitespaces)) }
        #expect(rows.count == Self.devices.count)
    }

    @Test("optional columns are dropped before a name is cut", arguments: widths.filter { $0 >= 60 })
    func optionalFirst(columns: Int) {
        let text = Self.lines(columns).joined(separator: "\n")
        if text.contains("…") {
            #expect(!text.contains("iOS 26.0") && !text.contains("Booting"), "\(columns) cut a name but kept an optional column")
        }
    }

    @Test("the ID column starts at one column in every group", arguments: widths.filter { $0 >= 60 })
    func alignedAcrossGroups(columns: Int) {
        let shownIDs = Self.devices.filter { $0.id != $0.name }.map(\.id)
        let starts = Self.lines(columns).compactMap { line -> Int? in
            guard let id = shownIDs.first(where: line.contains), let range = line.range(of: id) else { return nil }
            return TerminalText.width(String(line[..<range.lowerBound]))
        }
        #expect(starts.count >= 5)
        #expect(Set(starts).count == 1, "\(columns): \(starts)")
    }

    @Test("a terminal too narrow for anything still draws, with every ID whole")
    func tiny() {
        for columns in [1, 5, 12] {
            let text = Self.lines(columns).joined(separator: "\n")
            #expect(Self.ids.allSatisfy(text.contains))
            #expect(!PersonRenderer.body(ScreenFixtures.page(ScreenFixtures.mixed).blocks, canvas: Canvas(columns: columns, style: .plain)).isEmpty)
            #expect(!PersonRenderer.notices(ScreenFixtures.page(ScreenFixtures.mixed).notices, canvas: Canvas(columns: columns, style: .plain), afterBody: true).isEmpty)
        }
    }

    @Test("an AVD named by its ID shows once, never cut, and a person reads API 37 for Android API 37")
    func avdOnce() {
        let avd = Self.devices.filter { $0.kind == .avd }
        func lines(_ columns: Int) -> [String] { PersonRenderer.table(DevicesScreen.table(avd), canvas: Canvas(columns: columns, style: .plain)) }
        #expect(lines(80) == ["  Android Emulators", "  ○ Medium_Phone_API_37  API 37"])
        #expect(lines(30) == ["  Android Emulators", "  ○ Medium_Phone_API_37"])
        #expect(lines(12) == ["  Android Emulators", "  ○ Medium_Phone_API_37"])
    }
}
