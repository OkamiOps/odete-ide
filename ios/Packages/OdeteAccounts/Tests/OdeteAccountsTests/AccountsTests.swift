import Foundation
@testable import OdeteAccounts
import Testing

struct DeviceFlowTests {
    @Test func parsesCode() throws {
        let json = #"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        let c = try GitHubDeviceFlow.parseCode(Data(json.utf8))
        #expect(c.userCode == "ABCD-1234" && c.interval == 5 && c.expiresIn == 900)
    }

    @Test func parsesPoll() {
        #expect(GitHubDeviceFlow.parsePoll(Data(#"{"error":"authorization_pending"}"#.utf8)) == .pending)
        #expect(GitHubDeviceFlow.parsePoll(Data(#"{"error":"slow_down","interval":10}"#.utf8)) == .slowDown)
        #expect(GitHubDeviceFlow
            .parsePoll(Data(#"{"access_token":"gho_x","token_type":"bearer"}"#.utf8)) == .token("gho_x"))
        #expect(GitHubDeviceFlow
            .parsePoll(Data(#"{"error":"expired_token","error_description":"expirou"}"#.utf8)) == .failed("expirou"))
        #expect(GitHubDeviceFlow.parsePoll(Data("x".utf8)) == .failed("resposta inválida"))
    }
}

struct HostAccountTests {
    @Test func hostOfRemote() {
        #expect(HostAccount.host(ofRemote: "https://github.com/a/b.git") == "github.com")
        #expect(HostAccount.host(ofRemote: "git@gitlab.com:a/b.git") == "gitlab.com")
        #expect(HostAccount.host(ofRemote: "file:///tmp/x") == nil)
    }

    @Test func detectKind() {
        #expect(HostKind.detect(host: "github.com") == .github)
        #expect(HostKind.detect(host: "codeberg.org") == .gitea)
        #expect(HostKind.detect(host: "meu.git.local") == .other)
        #expect(HostKind.github.gitUsername == "x-access-token")
    }
}

struct GitHubAPITests {
    @Test func decodesPullsAndRuns() throws {
        let pulls = #"[{"id":1,"number":7,"title":"t","state":"open","html_url":"u","head":{"ref":"f","sha":"a"},"base":{"ref":"main","sha":"b"},"user":{"login":"me"},"created_at":"2026-09-14T00:00:00Z"}]"#
        let p = try GitHubAPI.decoder.decode([GitHubPull].self, from: Data(pulls.utf8))
        #expect(p[0].number == 7 && p[0].head.ref == "f" && p[0].user?.login == "me")
        let runs = #"{"workflow_runs":[{"id":3,"name":"CI","status":"completed","conclusion":"success","head_branch":"main","html_url":"u"}]}"#
        struct Wrap: Decodable { var workflow_runs: [GitHubRun] }
        let r = try GitHubAPI.decoder.decode(Wrap.self, from: Data(runs.utf8)).workflow_runs
        #expect(r[0].conclusion == "success")
        let issues = #"[{"id":1,"number":2,"title":"i","state":"open","html_url":"u"},{"id":2,"number":3,"title":"pr","state":"open","html_url":"u","pull_request":{"url":"x"}}]"#
        let i = try GitHubAPI.decoder.decode([GitHubIssue].self, from: Data(issues.utf8))
        #expect(i.filter { !$0.isPull }.count == 1)
    }
}

@MainActor
struct AccountStoreTests {
    @Test func addRemoveAndLookup() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "odete-acc-\(UUID().uuidString)/accounts.json")
        let secrets = MemorySecrets()
        let store = AccountStore(url: url, keychain: secrets)
        let acc = HostAccount(kind: .github, host: "github.com", login: "marcos", name: "Marcos", email: "m@x.io")
        try store.add(acc, token: "gho_test")
        #expect(store.token(for: acc) == "gho_test")
        #expect(store.account(forRemote: "https://github.com/a/b.git")?.login == "marcos")
        #expect(store.authorName == "Marcos" && store.authorEmail == "m@x.io")
        let again = AccountStore(url: url, keychain: secrets)
        #expect(again.accounts.count == 1)
        store.remove(acc)
        #expect(store.accounts.isEmpty && store.token(for: acc) == nil)
    }
}
