import Foundation
import OdeteI18n

/// OpenAI Chat Completions com SSE: Codex (chatgpt.com) e provedores compatíveis.
enum ChatCompletionsStream {
    static func body(_ t: TurnRequest, maxTokensKey: String) -> [String: Any] {
        var b: [String: Any] = [
            "model": t.model,
            "messages": messages(t),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let e = Effort.openai(t.effort) {
            b["reasoning_effort"] = e; b[maxTokensKey] = 8000
        } else {
            b["temperature"] = 0.3; b[maxTokensKey] = 1600
        }
        if !t.tools.isEmpty {
            b["tools"] = t.tools.map { [
                "type": "function",
                "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters],
            ] }
            b["tool_choice"] = "auto"
        }
        return b
    }

    static func messages(_ t: TurnRequest) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": t.system]]
        for m in t.messages {
            switch m.role {
            case .system: continue
            case .tool: out.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.content])
            case .assistant:
                var d: [String: Any] = ["role": "assistant", "content": m.content]
                if let tc = m.toolCalls, !tc.isEmpty {
                    d["tool_calls"] = tc.map { [
                        "id": $0.id,
                        "type": "function",
                        "function": ["name": $0.name, "arguments": $0.arguments],
                    ] }
                }
                out.append(d)
            case .user:
                if let imgs = m.images, !imgs.isEmpty {
                    var parts: [[String: Any]] = [["type": "text", "text": m.content.isEmpty ? " " : m.content]]
                    parts += imgs
                        .map { ["type": "image_url", "image_url": ["url": "data:\($0.mime);base64,\($0.data)"]] }
                    out.append(["role": "user", "content": parts])
                } else {
                    out.append(["role": "user", "content": m.content])
                }
            }
        }
        return out
    }

    /// Converte as linhas `data:` em eventos.
    static func events(_ lines: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                var acc = SSE.ToolAcc()
                do {
                    for try await line in lines {
                        if line == "[DONE]" {
                            break
                        }
                        let j = jsonObject(Data(line.utf8))
                        if j.isEmpty {
                            continue
                        }
                        if let e = j["error"] as? [String: Any],
                           let msg = e["message"] as? String
                        {
                            cont.yield(.error(msg)); continue
                        }
                        if let u = TokenUse.pick(j) {
                            cont.yield(.usage(u))
                        }
                        guard let choice = (j["choices"] as? [[String: Any]])?.first,
                              let delta = choice["delta"] as? [String: Any] else { continue }
                        if let rc = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
                           !rc.isEmpty
                        {
                            cont.yield(.think(rc))
                        }
                        if let c = delta["content"] as? String, !c.isEmpty {
                            cont.yield(.text(c))
                        }
                        for tc in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                            let f = tc["function"] as? [String: Any]
                            acc.add(
                                (tc["index"] as? Int) ?? 0,
                                id: tc["id"] as? String,
                                name: f?["name"] as? String,
                                args: f?["arguments"] as? String
                            )
                        }
                    }
                    if !acc.items.isEmpty {
                        cont.yield(.tools(acc.calls))
                    }
                    cont.yield(.done)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

/// Anthropic Messages com SSE: Claude (OAuth) e Anthropic-compatível (x-api-key).
enum MessagesStream {
    static func body(_ t: TurnRequest) -> [String: Any] {
        var b: [String: Any] = ["model": t.model, "stream": true, "system": t.system, "messages": messages(t)]
        if let m = Effort.anthropic(t.effort) {
            b["max_tokens"] = m.maxTokens
            b["thinking"] = ["type": "enabled", "budget_tokens": m.budget]
            b["output_config"] = ["effort": m.level]
        } else {
            b["max_tokens"] = 1600; b["temperature"] = 0.3
        }
        if !t.tools.isEmpty {
            b["tools"] = t.tools.map { [
                "name": $0.name,
                "description": $0.description,
                "input_schema": $0.parameters,
            ] }
        }
        return b
    }

    static func messages(_ t: TurnRequest) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in t.messages {
            switch m.role {
            case .system: continue
            case .user:
                if let imgs = m.images, !imgs.isEmpty {
                    var blocks: [[String: Any]] = imgs.map { [
                        "type": "image",
                        "source": ["type": "base64", "media_type": $0.mime, "data": $0.data],
                    ] }
                    blocks.append(["type": "text", "text": m.content.isEmpty ? " " : m.content])
                    out.append(["role": "user", "content": blocks])
                } else {
                    out.append(["role": "user", "content": m.content])
                }
            case .assistant:
                if let tc = m.toolCalls, !tc.isEmpty {
                    var blocks: [[String: Any]] = []
                    if !m.content.isEmpty {
                        blocks.append(["type": "text", "text": m.content])
                    }
                    for c in tc {
                        blocks.append(["type": "tool_use", "id": c.id, "name": c.name, "input": c.args])
                    }
                    out.append(["role": "assistant", "content": blocks])
                } else {
                    out.append(["role": "assistant", "content": m.content.isEmpty ? " " : m.content])
                }
            case .tool:
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": m.toolCallId ?? "",
                    "content": m.content,
                ]
                if var last = out.last, last["role"] as? String == "user", var arr = last["content"] as? [
                    [String: Any]
                ],
                    arr.last?["type"] as? String == "tool_result"
                {
                    arr.append(block); last["content"] = arr; out[out.count - 1] = last
                } else {
                    out.append(["role": "user", "content": [block]])
                }
            }
        }
        return out
    }

    static func events(_ lines: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                var acc = SSE.ToolAcc()
                var index = -1
                var isTool = false
                do {
                    for try await line in lines {
                        let j = jsonObject(Data(line.utf8))
                        guard let type = j["type"] as? String else { continue }
                        if type == "error",
                           let e = j["error"] as? [String: Any]
                        {
                            cont.yield(.error((e["message"] as? String) ?? "erro")); continue
                        }
                        if let u = TokenUse.pick(j) {
                            cont.yield(.usage(u))
                        }
                        if type == "content_block_start", let b = j["content_block"] as? [String: Any] {
                            index += 1
                            isTool = b["type"] as? String == "tool_use"
                            if isTool {
                                acc.add(index, id: b["id"] as? String, name: b["name"] as? String)
                            }
                        }
                        if type == "content_block_delta", let d = j["delta"] as? [String: Any] {
                            switch d["type"] as? String {
                            case "thinking_delta": if let s = d["thinking"] as? String,
                                                      !s.isEmpty
                                {
                                    cont.yield(.think(s))
                                }
                            case "text_delta": if let s = d["text"] as? String, !s.isEmpty {
                                    cont.yield(.text(s))
                                }
                            case "input_json_delta": if isTool {
                                    acc.add(index, args: d["partial_json"] as? String)
                                }
                            default: break
                            }
                        }
                        if type == "message_stop" {
                            break
                        }
                    }
                    if !acc.items.isEmpty {
                        cont.yield(.tools(acc.calls))
                    }
                    cont.yield(.done)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

/// OpenAI Responses com SSE: Grok pelo proxy do Grok CLI.
enum ResponsesStream {
    static func body(_ t: TurnRequest) -> [String: Any] {
        var b: [String: Any] = [
            "model": t.model,
            "stream": true,
            "instructions": t.system,
            "input": input(t),
            "store": false,
        ]
        if let e = Effort
            .openai(t.effort)
        {
            b["reasoning"] = ["effort": e, "summary": "auto"]; b["max_output_tokens"] = 8000
        } else {
            b["max_output_tokens"] = 1600
        }
        if !t.tools.isEmpty {
            b["tools"] = t.tools.map { [
                "type": "function",
                "name": $0.name,
                "description": $0.description,
                "parameters": $0.parameters,
            ] }
            b["tool_choice"] = "auto"
        }
        return b
    }

    static func input(_ t: TurnRequest) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in t.messages {
            switch m.role {
            case .system: continue
            case .user:
                var parts: [[String: Any]] = [["type": "input_text", "text": m.content.isEmpty ? " " : m.content]]
                for i in m.images ?? [] {
                    parts.append([
                        "type": "input_image",
                        "image_url": "data:\(i.mime);base64,\(i.data)",
                    ])
                }
                out.append(["role": "user", "content": parts])
            case .assistant:
                if !m.content.isEmpty {
                    out.append([
                        "role": "assistant",
                        "content": [["type": "output_text", "text": m.content]],
                    ])
                }
                for c in m.toolCalls ?? [] {
                    out.append([
                        "type": "function_call",
                        "call_id": c.id,
                        "name": c.name,
                        "arguments": c.arguments,
                    ])
                }
            case .tool:
                out.append(["type": "function_call_output", "call_id": m.toolCallId ?? "", "output": m.content])
            }
        }
        return out
    }

    static func events(_ lines: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                var acc = SSE.ToolAcc()
                var itemIndex: [String: Int] = [:] // item_id → índice
                do {
                    for try await line in lines {
                        if line == "[DONE]" {
                            break
                        }
                        let j = jsonObject(Data(line.utf8))
                        guard let type = j["type"] as? String else { continue }
                        switch type {
                        case "response.output_text.delta": if let d = j["delta"] as? String,
                                                              !d.isEmpty
                            {
                                cont.yield(.text(d))
                            }
                        case "response.reasoning_summary_text.delta",
                             "response.reasoning_text.delta": if let d = j["delta"] as? String,
                                                            !d.isEmpty
                            {
                                cont.yield(.think(d))
                            }
                        case "response.output_item.added":
                            if let item = j["item"] as? [String: Any], item["type"] as? String == "function_call" {
                                let i = (j["output_index"] as? Int) ?? acc.items.count
                                itemIndex[(item["id"] as? String) ?? ""] = i
                                acc.add(
                                    i,
                                    id: item["call_id"] as? String,
                                    name: item["name"] as? String,
                                    args: item["arguments"] as? String
                                )
                            }
                        case "response.function_call_arguments.delta":
                            let i = itemIndex[(j["item_id"] as? String) ?? ""] ?? (j["output_index"] as? Int) ?? 0
                            acc.add(i, args: j["delta"] as? String)
                        case "response.output_item.done":
                            if let item = j["item"] as? [String: Any], item["type"] as? String == "function_call",
                               let i = itemIndex[(item["id"] as? String) ?? ""] ?? (j["output_index"] as? Int)
                            {
                                // argumentos completos vencem o acumulado
                                if let a = item["arguments"] as? String, !a.isEmpty {
                                    acc.items[i] = (
                                        acc.items[i]?.id ?? (item["call_id"] as? String) ?? "",
                                        acc.items[i]?.name ?? (item["name"] as? String) ?? "",
                                        a
                                    )
                                }
                            }
                        case "response.completed", "response.done":
                            if let u = TokenUse.pick(j) {
                                cont.yield(.usage(u))
                            }
                        case "response.failed", "error":
                            let msg =
                                ((j["response"] as? [
                                    String: Any
                                ])?["error"] as? [String: Any])?["message"] as? String ??
                                (j["message"] as? String) ?? tr("erro do modelo")
                            cont.yield(.error(msg))
                        default: break
                        }
                    }
                    if !acc.items.isEmpty {
                        cont.yield(.tools(acc.calls))
                    }
                    cont.yield(.done)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}
