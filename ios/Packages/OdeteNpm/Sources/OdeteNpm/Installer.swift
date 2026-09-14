import Foundation

/// `npm install` de verdade: resolve, baixa, extrai, grava lock e .bin.
public struct Installer: Sendable {
    public struct Spec: Sendable, Hashable {
        public var name: String
        public var range: String
        public init(_ s: String) {
            if s.hasPrefix("@"), let at = s.dropFirst().firstIndex(of: "@") { name = String(s[..<at]); range = String(s[s.index(after: at)...]) }
            else if let at = s.firstIndex(of: "@"), at != s.startIndex { name = String(s[..<at]); range = String(s[s.index(after: at)...]) }
            else { name = s; range = "latest" }
        }
    }

    public struct Report: Sendable {
        public var installed: [(name: String, version: String)] = []
        public var native: [String] = []
        public var skipped: [String] = []
        public var failed: [String: String] = [:]
        public var added: [String] = []
    }

    public var project: URL
    public var registry: any RegistryClient
    public var log: @Sendable (String) -> Void
    public var concurrency = 4

    public init(project: URL, registry: any RegistryClient, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.project = project; self.registry = registry; self.log = log
    }

    var nodeModules: URL { project.appending(path: "node_modules") }
    var lockURL: URL { project.appending(path: "package-lock.json") }

    // MARK: API

    /// `npm install [specs]` (`add` vazio = instalar tudo do package.json).
    public func install(add: [Spec] = [], dev: Bool = false, force: Bool = false) async throws -> Report {
        var pkg = PackageJSON(url: project.appending(path: "package.json"))
        var report = Report()
        var pinned: [String: String] = [:]
        for spec in add {
            let p = try await registry.packument(spec.name)
            guard let v = p.pick(spec.range) else { throw NpmError.noVersion(spec.name, spec.range) }
            let range = spec.range == "latest" || spec.range.isEmpty ? "^\(v.version)" : spec.range
            pkg.set(spec.name, range: range, dev: dev)
            pinned[spec.name] = v.version.description
            report.added.append("\(spec.name)@\(v.version)")
        }
        if !add.isEmpty { try pkg.save() }
        let lock = force ? nil : Lockfile.load(lockURL)
        let tree = try await resolve(pkg: pkg, lock: lock, pinned: pinned, report: &report)
        try await materialize(tree, report: &report)
        var newLock = Lockfile(name: pkg.name)
        for (key, node) in tree { newLock.packages[key] = node.entry }
        var root: [String: Any] = ["name": pkg.name]
        if !pkg.dependencies.isEmpty { root["dependencies"] = pkg.dependencies }
        if !pkg.devDependencies.isEmpty { root["devDependencies"] = pkg.devDependencies }
        try newLock.save(to: lockURL, root: root)
        try writeBins(tree)
        try pruneExtraneous(tree)
        return report
    }

    public func uninstall(_ names: [String]) async throws -> Report {
        var pkg = PackageJSON(url: project.appending(path: "package.json"))
        for n in names { pkg.remove(n) }
        try pkg.save()
        return try await install()
    }

    /// Pacotes de primeiro nível instalados.
    public func list() -> [(name: String, version: String, dev: Bool, native: Bool)] {
        guard let lock = Lockfile.load(lockURL) else { return [] }
        return lock.packages.compactMap { k, e in
            let rel = k.dropFirst("node_modules/".count)
            guard !rel.contains("/node_modules/") else { return nil }
            return (String(rel), e.version, e.dev, e.native)
        }.sorted { $0.name < $1.name }
    }

    // MARK: resolução

    struct Node { var name: String; var pv: PackumentVersion?; var entry: Lockfile.Entry; var parentKey: String }

    func resolve(pkg: PackageJSON, lock: Lockfile?, pinned: [String: String], report: inout Report) async throws -> [String: Node] {
        var tree: [String: Node] = [:]
        var packuments: [String: Packument] = [:]
        struct Want { var name: String; var range: String; var from: String; var dev: Bool; var optional: Bool }
        var queue: [Want] = []
        // ordem determinística: mesmo package.json → mesmo lock
        for (n, r) in pkg.dependencies.sorted(by: { $0.key < $1.key }) { queue.append(Want(name: n, range: pinned[n] ?? r, from: "", dev: false, optional: false)) }
        for (n, r) in pkg.devDependencies.sorted(by: { $0.key < $1.key }) { queue.append(Want(name: n, range: pinned[n] ?? r, from: "", dev: true, optional: false)) }
        var i = 0
        while i < queue.count {
            let w = queue[i]; i += 1
            if w.range.hasPrefix("file:") || w.range.hasPrefix("git") || w.range.hasPrefix("http") || w.range.hasPrefix("link:") || w.range.hasPrefix("workspace:") {
                report.skipped.append("\(w.name)@\(w.range)"); continue
            }
            var range = w.range
            if range.hasPrefix("npm:") { range = String(range.split(separator: "@").last ?? "latest") }
            // já satisfeito em algum nível acima?
            if let (key, existing) = find(w.name, from: w.from, in: tree), let ev = Version(existing.entry.version), SemverRange(range).satisfies(ev) || SemverRange(range).isAny || pinned[w.name] == existing.entry.version {
                _ = key; continue
            }
            // lock
            var chosen: (version: String, resolved: String?, integrity: String?, deps: [String: String], opt: [String: String], bin: [String: String], native: Bool)?
            if pinned[w.name] == nil, let lock, let (_, le) = lock.resolve(w.name, from: w.from), let lv = Version(le.version), SemverRange(range).isAny || SemverRange(range).satisfies(lv) {
                chosen = (le.version, le.resolved, le.integrity, le.dependencies, le.optionalDependencies, le.bin, le.native)
            }
            if chosen == nil {
                let p: Packument
                if let c = packuments[w.name] { p = c } else {
                    do { p = try await registry.packument(w.name) } catch {
                        if w.optional { report.skipped.append(w.name); continue }
                        report.failed[w.name] = error.localizedDescription; continue
                    }
                    packuments[w.name] = p
                }
                guard let pv = p.pick(pinned[w.name] ?? range) else {
                    if w.optional { report.skipped.append(w.name); continue }
                    report.failed[w.name] = NpmError.noVersion(w.name, range).localizedDescription; continue
                }
                if !pv.os.isEmpty, !pv.os.contains("darwin"), !pv.os.contains("!win32"), !pv.os.contains("any") { report.skipped.append("\(w.name) (só \(pv.os.joined(separator: ",")))"); continue }
                if !pv.cpu.isEmpty, !pv.cpu.contains("arm64") { report.skipped.append("\(w.name) (só \(pv.cpu.joined(separator: ",")))"); continue }
                let native = pv.hasInstallScript || w.name.hasSuffix("-darwin-arm64") || w.name.hasSuffix("-darwin-64") || w.name.contains("/darwin-") || w.name.hasPrefix("@esbuild/") || w.name.hasPrefix("@swc/core-") || w.name.hasPrefix("@rollup/rollup-") || w.name.hasPrefix("@next/swc-")
                chosen = (pv.version.description, pv.tarball, pv.integrity, pv.dependencies, pv.optionalDependencies, pv.bin, native)
            }
            guard let c = chosen else { continue }
            // onde colocar: topo se livre, senão aninhado sob quem pediu
            var key = "node_modules/\(w.name)"
            if let top = tree[key], top.entry.version != c.version { key = w.from.isEmpty ? key : "\(w.from)/node_modules/\(w.name)" }
            if let existing = tree[key], existing.entry.version == c.version { continue }
            let entry = Lockfile.Entry(version: c.version, resolved: c.resolved, integrity: c.integrity, dependencies: c.deps, optionalDependencies: c.opt, bin: c.bin, dev: w.dev, native: c.native)
            tree[key] = Node(name: w.name, pv: nil, entry: entry, parentKey: w.from)
            if c.native { report.native.append("\(w.name)@\(c.version)") }
            for (dn, dr) in c.deps.sorted(by: { $0.key < $1.key }) { queue.append(Want(name: dn, range: dr, from: key, dev: w.dev, optional: false)) }
            for (dn, dr) in c.opt.sorted(by: { $0.key < $1.key }) { queue.append(Want(name: dn, range: dr, from: key, dev: w.dev, optional: true)) }
        }
        return tree
    }

    func find(_ name: String, from: String, in tree: [String: Node]) -> (String, Node)? {
        var base = from
        while true {
            let key = base.isEmpty ? "node_modules/\(name)" : "\(base)/node_modules/\(name)"
            if let n = tree[key] { return (key, n) }
            if base.isEmpty { return nil }
            guard let r = base.range(of: "/node_modules/", options: .backwards) else { base = ""; continue }
            base = String(base[..<r.lowerBound])
        }
    }

    // MARK: download + extração

    func materialize(_ tree: [String: Node], report: inout Report) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        var todo: [(String, Node)] = []
        for (key, node) in tree {
            let dir = project.appending(path: key)
            let marker = dir.appending(path: "package.json")
            if let d = try? Data(contentsOf: marker), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], (j["version"] as? String) == node.entry.version { continue }
            todo.append((key, node))
        }
        let total = todo.count
        if total > 0 { log("baixando \(total) pacote(s)…") }
        var done = 0
        var results: [(String, Node, Result<Data, Error>)] = []
        for chunk in stride(from: 0, to: todo.count, by: concurrency).map({ Array(todo[$0 ..< min($0 + concurrency, todo.count)]) }) {
            let fetched: [(String, Node, Result<Data, Error>)] = await withTaskGroup(of: (String, Node, Result<Data, Error>).self) { group in
                for (key, node) in chunk {
                    group.addTask { [registry] in
                        guard let url = node.entry.resolved else { return (key, node, .failure(NpmError.tarball("sem URL para \(node.name)"))) }
                        do { return (key, node, .success(try await registry.tarball(url, integrity: node.entry.integrity))) } catch { return (key, node, .failure(error)) }
                    }
                }
                var out: [(String, Node, Result<Data, Error>)] = []
                for await r in group { out.append(r) }
                return out
            }
            results += fetched
        }
        for (key, node, r) in results {
            switch r {
            case let .success(data):
                let dir = project.appending(path: key)
                try? fm.removeItem(at: dir)
                do {
                    try Tar.extractPackage(data, to: dir)
                    if node.entry.native || fm.fileExists(atPath: dir.appending(path: "binding.gyp").path) { report.native.append("\(node.name)@\(node.entry.version)") }
                    report.installed.append((node.name, node.entry.version))
                } catch { report.failed[node.name] = error.localizedDescription }
            case let .failure(e): report.failed[node.name] = e.localizedDescription
            }
            done += 1
            if done % 10 == 0 || done == total { log("\(done)/\(total)") }
        }
        report.native = Array(Set(report.native)).sorted()
    }

    func writeBins(_ tree: [String: Node]) throws {
        let fm = FileManager.default
        for (key, node) in tree {
            let binDir = URL(fileURLWithPath: key, relativeTo: project).deletingLastPathComponent().appending(path: ".bin")
            let parentNM = key.hasSuffix("/" + node.name) ? String(key.dropLast(node.name.count + 1)) : "node_modules"
            let binDirURL = project.appending(path: parentNM).appending(path: ".bin")
            _ = binDir
            for (bname, bpath) in node.entry.bin {
                try fm.createDirectory(at: binDirURL, withIntermediateDirectories: true)
                let link = binDirURL.appending(path: bname)
                try? fm.removeItem(at: link)
                let target = "../\(node.name)/\(bpath)"
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            }
        }
    }

    /// Remove de node_modules o que não está na árvore.
    func pruneExtraneous(_ tree: [String: Node]) throws {
        let fm = FileManager.default
        let keep = Set(tree.keys.map { project.appending(path: $0).path })
        func walk(_ nm: URL) {
            guard let items = try? fm.contentsOfDirectory(at: nm, includingPropertiesForKeys: nil) else { return }
            for item in items {
                let name = item.lastPathComponent
                if name == ".bin" || name == ".package-lock.json" { continue }
                if name.hasPrefix("@") {
                    for scoped in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
                        if !keep.contains(scoped.path) { try? fm.removeItem(at: scoped) } else { walk(scoped.appending(path: "node_modules")) }
                    }
                    continue
                }
                if !keep.contains(item.path) { try? fm.removeItem(at: item) } else { walk(item.appending(path: "node_modules")) }
            }
        }
        walk(nodeModules)
    }
}
