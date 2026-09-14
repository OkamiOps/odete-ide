import OdeteAgent
import SwiftUI

/// Cor do quadrado de ícone de cada provedor. Tudo laranja fazia o X do Grok parecer
/// um erro e não dava para distinguir uma conta da outra de relance.
enum ProviderCor {
    static func de(_ k: ProviderKind) -> Color {
        switch k {
        case .apple: .gray
        case .claude: .orange
        case .codex: .green
        case .grok: .blue
        case .openaiCompat: .teal
        case .anthropicCompat: .brown
        }
    }
}
