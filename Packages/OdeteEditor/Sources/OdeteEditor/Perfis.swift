import OdeteCore

/// Um perfil por linguagem: o que liga nome, o que não é referência, o que já vem
/// pronto, e até onde uma declaração é vista. O motor é o mesmo para todos.
///
/// Só entram linguagens em que a resposta é honesta. A regra é simples: se o que existe
/// num arquivo depende de texto que a Odete não lê, a linguagem fica de fora. C e C++
/// ficam por causa do `#include`, que traz nomes de cabeçalhos do sistema; Rust, porque a
/// maior parte dos nomes vem de crates externas. JavaScript e TypeScript quase ficaram
/// pelo mesmo motivo — o ambiente traz centenas de globais — e entram porque essa lista é
/// finita e está escrita aqui embaixo.
enum Perfis {
    // MARK: - Python

    /// O módulo é a unidade: `alcance: .arquivo`. O que outro arquivo declara só chega
    /// aqui por import, e o import já liga o nome.
    static let python = Resolvedor.Perfil(
        ligacoes: [
            "function_definition": .campo("name"),
            "class_definition": .campo("name"),
            "parameters": .tudoAbaixo,
            "lambda_parameters": .tudoAbaixo,
            "assignment": .campo("left"),
            "augmented_assignment": .campo("left"),
            "named_expression": .campo("name"),
            "for_statement": .campo("left"),
            "for_in_clause": .campo("left"),
            "as_pattern": .campo("alias"),
            "global_statement": .filhosDiretos,
            "nonlocal_statement": .filhosDiretos,
        ],
        referenciaParcial: ["attribute": "object", "keyword_argument": "value"],
        imports: ["import_statement", "import_from_statement", "future_import_statement"],
        // `from x import *`: dali pode ter vindo qualquer coisa. Calar é o certo.
        desligam: ["wildcard_import"],
        embutidos: embutidosPython,
        alcance: .arquivo
    )

    // MARK: - Go

    /// Pacote é diretório: `alcance: .pasta`. Uma função declarada em `tela.go` é vista
    /// em `main.go` sem import nenhum, e é por isso que o índice do projeto existe.
    static let go = Resolvedor.Perfil(
        ligacoes: [
            "function_declaration": .campo("name"),
            "method_declaration": .campo("name"),
            "type_spec": .campo("name"),
            "const_spec": .campo("name"),
            "var_spec": .campo("name"),
            "short_var_declaration": .campo("left"),
            "parameter_declaration": .campo("name"),
            "variadic_parameter_declaration": .campo("name"),
            "range_clause": .campo("left"),
            "type_parameter_declaration": .campo("name"),
            "label_statement": .campo("label"),
        ],
        referenciaParcial: ["selector_expression": "operand", "keyed_element": "value"],
        // Campo de struct e de interface é nome do tipo, não do arquivo.
        semReferencias: ["field_declaration", "method_elem", "field_identifier"],
        imports: ["import_declaration"],
        embutidos: embutidosGo,
        declaracoesDoTopo: ["function_declaration", "type_spec", "const_spec", "var_spec"],
        alcance: .pasta
    )

    // MARK: - Java

    /// A classe é achada pelo nome: `alcance: .projeto`. `import a.b.C` liga `C`, e uma
    /// classe do mesmo projeto vale sem import quando está no mesmo pacote.
    static let java = Resolvedor.Perfil(
        ligacoes: [
            "class_declaration": .campo("name"),
            "interface_declaration": .campo("name"),
            "enum_declaration": .campo("name"),
            "record_declaration": .campo("name"),
            "method_declaration": .campo("name"),
            "formal_parameter": .campo("name"),
            "spread_parameter": .tudoAbaixo,
            "catch_formal_parameter": .campo("name"),
            "variable_declarator": .campo("name"),
            "enum_constant": .campo("name"),
            "type_parameter": .tudoAbaixo,
            "resource": .campo("name"),
            "labeled_statement": .filhosDiretos,
            "enhanced_for_statement": .campo("name"),
            "lambda_expression": .campo("parameters"),
            "inferred_parameters": .tudoAbaixo,
        ],
        referenciaParcial: ["field_access": "object"],
        // `obj.faz(x)`: `faz` é membro de `obj`, mas `x` é nome daqui.
        semOCampo: ["method_invocation": "name"],
        semReferencias: ["package_declaration", "marker_annotation", "annotation"],
        imports: ["import_declaration"],
        // `import java.util.*`: o que entrou é desconhecido.
        desligam: ["asterisk"],
        embutidos: embutidosJava,
        declaracoesDoTopo: ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"],
        alcance: .projeto
    )

    // MARK: - TypeScript e JavaScript

    /// O módulo é a unidade, como em Python: `alcance: .arquivo`. Tudo que vem de fora
    /// vem por `import`, e o `import` liga o nome.
    ///
    /// Aqui a lista de embutidos é o coração da coisa. Um arquivo `.ts` roda no navegador,
    /// no Node ou nos dois, e cada um traz centenas de nomes que ninguém declara —
    /// `document`, `process`, `fetch`, `describe`. Foi por isso que esta linguagem ficou
    /// de fora antes; ela só entra agora porque a lista está escrita.
    static let typescript = perfilJS(tipos: true)
    static let javascript = perfilJS(tipos: false)

    private static func perfilJS(tipos: Bool) -> Resolvedor.Perfil {
        var ligacoes: [String: Resolvedor.Ligacao] = [
            "function_declaration": .campo("name"),
            "generator_function_declaration": .campo("name"),
            "function_expression": .campo("name"),
            "class_declaration": .campo("name"),
            "variable_declarator": .campo("name"),
            "arrow_function": .campo("parameter"),
            "for_in_statement": .campo("left"),
            "catch_clause": .campo("parameter"),
            "labeled_statement": .filhosDiretos,
        ]
        if tipos {
            // Em TypeScript o parâmetro vem embrulhado, e é preciso: ligar tudo que está
            // dentro de `formal_parameters` ligaria também o tipo anotado, e aí
            // `function f(p: Pessoa)` nunca acusaria `Pessoa` — que é metade do valor de
            // ter isto em TypeScript.
            // O que só existe em TypeScript. Um `.ts` sem isto acusaria todo tipo genérico.
            for (k, v) in [
                "type_alias_declaration": Resolvedor.Ligacao.campo("name"),
                "interface_declaration": .campo("name"),
                "enum_declaration": .campo("name"),
                "abstract_class_declaration": .campo("name"),
                "required_parameter": .campo("pattern"),
                "optional_parameter": .campo("pattern"),
                "type_parameter": .tudoAbaixo,
                "internal_module": .campo("name"),
                "module": .campo("name"),
                "import_alias": .campo("name"),
            ] {
                ligacoes[k] = v
            }
        } else {
            ligacoes["formal_parameters"] = .tudoAbaixo
        }
        return Resolvedor.Perfil(
            ligacoes: ligacoes,
            referenciaParcial: [
                "member_expression": "object",
                "nested_type_identifier": "module",
                "nested_identifier": "object",
            ],
            semReferencias: ["property_signature", "method_signature", "public_field_definition"],
            // `export { a } from './b'` fala de um nome que nem passa por este arquivo.
            semReferenciasComCampo: ["export_statement": "source"],
            // `<div>` e `<Botao>` são o mesmo nó; ver o nome basta, acusar não.
            nomeSoUsa: ["jsx_opening_element", "jsx_self_closing_element", "jsx_closing_element"],
            tokensSoUsam: ["shorthand_property_identifier"],
            imports: ["import_statement"],
            embutidos: tipos
                ? embutidosJS.union(tiposTS).union(palavrasContextuais)
                : embutidosJS.union(palavrasContextuais),
            alcance: .arquivo
        )
    }

    // MARK: - listas

    /// Faltar um embutido aqui é acusar código certo, então a lista é larga de propósito.
    static let embutidosPython: Set<String> = [
        "abs", "aiter", "all", "anext", "any", "ascii", "bin", "bool", "breakpoint",
        "bytearray", "bytes", "callable", "chr", "classmethod", "compile", "complex",
        "delattr", "dict", "dir", "divmod", "enumerate", "eval", "exec", "filter", "float",
        "format", "frozenset", "getattr", "globals", "hasattr", "hash", "help", "hex", "id",
        "input", "int", "isinstance", "issubclass", "iter", "len", "list", "locals", "map",
        "max", "memoryview", "min", "next", "object", "oct", "open", "ord", "pow", "print",
        "property", "range", "repr", "reversed", "round", "set", "setattr", "slice",
        "sorted", "staticmethod", "str", "sum", "super", "tuple", "type", "vars", "zip",
        "True", "False", "None", "NotImplemented", "Ellipsis", "self", "cls",
        "__name__", "__file__", "__doc__", "__package__", "__spec__", "__loader__",
        "__builtins__", "__debug__", "__import__", "__init__", "__main__",
        "BaseException", "Exception", "ArithmeticError", "AssertionError", "AttributeError",
        "BlockingIOError", "BrokenPipeError", "BufferError", "BytesWarning",
        "ChildProcessError", "ConnectionError", "ConnectionAbortedError",
        "ConnectionRefusedError", "ConnectionResetError", "DeprecationWarning", "EOFError",
        "EnvironmentError", "FileExistsError", "FileNotFoundError", "FloatingPointError",
        "FutureWarning", "GeneratorExit", "IOError", "ImportError", "ImportWarning",
        "IndentationError", "IndexError", "InterruptedError", "IsADirectoryError",
        "KeyError", "KeyboardInterrupt", "LookupError", "MemoryError", "ModuleNotFoundError",
        "NameError", "NotADirectoryError", "NotImplementedError", "OSError", "OverflowError",
        "PendingDeprecationWarning", "PermissionError", "ProcessLookupError", "RecursionError",
        "ReferenceError", "ResourceWarning", "RuntimeError", "RuntimeWarning",
        "StopAsyncIteration", "StopIteration", "SyntaxError", "SyntaxWarning", "SystemError",
        "SystemExit", "TabError", "TimeoutError", "TypeError", "UnboundLocalError",
        "UnicodeDecodeError", "UnicodeEncodeError", "UnicodeError", "UnicodeTranslateError",
        "UnicodeWarning", "UserWarning", "ValueError", "Warning", "ZeroDivisionError",
    ]

    /// Go tem lista curta e fechada: tipos, constantes e funções embutidas.
    static let embutidosGo: Set<String> = [
        "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
        "int", "int8", "int16", "int32", "int64", "rune", "string",
        "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any", "comparable",
        "true", "false", "iota", "nil",
        "append", "cap", "clear", "close", "complex", "copy", "delete", "imag", "len",
        "make", "max", "min", "new", "panic", "print", "println", "real", "recover",
        "_",
    ]

    /// De `java.lang`, que entra sem import, mais as palavras que a gramática devolve
    /// como identificador.
    static let embutidosJava: Set<String> = [
        "String", "Object", "Integer", "Long", "Double", "Float", "Short", "Byte",
        "Character", "Boolean", "Number", "Math", "System", "Thread", "Runnable",
        "Comparable", "Iterable", "Class", "ClassLoader", "Enum", "Record", "Void",
        "StringBuilder", "StringBuffer", "CharSequence", "Runtime", "Process",
        "ProcessBuilder", "SecurityManager", "StackTraceElement", "ThreadLocal",
        "Throwable", "Exception", "RuntimeException", "Error", "AssertionError",
        "ArithmeticException", "ArrayIndexOutOfBoundsException", "ArrayStoreException",
        "ClassCastException", "ClassNotFoundException", "CloneNotSupportedException",
        "IllegalAccessException", "IllegalArgumentException", "IllegalStateException",
        "IndexOutOfBoundsException", "InstantiationException", "InterruptedException",
        "NegativeArraySizeException", "NoSuchFieldException", "NoSuchMethodException",
        "NullPointerException", "NumberFormatException", "OutOfMemoryError",
        "StackOverflowError", "StringIndexOutOfBoundsException", "UnsupportedOperationException",
        "Override", "Deprecated", "SuppressWarnings", "FunctionalInterface", "SafeVarargs",
        "Iterable", "AutoCloseable", "Cloneable", "Readable", "Appendable",
        "var", "this", "super", "length", "args", "main",
    ]

    /// O que existe sem ninguém declarar em JavaScript: a linguagem, o navegador, o Node e
    /// os arcabouços de teste. Faltar um nome aqui é acusar código certo, então a lista é
    /// larga de propósito — e é a razão de esta linguagem ter demorado a entrar.
    static let embutidosJS: Set<String> = [
        // A linguagem.
        "Object", "Function", "Boolean", "Symbol", "Error", "EvalError", "RangeError",
        "ReferenceError", "SyntaxError", "TypeError", "URIError", "AggregateError",
        "Number", "BigInt", "Math", "Date", "String", "RegExp", "Array", "JSON",
        "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array",
        "Int32Array", "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array",
        "BigUint64Array", "Map", "Set", "WeakMap", "WeakSet", "WeakRef",
        "FinalizationRegistry", "ArrayBuffer", "SharedArrayBuffer", "DataView", "Atomics",
        "Promise", "Reflect", "Proxy", "Intl", "Generator", "GeneratorFunction",
        "eval", "isFinite", "isNaN", "parseFloat", "parseInt", "decodeURI",
        "decodeURIComponent", "encodeURI", "encodeURIComponent", "escape", "unescape",
        "undefined", "NaN", "Infinity", "globalThis", "arguments", "console",
        // O navegador.
        "window", "document", "navigator", "location", "history", "screen", "alert",
        "confirm", "prompt", "fetch", "Headers", "Request", "Response", "FormData", "URL",
        "URLSearchParams", "Blob", "File", "FileList", "FileReader", "AbortController",
        "AbortSignal", "Event", "CustomEvent", "EventTarget", "MessageChannel",
        "MessagePort", "BroadcastChannel", "Worker", "SharedWorker", "ServiceWorker",
        "WebSocket", "XMLHttpRequest", "localStorage", "sessionStorage", "indexedDB",
        "crypto", "performance", "requestAnimationFrame", "cancelAnimationFrame",
        "requestIdleCallback", "setTimeout", "clearTimeout", "setInterval", "clearInterval",
        "queueMicrotask", "structuredClone", "getComputedStyle", "matchMedia",
        "IntersectionObserver", "MutationObserver", "ResizeObserver", "PerformanceObserver",
        "TextEncoder", "TextDecoder", "ReadableStream", "WritableStream", "TransformStream",
        "CompressionStream", "DecompressionStream", "Element", "Node", "NodeList", "Text",
        "Image", "Audio", "DOMParser", "XMLSerializer", "Range", "Selection", "Notification",
        "Storage", "CSS", "CSSStyleDeclaration", "SVGElement", "DOMRect", "DOMMatrix",
        "CanvasRenderingContext2D", "OffscreenCanvas", "ImageData", "Path2D", "Touch",
        "HTMLElement", "HTMLInputElement", "HTMLDivElement", "HTMLSpanElement",
        "HTMLButtonElement", "HTMLFormElement", "HTMLCanvasElement", "HTMLImageElement",
        "HTMLAnchorElement", "HTMLSelectElement", "HTMLTextAreaElement", "HTMLVideoElement",
        "HTMLAudioElement", "HTMLIFrameElement", "HTMLTableElement", "HTMLScriptElement",
        "HTMLStyleElement", "HTMLLabelElement", "HTMLOptionElement", "HTMLDialogElement",
        "TouchEvent", "KeyboardEvent", "MouseEvent", "PointerEvent", "FocusEvent",
        "InputEvent", "DragEvent", "WheelEvent", "ClipboardEvent", "ErrorEvent",
        "ProgressEvent", "MessageEvent", "CloseEvent", "PopStateEvent", "HashChangeEvent",
        "SubmitEvent", "AnimationEvent", "TransitionEvent", "StorageEvent", "UIEvent",
        "btoa", "atob", "reportError", "scrollTo", "scrollBy", "open", "close", "postMessage",
        "self", "top", "parent", "frames", "origin", "isSecureContext",
        // O Node.
        "process", "Buffer", "__dirname", "__filename", "require", "module", "exports",
        "global", "setImmediate", "clearImmediate", "NodeJS",
        // Os testes.
        "describe", "it", "test", "expect", "beforeEach", "afterEach", "beforeAll",
        "afterAll", "jest", "vi", "vitest", "suite", "bench", "assert",
    ]

    /// Palavras que são palavra-chave para quem lê e identificador para a gramática.
    /// `as const` é o caso que aparece todo dia: `const` ali chega como identificador
    /// comum, e sem esta lista a Odete diria que `const` não foi declarado. Nenhuma delas
    /// pode ser o nome de uma variável, então calar aqui não esconde erro nenhum.
    static let palavrasContextuais: Set<String> = [
        "const", "let", "type", "namespace", "module", "global", "declare", "abstract",
        "override", "accessor", "readonly", "unique", "infer", "asserts", "satisfies",
        "as", "is", "out", "of", "from", "async", "await", "yield", "get", "set", "static",
        "keyof", "typeof", "enum", "interface", "implements", "public", "private",
        "protected", "constructor", "target", "meta",
    ]

    /// Os tipos que o TypeScript traz sem biblioteca nenhuma.
    static let tiposTS: Set<String> = [
        "Partial", "Required", "Readonly", "Pick", "Record", "Omit", "Exclude", "Extract",
        "NonNullable", "Parameters", "ConstructorParameters", "ReturnType", "InstanceType",
        "ThisParameterType", "OmitThisParameter", "ThisType", "Awaited", "NoInfer",
        "Uppercase", "Lowercase", "Capitalize", "Uncapitalize", "ReadonlyArray",
        "ReadonlyMap", "ReadonlySet", "Iterable", "Iterator", "IterableIterator",
        "AsyncIterable", "AsyncIterator", "AsyncIterableIterator", "AsyncGenerator",
        "PromiseLike", "ArrayLike", "PropertyKey", "TemplateStringsArray", "JSX",
        "Exclude", "InstanceType", "ClassDecorator", "MethodDecorator", "PropertyDecorator",
        "ParameterDecorator", "WeakKeyTypes", "Uncapitalize",
    ]
}
