import CryptoKit
import Foundation

enum PKCE {
    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/",
            with: "_"
        ).replacingOccurrences(of: "=", with: "")
    }

    static func random(_ n: Int = 32) -> [UInt8] {
        (0 ..< n).map { _ in UInt8.random(in: 0 ... 255) }
    }

    /// verifier, challenge (S256) e state.
    static func make() -> (verifier: String, challenge: String, state: String) {
        let verifier = base64url(random())
        let challenge = base64url(Array(SHA256.hash(data: Data(verifier.utf8))))
        return (verifier, challenge, base64url(random()))
    }

    /// Lê um claim de um JWT sem validar assinatura.
    static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 {
            b += "="
        }
        guard let d = Data(base64Encoded: b) else { return [:] }
        return jsonObject(d)
    }
}
