import Clibgit2
import Foundation

/// Credenciais HTTPS: usuário + token/senha. No GitHub o usuário é `x-access-token`.
public struct Credentials: Sendable, Hashable {
    public var username: String
    public var token: String
    public init(username: String, token: String) {
        self.username = username
        self.token = token
    }

    public static func github(token: String) -> Credentials {
        Credentials(username: "x-access-token", token: token)
    }

    public static func oauth2(token: String) -> Credentials {
        Credentials(username: "oauth2", token: token)
    }
}

/// Caixa que os callbacks C do libgit2 recebem como payload.
final class RemotePayload: @unchecked Sendable {
    let credentials: Credentials?
    let progress: (@Sendable (CloneProgress) -> Void)?
    var attempts = 0
    var cancelled = false
    init(credentials: Credentials?, progress: (@Sendable (CloneProgress) -> Void)?) {
        self.credentials = credentials
        self.progress = progress
    }
}

let credentialCB: git_credential_acquire_cb = { out, _, _, _, payload in
    guard let payload else { return GIT_PASSTHROUGH.rawValue }
    let box = Unmanaged<RemotePayload>.fromOpaque(payload).takeUnretainedValue()
    box.attempts += 1
    guard let c = box.credentials, box.attempts <= 2 else { return GIT_EAUTH.rawValue }
    return git_credential_userpass_plaintext_new(out, c.username, c.token)
}

let transferCB: git_indexer_progress_cb = { stats, payload in
    guard let stats, let payload else { return 0 }
    let box = Unmanaged<RemotePayload>.fromOpaque(payload).takeUnretainedValue()
    if box.cancelled {
        return -1
    }
    let s = stats.pointee
    box.progress?(CloneProgress(
        received: Int(s.received_objects),
        total: Int(s.total_objects),
        bytes: Int(s.received_bytes),
        indexed: Int(s.indexed_objects)
    ))
    return 0
}

/// Aceita o certificado quando o SecureTransport já validou; nunca aceita certificado inválido.
let certificateCB: git_transport_certificate_check_cb = { _, valid, _, _ in
    valid == 1 ? 0 : GIT_ECERTIFICATE.rawValue
}

func remoteCallbacks(_ payload: UnsafeMutableRawPointer) -> git_remote_callbacks {
    var cb = git_remote_callbacks()
    git_remote_init_callbacks(&cb, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
    cb.credentials = credentialCB
    cb.transfer_progress = transferCB
    cb.certificate_check = certificateCB
    cb.payload = payload
    return cb
}
