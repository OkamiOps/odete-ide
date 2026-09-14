import Foundation

public struct RuntimeError: LocalizedError, Sendable, Equatable {
    public var message: String
    public var stack: String?
    public var file: String?
    public var line: Int?
    public var errorDescription: String? {
        message
    }

    public init(message: String, stack: String? = nil, file: String? = nil, line: Int? = nil) {
        self.message = message
        self.stack = stack
        self.file = file
        self.line = line
    }
}

/// Saída de um processo: linhas de stdout/stderr.
public enum OutputKind: Sendable { case out, err }

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}
