import Foundation
import OffsiderCore
import Testing

@Suite("Selector text folding")
struct SelectorTextTests {
    @Test("a curly apostrophe folds to a straight one")
    func curlyApostrophe() {
        #expect(SelectorText.folded("Don\u{2019}t Allow") == "Don't Allow")
        #expect(SelectorText.folded("\u{201C}Quoted\u{201D}") == "\"Quoted\"")
    }

    @Test("a narrow no-break space in a time folds to a plain space")
    func narrowNoBreakSpace() {
        #expect(SelectorText.folded("9:41\u{202F}AM") == "9:41 AM")
    }

    @Test("zero-width and direction marks are dropped, and whitespace runs collapse")
    func invisibleMarksDropped() {
        #expect(SelectorText.folded("Sign\u{200B} in") == "Sign in")
        #expect(SelectorText.folded("\u{2066}Save\u{2069}") == "Save")
        #expect(SelectorText.folded("  Sign \n\t in  ") == "Sign in")
    }

    @Test("non-breaking hyphens and minus signs fold, en dashes stay")
    func hyphens() {
        #expect(SelectorText.folded("e\u{2011}mail") == "e-mail")
        #expect(SelectorText.folded("\u{2212}5") == "-5")
        #expect(SelectorText.folded("1\u{2013}2") == "1\u{2013}2")
    }

    @Test("case is kept")
    func caseKept() {
        #expect(SelectorText.folded("Sign In") != SelectorText.folded("sign in"))
    }

    @Test("NFC and NFD spellings fold to the same text")
    func normalisationForms() {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        #expect(SelectorText.folded(composed).unicodeScalars.elementsEqual(SelectorText.folded(decomposed).unicodeScalars))
    }

    @Test("suggestions rank a case-only difference first, then containment")
    func suggestionRanking() {
        let suggestions = SelectorText.suggestions(
            for: "Sign in",
            among: ["Sign in with Apple", "Cancel", "Sign In"]
        )
        #expect(suggestions == ["Sign In", "Sign in with Apple"])
    }

    @Test("a small typo is suggested")
    func typoSuggested() {
        #expect(SelectorText.suggestions(for: "Setings", among: ["Settings", "Profile"]) == ["Settings"])
    }

    @Test("the limit is respected")
    func limitRespected() {
        let suggestions = SelectorText.suggestions(for: "Save", among: ["save", "SAVE", "Save draft", "Save all"], limit: 2)
        #expect(suggestions == ["save", "SAVE"])
    }

    @Test("distant strings give no suggestion")
    func distantStrings() {
        #expect(SelectorText.suggestions(for: "Delete account", among: ["Settings", "Profile", "OK"]).isEmpty)
    }

    @Test("text over the limit is cut to the limit with an ellipsis; text at the limit is kept")
    func truncatedToLimit() {
        let long = String(repeating: "a", count: 61)
        #expect(SelectorText.truncated(long) == String(repeating: "a", count: 59) + "…")
        #expect(SelectorText.truncated(long).count == 60)
        #expect(SelectorText.truncated(String(long.dropLast())) == String(long.dropLast()))
        #expect(SelectorText.truncated("Settings", limit: 4) == "Set…")
    }
}
