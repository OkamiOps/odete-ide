import CryptoKit
import Foundation
import OdeteAccounts
@testable import OdeteAgent
import Testing

struct AuthTests {
    @Test func pkceAndClaudeURL() throws {
        let a = ClaudeAuth().authorize()
        let q = try #require(URLComponents(url: a.url, resolvingAgainstBaseURL: false)?.queryItems)
        let challenge = try #require(q.first { $0.name == "code_challenge" }?.value)
        #expect(challenge == PKCE.base64url(Array(SHA256.hash(data: Data(a.verifier.utf8)))))
        #expect(q.contains { $0.name == "client_id" && $0.value == ClaudeAuth.clientId } && a.url
            .host() == "claude.com")
        #expect(ClaudeAuth.parseCode("abc#st") == ("abc", "st"))
        #expect(ClaudeAuth.parseCode("https://platform.claude.com/oauth/code/callback?code=abc&state=st") == (
            "abc",
            "st"
        ))
    }

    @Test func claudeExchangeAndRefresh() async throws {
        let http = FakeHTTP()
        http.enqueue(
            "https://platform.claude.com/v1/oauth/token",
            200,
            #"{"access_token":"A1","refresh_token":"R1","expires_in":3600}"#
        )
        let t = try await ClaudeAuth(http: http).exchange(code: "c", state: "s", verifier: "v")
        #expect(t.access == "A1" && t.refresh == "R1" && t.expiresAt > .now)
        let body = http.call(0).bodyJSON
        #expect(body["grant_type"] as? String == "authorization_code" && body["code_verifier"] as? String == "v" &&
            body["state"] as? String == "s")
        http.enqueue("https://platform.claude.com/v1/oauth/token", 400, #"{"error":"invalid_grant"}"#)
        await #expect(throws: AgentError.invalidGrant) { try await ClaudeAuth(http: http).refresh("R1") }
    }

    @Test func openaiDeviceFlow() async throws {
        let http = FakeHTTP()
        http.enqueue(
            "https://auth.openai.com/api/accounts/deviceauth/usercode",
            200,
            #"{"user_code":"ABCD-1234","device_auth_id":"dev1","interval":3}"#
        )
        let auth = OpenAIDeviceAuth(http: http)
        let s = try await auth.start()
        #expect(s.userCode == "ABCD-1234" && s.handle == "dev1" && s.interval == 3 && s.verificationURL
            .absoluteString == "https://auth.openai.com/codex/device")
        http.enqueue("https://auth.openai.com/api/accounts/deviceauth/token", 403, "{}")
        #expect(try await auth.poll(s) == .pending)
        let access = jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct_9"]])
        http.enqueue(
            "https://auth.openai.com/api/accounts/deviceauth/token",
            200,
            #"{"authorization_code":"code1","code_verifier":"ver1"}"#
        )
        http.enqueue(
            "https://auth.openai.com/oauth/token",
            200,
            #"{"access_token":"\#(access)","refresh_token":"R","expires_in":100}"#
        )
        guard case let .tokens(t) = try await auth.poll(s) else { Issue.record("esperava tokens"); return }
        #expect(t.accountId == "acct_9" && t.refresh == "R")
        let form = http.call(3).bodyForm
        #expect(form["grant_type"] == "authorization_code" && form["code_verifier"] == "ver1" && form["client_id"] ==
            OpenAIDeviceAuth.clientId)
    }

    @Test func grokDeviceFlow() async throws {
        let http = FakeHTTP()
        http.enqueue(
            "https://auth.x.ai/oauth2/device/code",
            200,
            #"{"device_code":"d1","user_code":"WXYZ","verification_uri":"https://auth.x.ai/device","verification_uri_complete":"https://auth.x.ai/device?code=WXYZ","interval":5,"expires_in":600}"#
        )
        let auth = GrokDeviceAuth(http: http)
        let s = try await auth.start()
        #expect(s.userCode == "WXYZ" && s.verificationURL.absoluteString == "https://auth.x.ai/device?code=WXYZ")
        #expect(http.call(0).bodyForm["scope"] == GrokDeviceAuth.scope)
        http.enqueue("https://auth.x.ai/oauth2/token", 400, #"{"error":"authorization_pending"}"#)
        http.enqueue("https://auth.x.ai/oauth2/token", 400, #"{"error":"slow_down"}"#)
        http.enqueue(
            "https://auth.x.ai/oauth2/token",
            200,
            #"{"access_token":"G","refresh_token":"GR","expires_in":3600,"id_token":"\#(jwt(["email": "m@x.ai"]))"}"#
        )
        #expect(try await auth.poll(s) == .pending)
        #expect(try await auth.poll(s) == .slowDown)
        guard case let .tokens(t) = try await auth.poll(s) else { Issue.record("esperava tokens"); return }
        #expect(t.access == "G" && t.accountId == "m@x.ai")
        #expect(http.call(1).bodyForm["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
    }

    @MainActor
    @Test func storeAndSessionRefreshOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "odete-ai-\(UUID().uuidString).json")
        let store = AIAccountStore(url: dir, secrets: MemorySecrets())
        let acc = AIAccount(kind: .grok, login: "m@x.ai")
        try store.add(acc, tokens: TokenBundle(access: "old", refresh: "GR", expiresAt: Date(timeIntervalSinceNow: 10)))
        #expect(AIAccountStore(url: dir, secrets: MemorySecrets()).accounts.count == 1)
        let http = FakeHTTP()
        http.enqueue(
            "https://auth.x.ai/oauth2/token",
            200,
            #"{"access_token":"new","refresh_token":"GR2","expires_in":3600}"#
        )
        let session = store.session(for: store.accounts[0], http: http)
        async let a = session.accessToken()
        async let b = session.accessToken()
        let (ta, tb) = try await (a, b)
        #expect(ta == "new" && tb == "new" && http.count == 1)
        #expect(store.tokens(for: store.accounts[0])?.refresh == "GR2")
        // chave de API não renova
        let key = AIAccount(kind: .openaiCompat, label: "OpenRouter", baseURL: "https://openrouter.ai/api/v1")
        try store.add(key, apiKey: "sk-1")
        #expect(try await store.session(for: key).accessToken() == "sk-1")
        // invalid_grant marca reconectar
        http.enqueue("https://auth.x.ai/oauth2/token", 400, #"{"error":"invalid_grant"}"#)
        await #expect(throws: AgentError.invalidGrant) { try await session.refreshNow() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.accounts.first { $0.kind == .grok }?.needsReconnect == true)
    }
}
