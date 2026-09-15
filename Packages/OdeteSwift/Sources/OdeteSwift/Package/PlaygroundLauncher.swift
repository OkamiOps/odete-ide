import UIKit

/// Abre o pacote no Swift Playgrounds (ou no Arquivos) a partir do app.
@MainActor
public enum PlaygroundLauncher {
    public static let appStoreURL = URL(string: "itms-apps://apps.apple.com/app/id908519492")!
    private static var interaction: UIDocumentInteractionController?
    private static let delegate = Delegate()

    /// Folha "Abrir em…" do sistema com o pacote; o Playgrounds aparece quando está instalado.
    public static func open(_ package: URL, from view: UIView, rect: CGRect) -> Bool {
        let c = UIDocumentInteractionController(url: package)
        c.uti = "com.apple.swift-playgrounds.package"
        c.delegate = delegate
        interaction = c
        if c.presentOpenInMenu(from: rect, in: view, animated: true) {
            return true
        }
        return c.presentOptionsMenu(from: rect, in: view, animated: true)
    }

    /// Mostra a pasta do pacote no app Arquivos.
    public static func showInFiles(_ package: URL) {
        let path = package.deletingLastPathComponent().path
        if let u = URL(string: "shareddocuments://" + path) {
            UIApplication.shared.open(u)
        }
    }

    public static func openAppStore() {
        UIApplication.shared.open(appStoreURL)
    }

    final class Delegate: NSObject, UIDocumentInteractionControllerDelegate {}
}
