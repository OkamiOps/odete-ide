import Foundation

/// Portado de `detectStack` em `src/lib/workspace/npm.ts`, mais Swift.
public struct Stack: Hashable, Sendable {
    public enum Kind: String, Sendable { case spa, ssr, api, swift, html }
    public var id: String
    public var kind: Kind
    public var label: String

    public static let html = Stack(id: "html", kind: .html, label: "HTML")

    public static func detect(paths: some Sequence<String>, packageJSON: Data?) -> Stack {
        let list = Array(paths)
        if list
            .contains(where: {
                $0 == "Package.swift" || $0.hasSuffix(".swiftpm/Package.swift") || $0.hasSuffix(".swift") && !$0
                    .contains("/")
            })
        {
            return Stack(id: "swift", kind: .swift, label: "Swift")
        }
        var all: [String: String] = [:]
        if let data = packageJSON,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in ["dependencies", "devDependencies"] {
                if let deps = obj[key] as? [String: String] {
                    all.merge(deps) { a, _ in a }
                }
            }
        }
        if all["next"] != nil {
            return Stack(id: "next", kind: .ssr, label: "Next.js")
        }
        if all["astro"] != nil {
            return Stack(id: "astro", kind: .ssr, label: "Astro")
        }
        if all["@remix-run/react"] != nil || all["@remix-run/node"] != nil || all["remix"] != nil {
            return Stack(id: "remix", kind: .ssr, label: "Remix")
        }
        if all["@nestjs/core"] != nil {
            return Stack(id: "nest", kind: .api, label: "Nest")
        }
        if all["@tanstack/react-start"] != nil || all["@tanstack/start"] != nil {
            return Stack(id: "tanstack-start", kind: .ssr, label: "TanStack Start")
        }
        if all["vite"] != nil || all["@vitejs/plugin-react"] !=
            nil
        {
            return Stack(id: "vite", kind: .spa, label: "Vite")
        }
        if all["react-scripts"] != nil {
            return Stack(id: "cra", kind: .spa, label: "CRA")
        }
        if all["react"] != nil {
            return Stack(id: "react", kind: .spa, label: "React")
        }
        return .html
    }
}
