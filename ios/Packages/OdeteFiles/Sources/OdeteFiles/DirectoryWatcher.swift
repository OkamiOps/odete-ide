import Foundation

/// Observa a raiz do projeto (recursivo por polling leve do `contentModificationDate` de cada pasta
/// combinado com `DispatchSource` na raiz) e chama `onChange` com debounce.
public final class DirectoryWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var lastSignature: Int = 0
    private let queue = DispatchQueue(label: "odete.watcher", qos: .utility)
    private var pending: DispatchWorkItem?

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            fd = open(url.path, O_EVTONLY)
            if fd >= 0 {
                let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
                src.setEventHandler { [weak self] in self?.fire() }
                src.setCancelHandler { [fd] in close(fd) }
                src.resume()
                source = src
            }
            lastSignature = signature()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: 2)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let sig = signature()
                if sig != lastSignature {
                    lastSignature = sig
                    fire()
                }
            }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
            timer?.cancel()
            timer = nil
            pending?.cancel()
        }
    }

    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Assinatura barata da árvore: soma de datas de modificação das pastas (fora de ruído).
    private func signature() -> Int {
        var hasher = Hasher()
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return 0 }
        for case let item as URL in e {
            let name = item.lastPathComponent
            if name == "node_modules" || name == ".git" || name == ".build" {
                e.skipDescendants()
                continue
            }
            if let v = try? item.resourceValues(forKeys: Set(keys)), v.isDirectory == true {
                hasher.combine(item.path)
                hasher.combine(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return hasher.finalize()
    }
}
