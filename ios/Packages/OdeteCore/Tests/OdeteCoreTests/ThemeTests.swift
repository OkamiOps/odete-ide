import Testing
@testable import OdeteCore

@Suite struct ThemeTests {
    @Test func allThemesPresent() {
        #expect(ThemePalette.all.count == ThemeId.allCases.count)
        for id in ThemeId.allCases {
            #expect(ThemePalette.by(id).id == id)
        }
    }

    @Test func tokensAreHex() {
        let hex = try! Regex("^#[0-9a-f]{6}$")
        for t in ThemePalette.all {
            for c in [t.bg, t.bgElevated, t.bgSubtle, t.fg, t.fgMuted, t.fgSubtle, t.border, t.borderStrong,
                      t.accent, t.accentFg, t.danger, t.ok, t.syntax.keyword, t.syntax.string, t.syntax.comment,
                      t.syntax.number, t.syntax.function, t.syntax.type] {
                #expect(c.wholeMatch(of: hex) != nil, "\(t.id): \(c)")
            }
        }
    }
}
