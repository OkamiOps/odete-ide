import OdeteCore
@testable import OdeteUI
import SwiftUI
import Testing

struct ThemeColorTests {
    @Test func hexParses() {
        #expect(Color(hex: "#ffffff") == Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1))
        #expect(Color(hex: "000000") == Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1))
        #expect(Color(hex: "zz") == .pink)
    }

    @Test func everyThemeBuilds() {
        for id in ThemeId.allCases {
            let t = Theme(id: id)
            #expect(t.id == id)
            #expect(t.colorScheme == (t.dark ? .dark : .light))
        }
    }
}
