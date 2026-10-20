import Foundation
import OffsiderCore
import Testing

@Suite("Menu filter")
struct MenuFilterTests {
    /// Twelve rows as the boot picker joins their columns: a running iPhone first, the Pixels further down.
    static let rows = [
        "iPhone 17 Pro running", "Medium_Phone Android API 37", "Pixel_9 Android 16", "Pixel_Tablet Android 16", "iPhone 17 iOS 27.0", "iPhone Air iOS 27.0",
        "iPad Pro 13-inch (M5) iOS 27.0", "iPad Air 11-inch (M3) iOS 27.0", "iPad mini (A17 Pro) iOS 27.0", "iPhone 16 iOS 26.0", "iPhone 16e iOS 26.0", "Café Sim iOS 26.0",
    ]

    static func menu(disabled: Set<Int> = [], rows: [String] = rows) -> ChoiceMenu {
        ChoiceMenu(count: rows.count, disabled: disabled, refreshable: true, search: rows)
    }

    static func text(_ typed: String) -> TerminalKey { .text(Array(typed.utf8)) }

    @Test("/ starts a filter on a long list, and the whole burst after it is the query")
    func slashStartsFilter() {
        var menu = Self.menu()
        #expect(menu.offersFilter)
        #expect(menu.apply(Self.text("/")) == .moving)
        #expect(menu.query == "")
        #expect(menu.shown == Array(Self.rows.indices))
        var burst = Self.menu()
        #expect(burst.apply(Self.text("j/pix")) == .moving)
        #expect(burst.query == "pix")
        #expect(burst.shown == [2, 3])
    }

    @Test("while filtering, j, k, q, r and digits are text, not moves, quits, rescans or picks")
    func lettersAreText() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/"))
        for key in ["j", "k", "q", "r", "R", "Q", "3"] {
            #expect(menu.apply(Self.text(key)) == .moving)
        }
        #expect(menu.query == "jkqrRQ3")
        #expect(menu.apply(.endOfInput) == .cancelled)
    }

    @Test("Enter chooses the match under the cursor by its index in the full list")
    func enterReturnsFullIndex() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/pix"))
        #expect(menu.apply(.enter) == .chosen(2))
        var tablet = Self.menu()
        _ = tablet.apply(Self.text("/pix"))
        #expect(tablet.apply(.down) == .moving)
        #expect(tablet.apply(.enter) == .chosen(3))
    }

    @Test("every term must match somewhere in the row, ignoring case, accents and full-width forms")
    func matching() {
        var terms = Self.menu()
        _ = terms.apply(Self.text("/ipad iOS 27"))
        #expect(terms.shown == [6, 7, 8])
        _ = terms.apply(Self.text(" mini"))
        #expect(terms.shown == [8])
        var folded = Self.menu()
        _ = folded.apply(Self.text("/CAFE"))
        #expect(folded.shown == [11])
        var wide = Self.menu()
        _ = wide.apply(Self.text("/ｐｉｘ"))
        #expect(wide.shown == [2, 3])
        var running = Self.menu()
        _ = running.apply(Self.text("/running"))
        #expect(running.shown == [0])
    }

    @Test("Up and Down move among matches only, wrapping round")
    func arrowsStayInMatches() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/ios 26"))
        #expect(menu.selected == 9)
        _ = menu.apply(.down)
        #expect(menu.selected == 10)
        _ = menu.apply(.down)
        #expect(menu.selected == 11)
        _ = menu.apply(.down)
        #expect(menu.selected == 9)
        _ = menu.apply(.up)
        #expect(menu.selected == 11)
    }

    @Test("with no match the cursor is nowhere, Enter does nothing, and Backspace brings the matches back")
    func noMatch() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/pixx"))
        #expect(menu.shown.isEmpty)
        #expect(menu.selected == nil)
        #expect(menu.apply(.enter) == .moving)
        _ = menu.apply(.down)
        #expect(menu.selected == nil)
        _ = menu.apply(.backspace)
        #expect(menu.query == "pix")
        #expect(menu.apply(.enter) == .chosen(2))
    }

    @Test("Backspace edits the query, and on an empty query leaves the filter with every row back")
    func backspaceLeaves() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/pi"))
        _ = menu.apply(.backspace)
        _ = menu.apply(.backspace)
        #expect(menu.query == "")
        _ = menu.apply(.backspace)
        #expect(menu.query == nil)
        #expect(menu.shown == Array(Self.rows.indices))
        #expect(menu.apply(Self.text("q")) == .cancelled)
    }

    @Test("Control-U clears the query and stays filtering; Control-W drops the last word")
    func clearingKeys() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/ipad air"))
        _ = menu.apply(.deleteWord)
        #expect(menu.query == "ipad ")
        _ = menu.apply(.clearLine)
        #expect(menu.query == "")
        #expect(menu.shown == Array(Self.rows.indices))
    }

    @Test("the first Escape clears the filter and keeps the cursor on the match; the second cancels")
    func escapeTwice() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/tablet"))
        #expect(menu.apply(.escape) == .moving)
        #expect(menu.query == nil)
        #expect(menu.selected == 3)
        #expect(menu.shown.count == Self.rows.count)
        #expect(menu.apply(.escape) == .cancelled)
    }

    @Test("Escape from a filter with no match puts the cursor back where it was before the filter")
    func escapeFromNoMatch() {
        var menu = Self.menu()
        _ = menu.apply(.down)
        _ = menu.apply(.down)
        _ = menu.apply(Self.text("/zzz"))
        _ = menu.apply(.escape)
        #expect(menu.selected == 2)
    }

    @Test("Control-C cancels at once, even mid-filter")
    func controlCCancels() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/pix"))
        #expect(menu.apply(.cancel) == .cancelled)
    }

    @Test("a disabled row that matches is shown, but the cursor skips it and Enter never takes it")
    func disabledMatches() {
        var menu = Self.menu(disabled: [2])
        _ = menu.apply(Self.text("/pix"))
        #expect(menu.shown == [2, 3])
        #expect(menu.selected == 3)
        _ = menu.apply(.down)
        #expect(menu.selected == 3)
        #expect(menu.apply(.enter) == .chosen(3))
        var only = Self.menu(disabled: [2])
        _ = only.apply(Self.text("/pixel_9"))
        #expect(only.shown == [2])
        #expect(only.apply(.enter) == .moving)
    }

    @Test("a list of nine rows that fits the window ignores /, so its keys work as they always did")
    func shortListsIgnoreSlash() {
        var short = Self.menu(rows: Array(Self.rows.prefix(9)))
        short.window = 16
        #expect(!short.offersFilter)
        #expect(short.apply(Self.text("/")) == .moving)
        #expect(short.query == nil)
        #expect(short.apply(Self.text("3")) == .chosen(2))
        var cramped = Self.menu(rows: Array(Self.rows.prefix(5)))
        cramped.window = 3
        #expect(cramped.offersFilter)
    }

    @Test("a menu given no search text never filters, however long")
    func noSearchNoFilter() {
        var menu = ChoiceMenu(count: 30)
        menu.window = 5
        #expect(!menu.offersFilter)
        #expect(menu.apply(Self.text("/")) == .moving)
        #expect(menu.query == nil)
    }

    @Test("a query stops growing at its limit, and control bytes never join it")
    func queryLimit() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/" + String(repeating: "a", count: 100) + "\t"))
        #expect(menu.query?.count == ChoiceMenu.queryLimit)
        var tabbed = Self.menu()
        _ = tabbed.apply(Self.text("/pi\tx"))
        #expect(tabbed.query == "pix")
    }

    @Test("a resize changes nothing in a menu, a tick menu or a line")
    func resizeIsNoOp() {
        var menu = Self.menu()
        _ = menu.apply(Self.text("/pix"))
        #expect(menu.apply(.resize) == .moving)
        #expect(menu.query == "pix")
        #expect(menu.selected == 2)
        var ticks = CheckMenu(count: 2, ticked: [1])
        #expect(ticks.apply(.resize) == .moving)
        #expect(ticks.ticked == [1])
        let editor = LineEditor()
        _ = editor.apply(Self.text("qa"))
        #expect(editor.apply(.resize) == .editing)
        #expect(editor.text == "qa")
    }
}
