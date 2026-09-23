// Executor de testes embutido: o básico do vitest (describe/it/expect/vi) num processo só.
//
// O vitest de verdade não sobe no iPad: o vite 8 que ele carrega precisa do binário nativo do
// rolldown, e os pools dele rodam cada arquivo num worker_thread ou num processo filho. Aqui
// cada arquivo de teste é carregado pelo `require` da Odete (TS e ESM passam pelo esbuild do
// projeto), com o módulo "vitest" trocado por este — módulo embutido ganha de node_modules.
// A saída imita a do vitest (em inglês, como a dele) para quem já sabe lê-la.
//
// Roda como script principal; `process.argv[2]` traz, em JSON:
// { raiz, versao, arquivos: [caminhos absolutos], padrao, tempoLimite, detalhado }.
// Não é carregado no boot: JSRuntime.boot só avalia os módulos da lista dele.
"use strict";
const path = require("path");
const util = require("util");
const opcoes = JSON.parse(process.argv[2] || "{}");
const raiz = opcoes.raiz || process.cwd();
const agora = () => performance.now();
const rel = (f) => path.relative(raiz, f) || f;
const escreve = (s = "") => console.log(s);
const ms = (t) => `${Math.round(t)}ms`;
const padraoDeNome = opcoes.padrao ? new RegExp(opcoes.padrao) : null;
const limitePadrao = opcoes.tempoLimite || 5000;
const LINHA = "⎯";

// ---------------------------------------------------------------- árvore de testes

class Suite {
  constructor(nome, pai, modo, fabrica) {
    this.tipo = "suite"; this.nome = nome; this.pai = pai; this.modo = modo; this.fabrica = fabrica;
    this.filhos = []; this.erro = null;
    this.ganchos = { beforeAll: [], afterAll: [], beforeEach: [], afterEach: [] };
  }
}
class Teste {
  constructor(nome, pai, modo, fn, tempo) {
    this.tipo = "teste"; this.nome = nome; this.pai = pai; this.modo = modo; this.fn = fn; this.tempo = tempo;
    this.estado = "pendente"; this.erro = null; this.duracao = 0; this.esperaFalha = false;
  }
}
let atual = null; // a suíte que recebe o que describe/it/beforeEach registram agora

function formataNome(nome, linha, i) {
  const args = Array.isArray(linha) ? linha : [linha];
  let k = 0;
  let s = String(nome).replace(/%[sdifjoO#%]/g, (m) => {
    if (m === "%%") return "%";
    if (m === "%#") return String(i);
    const v = args[k++];
    if (m === "%s") return typeof v === "string" ? v : fmt(v);
    if (m === "%d" || m === "%f") return String(Number(v));
    if (m === "%i") return String(parseInt(v, 10));
    if (m === "%j") return JSON.stringify(v);
    return fmt(v);
  });
  if (linha && typeof linha === "object" && !Array.isArray(linha)) {
    s = s.replace(/\$([\w.]+)/g, (m, chave) => {
      const partes = chave.split(".");
      if (!(partes[0] in linha)) return m;
      let v = linha;
      for (const p of partes) v = v == null ? v : v[p];
      return typeof v === "string" ? v : fmt(v);
    });
  }
  return s;
}

// A tabela de `each` como template literal: `a | b` na primeira linha, depois ${valores}.
function linhasDaTabela(tabela, valores) {
  if (!(Array.isArray(tabela) && tabela.raw)) return tabela;
  const cabeca = tabela[0].split("|").map((x) => x.trim()).filter(Boolean);
  const linhas = [];
  for (let i = 0; i + cabeca.length <= valores.length; i += cabeca.length) {
    const o = {};
    cabeca.forEach((c, j) => { o[c] = valores[i + j]; });
    linhas.push(o);
  }
  return linhas;
}

function criaRegistro(tipo) {
  const registra = (modo, falha) => function (nome, a, b) {
    let fn = a, tempo = b, m = modo;
    if (a && typeof a === "object") {
      fn = b; tempo = a.timeout;
      if (a.skip) m = "skip"; if (a.only) m = "only"; if (a.todo) m = "todo"; if (a.fails) falha = true;
    }
    if (tempo && typeof tempo === "object") tempo = tempo.timeout;
    if (typeof fn !== "function" && m !== "skip") m = "todo";
    if (!atual) throw new Error(`${tipo === "suite" ? "describe" : "test"}() só pode ser chamado ao carregar um arquivo de teste`);
    const texto = typeof nome === "function" ? nome.name : String(nome);
    const item = tipo === "suite" ? new Suite(texto, atual, m, fn) : new Teste(texto, atual, m, fn, tempo);
    if (falha && item.tipo === "teste") item.esperaFalha = true;
    atual.filhos.push(item);
    return item;
  };
  const comEach = (f) => {
    f.each = (tabela, ...valores) => (nome, fn, tempo) => {
      linhasDaTabela(tabela, valores).forEach((linha, i) => {
        const args = Array.isArray(linha) ? linha : [linha];
        f(formataNome(nome, linha, i), typeof fn === "function" ? () => fn(...args) : fn, tempo);
      });
    };
    f.for = (tabela, ...valores) => (nome, fn, tempo) => {
      linhasDaTabela(tabela, valores).forEach((linha, i) => {
        f(formataNome(nome, linha, i), typeof fn === "function" ? (ctx) => fn(linha, ctx) : fn, tempo);
      });
    };
    return f;
  };
  const f = comEach(registra("run"));
  f.skip = comEach(registra("skip"));
  f.only = comEach(registra("only"));
  f.todo = comEach(registra("todo"));
  f.skipIf = (c) => (c ? f.skip : f);
  f.runIf = (c) => (c ? f : f.skip);
  f.concurrent = f; f.sequential = f; f.shuffle = f;
  f.skip.concurrent = f.skip; f.only.concurrent = f.only;
  if (tipo === "teste") f.fails = comEach(registra("run", true));
  f.extend = () => f; // fixtures do test.extend: o teste roda, mas sem os valores extras
  return f;
}
const describe = criaRegistro("suite");
const it = criaRegistro("teste");
const gancho = (tipo) => (fn, tempo) => {
  if (!atual) throw new Error(`${tipo}() só pode ser chamado ao carregar um arquivo de teste`);
  atual.ganchos[tipo].push({ fn, tempo: typeof tempo === "object" && tempo ? tempo.timeout : tempo });
};

// ---------------------------------------------------------------- formatação e igualdade

function fmt(v) {
  if (typeof v === "string") return JSON.stringify(v).replace(/^"|"$/g, "'");
  if (ehAssimetrico(v)) return v.toString();
  if (typeof v === "function") return v._isMockFunction ? `[MockFunction ${v.getMockName()}]` : `[Function${v.name ? " " + v.name : ""}]`;
  if (v instanceof Error) return `[${v.name}: ${v.message}]`;
  return util.inspect(v, { depth: 3 }).replace(/\s*\n\s*/g, " ");
}

// Uma forma estável e em várias linhas, para o diff de esperado × recebido.
function serializa(v, nivel = 0, vistos = new Set()) {
  const pad = "  ".repeat(nivel + 1), fim = "  ".repeat(nivel);
  if (typeof v === "string") return JSON.stringify(v);
  if (v === null || typeof v !== "object") return typeof v === "function" ? fmt(v) : typeof v === "bigint" ? v + "n" : String(v);
  if (ehAssimetrico(v)) return v.toString();
  if (vistos.has(v)) return "[Circular]";
  if (v instanceof Date || v instanceof RegExp || v instanceof Error) return fmt(v);
  vistos.add(v);
  try {
    if (Array.isArray(v) || ArrayBuffer.isView(v)) {
      const a = Array.from(v);
      return a.length ? `${Array.isArray(v) ? "" : v.constructor.name + " "}[\n${a.map((x) => pad + serializa(x, nivel + 1, vistos) + ",").join("\n")}\n${fim}]` : "[]";
    }
    if (v instanceof Map) return `Map {\n${[...v].map(([k, x]) => pad + serializa(k, nivel + 1, vistos) + " => " + serializa(x, nivel + 1, vistos) + ",").join("\n")}\n${fim}}`;
    if (v instanceof Set) return `Set {\n${[...v].map((x) => pad + serializa(x, nivel + 1, vistos) + ",").join("\n")}\n${fim}}`;
    const ks = Object.keys(v).sort();
    const nome = v.constructor && v.constructor !== Object && v.constructor.name ? v.constructor.name + " " : "";
    return ks.length ? `${nome}{\n${ks.map((k) => pad + JSON.stringify(k) + ": " + serializa(v[k], nivel + 1, vistos) + ",").join("\n")}\n${fim}}` : nome + "{}";
  } finally { vistos.delete(v); }
}

// Diff por linhas (maior subsequência comum), no formato do vitest.
function diff(esperado, recebido) {
  const a = serializa(esperado).split("\n"), b = serializa(recebido).split("\n");
  const saida = ["- Expected", "+ Received", ""];
  if (a.length * b.length > 250000) return saida.concat(a.map((l) => "- " + l), b.map((l) => "+ " + l)).join("\n");
  const t = Array.from({ length: a.length + 1 }, () => new Int32Array(b.length + 1));
  for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) t[i][j] = a[i] === b[j] ? t[i + 1][j + 1] + 1 : Math.max(t[i + 1][j], t[i][j + 1]);
  let i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { saida.push("  " + a[i]); i++; j++; }
    else if (t[i + 1][j] >= t[i][j + 1]) saida.push("- " + a[i++]);
    else saida.push("+ " + b[j++]);
  }
  while (i < a.length) saida.push("- " + a[i++]);
  while (j < b.length) saida.push("+ " + b[j++]);
  return saida.join("\n");
}

class Assimetrico {
  constructor(nome, amostra, teste, inverso = false) { this.nome = nome; this.amostra = amostra; this.teste = teste; this.inverso = inverso; }
  asymmetricMatch(v) { const r = !!this.teste(v); return this.inverso ? !r : r; }
  toString() { const n = (this.inverso ? "Not" : "") + this.nome; return this.amostra === undefined ? n : `${n} ${typeof this.amostra === "function" ? this.amostra.name : fmt(this.amostra)}`; }
}
const ehAssimetrico = (v) => v != null && typeof v === "object" && typeof v.asymmetricMatch === "function";

function iguais(a, b, estrito, vistos = []) {
  if (ehAssimetrico(b)) return b.asymmetricMatch(a);
  if (ehAssimetrico(a)) return a.asymmetricMatch(b);
  if (Object.is(a, b)) return true;
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  const ta = Object.prototype.toString.call(a);
  if (ta !== Object.prototype.toString.call(b)) return false;
  if (estrito && Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
  if (a instanceof Date) return Object.is(a.getTime(), b.getTime());
  if (a instanceof RegExp) return a.source === b.source && a.flags === b.flags;
  if (a instanceof Error && (a.name !== b.name || a.message !== b.message)) return false;
  for (const [x, y] of vistos) if (x === a && y === b) return true;
  vistos.push([a, b]);
  try {
    if (a instanceof Map) {
      if (a.size !== b.size) return false;
      for (const [k, v] of a) if (!b.has(k) || !iguais(v, b.get(k), estrito, vistos)) return false;
      return true;
    }
    if (a instanceof Set) {
      if (a.size !== b.size) return false;
      for (const v of a) if (!b.has(v) && ![...b].some((w) => iguais(v, w, estrito, vistos))) return false;
      return true;
    }
    if (ArrayBuffer.isView(a)) {
      if (a.length !== b.length) return false;
      for (let i = 0; i < a.length; i++) if (!Object.is(a[i], b[i])) return false;
      return true;
    }
    if (Array.isArray(a)) {
      if (a.length !== b.length) return false;
      for (let i = 0; i < a.length; i++) {
        if (estrito && (i in a) !== (i in b)) return false;
        if (!iguais(a[i], b[i], estrito, vistos)) return false;
      }
      return true;
    }
    // toEqual ignora propriedades com undefined; toStrictEqual não.
    const chaves = (o) => (estrito ? Object.keys(o) : Object.keys(o).filter((k) => o[k] !== undefined));
    const ka = chaves(a), kb = chaves(b);
    if (ka.length !== kb.length) return false;
    for (const k of ka) {
      if (estrito && !Object.prototype.hasOwnProperty.call(b, k)) return false;
      if (!iguais(a[k], b[k], estrito, vistos)) return false;
    }
    return true;
  } finally { vistos.pop(); }
}

// `recebido` tem tudo o que `parte` tem (toMatchObject, objectContaining).
function contem(recebido, parte) {
  if (ehAssimetrico(parte)) return parte.asymmetricMatch(recebido);
  if (Array.isArray(parte)) return Array.isArray(recebido) && recebido.length === parte.length && parte.every((v, i) => contem(recebido[i], v));
  if (parte !== null && typeof parte === "object" && Object.getPrototypeOf(parte) === Object.prototype) {
    if (recebido === null || typeof recebido !== "object") return false;
    return Object.keys(parte).every((k) => k in recebido && contem(recebido[k], parte[k]));
  }
  return iguais(recebido, parte, false);
}

// ---------------------------------------------------------------- expect

class AssertionError extends Error {
  constructor(mensagem, extra) { super(mensagem); this.name = "AssertionError"; Object.assign(this, extra); }
}
let afirmacoes = 0, afirmacoesEsperadas = null, exigeAfirmacao = false;

function ehEspiao(v) { return typeof v === "function" && v._isMockFunction; }
function exigeEspiao(v) { if (!ehEspiao(v)) throw new TypeError(`${fmt(v)} is not a spy or a call to a spy!`); return v.mock; }
const vezes = (n) => `${n} time${n === 1 ? "" : "s"}`;
const naoTexto = (nao) => (nao ? "not " : "");

// Cada matcher devolve { pass, mensagem(nao), esperado?, recebido?, diff? }.
const matchers = {
  toBe(r, e) { return { pass: Object.is(r, e), mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be ${fmt(e)} // Object.is equality`, esperado: e, recebido: r, diff: true }; },
  toEqual(r, e) { return { pass: iguais(r, e, false), mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to deeply equal ${fmt(e)}`, esperado: e, recebido: r, diff: true }; },
  toStrictEqual(r, e) { return { pass: iguais(r, e, true), mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to strictly equal ${fmt(e)}`, esperado: e, recebido: r, diff: true }; },
  toBeTruthy(r) { return { pass: !!r, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be truthy` }; },
  toBeFalsy(r) { return { pass: !r, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be falsy` }; },
  toBeNull(r) { return { pass: r === null, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be null` }; },
  toBeUndefined(r) { return { pass: r === undefined, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be undefined` }; },
  toBeDefined(r) { return { pass: r !== undefined, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be defined` }; },
  toBeNaN(r) { return { pass: Number.isNaN(r), mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be NaN` }; },
  toBeGreaterThan(r, e) { return { pass: r > e, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be greater than ${fmt(e)}` }; },
  toBeGreaterThanOrEqual(r, e) { return { pass: r >= e, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be greater than or equal to ${fmt(e)}` }; },
  toBeLessThan(r, e) { return { pass: r < e, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be less than ${fmt(e)}` }; },
  toBeLessThanOrEqual(r, e) { return { pass: r <= e, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be less than or equal to ${fmt(e)}` }; },
  toBeCloseTo(r, e, digitos = 2) { return { pass: Math.abs(r - e) < 10 ** -digitos / 2, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be close to ${fmt(e)} (${digitos} digits)` }; },
  toBeInstanceOf(r, C) { return { pass: r instanceof C, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be an instance of ${C && C.name}` }; },
  toBeTypeOf(r, t) { return { pass: typeof r === t, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be type of '${t}'` }; },
  toBeOneOf(r, lista) { return { pass: lista.some((x) => iguais(r, x, false)), mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to be one of ${fmt(lista)}` }; },
  toSatisfy(r, f) { return { pass: !!f(r), mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to satisfy ${fmt(f)}` }; },
  toContain(r, item) {
    const pass = typeof r === "string" ? r.includes(item) : r != null && typeof r[Symbol.iterator] === "function" && [...r].includes(item);
    return { pass, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to include ${fmt(item)}` };
  },
  toContainEqual(r, item) { return { pass: [...r].some((x) => iguais(x, item, false)), mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to deep equally contain ${fmt(item)}` }; },
  toHaveLength(r, len) { return { pass: r != null && r.length === len, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to have a length of ${len} but got ${r == null ? r : r.length}` }; },
  toHaveProperty(r, caminho, ...valor) {
    const partes = Array.isArray(caminho) ? caminho : String(caminho).replace(/\[(\w+)\]/g, ".$1").split(".").filter((x) => x !== "");
    let v = r, tem = true;
    for (const p of partes) { if (v == null || !(p in Object(v))) { tem = false; break; } v = v[p]; }
    const pass = tem && (valor.length === 0 || iguais(v, valor[0], false));
    return { pass, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to have property "${partes.join(".")}"${valor.length ? ` with value ${fmt(valor[0])}` : ""}`, esperado: valor[0], recebido: v, diff: valor.length > 0 && tem };
  },
  toMatch(r, e) { const pass = typeof r === "string" && (typeof e === "string" ? r.includes(e) : e.test(r)); return { pass, mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to ${typeof e === "string" ? "include" : "match"} ${typeof e === "string" ? fmt(e) : String(e)}` }; },
  toMatchObject(r, e) { return { pass: contem(r, e), mensagem: (n) => `expected ${fmt(r)} ${naoTexto(n)}to match object ${fmt(e)}`, esperado: e, recebido: r, diff: true }; },
  toThrow(r, esperado) {
    let erro, lancou = false;
    if (this.promessa === "rejects") { erro = r; lancou = true; }
    else {
      if (typeof r !== "function") throw new TypeError(`${fmt(r)} is not a function`);
      try { r(); } catch (e) { erro = e; lancou = true; }
    }
    const msg = erro && typeof erro === "object" ? erro.message : String(erro);
    let pass = lancou;
    if (lancou && esperado !== undefined) {
      if (typeof esperado === "string") pass = String(msg).includes(esperado);
      else if (esperado instanceof RegExp) pass = esperado.test(String(msg));
      else if (typeof esperado === "function") pass = erro instanceof esperado;
      else if (ehAssimetrico(esperado)) pass = esperado.asymmetricMatch(erro);
      else if (esperado instanceof Error) pass = msg === esperado.message;
      else if (typeof esperado === "object") pass = contem(erro, esperado);
    }
    const alvo = esperado === undefined ? "" : typeof esperado === "function" ? ` an instance of ${esperado.name}` : esperado instanceof RegExp ? ` an error matching ${esperado}` : ` an error including ${fmt(esperado instanceof Error ? esperado.message : esperado)}`;
    return { pass, mensagem: (n) => (lancou ? `expected function ${naoTexto(n)}to throw${alvo || " an error"}, but got ${fmt(erro)}` : `expected function ${naoTexto(n)}to throw${alvo || " an error"}, but it didn't throw`) };
  },
  toHaveBeenCalled(r) { const m = exigeEspiao(r); return { pass: m.calls.length > 0, mensagem: (n) => `expected "${r.getMockName()}" ${naoTexto(n)}to be called at least once` }; },
  toHaveBeenCalledTimes(r, k) { const m = exigeEspiao(r); return { pass: m.calls.length === k, mensagem: (n) => `expected "${r.getMockName()}" ${naoTexto(n)}to be called ${vezes(k)}, but got ${vezes(m.calls.length)}` }; },
  toHaveBeenCalledWith(r, ...args) { const m = exigeEspiao(r); return { pass: m.calls.some((c) => iguais(c, args, false)), mensagem: (n) => `expected "${r.getMockName()}" ${naoTexto(n)}to be called with arguments: ${fmt(args)}\nReceived calls: ${m.calls.map(fmt).join(", ") || "none"}` }; },
  toHaveBeenLastCalledWith(r, ...args) { const m = exigeEspiao(r); const u = m.calls[m.calls.length - 1]; return { pass: !!u && iguais(u, args, false), mensagem: (n) => `expected last "${r.getMockName()}" call ${naoTexto(n)}to have been called with ${fmt(args)}, but got ${fmt(u)}` }; },
  toHaveBeenNthCalledWith(r, k, ...args) { const m = exigeEspiao(r); const c = m.calls[k - 1]; return { pass: !!c && iguais(c, args, false), mensagem: (n) => `expected ${k}th "${r.getMockName()}" call ${naoTexto(n)}to have been called with ${fmt(args)}, but got ${fmt(c)}` }; },
  toHaveReturned(r) { const m = exigeEspiao(r); return { pass: m.results.some((x) => x.type === "return"), mensagem: (n) => `expected "${r.getMockName()}" ${naoTexto(n)}to be successfully called at least once` }; },
  toHaveReturnedTimes(r, k) { const m = exigeEspiao(r); const q = m.results.filter((x) => x.type === "return").length; return { pass: q === k, mensagem: (n) => `expected "${r.getMockName()}" ${naoTexto(n)}to be successfully called ${vezes(k)}, but got ${vezes(q)}` }; },
  toHaveReturnedWith(r, v) { const m = exigeEspiao(r); return { pass: m.results.some((x) => x.type === "return" && iguais(x.value, v, false)), mensagem: (n) => `expected "${r.getMockName()}" ${naoTexto(n)}to return with: ${fmt(v)} at least once` }; },
  toHaveLastReturnedWith(r, v) { const m = exigeEspiao(r); const u = m.results[m.results.length - 1]; return { pass: !!u && u.type === "return" && iguais(u.value, v, false), mensagem: (n) => `expected last "${r.getMockName()}" call ${naoTexto(n)}to return ${fmt(v)}` }; },
  toMatchSnapshot() { throw new Error("Odete: snapshots ainda não existem no executor embutido de testes"); },
  toMatchInlineSnapshot() { throw new Error("Odete: snapshots ainda não existem no executor embutido de testes"); },
  toMatchFileSnapshot() { throw new Error("Odete: snapshots ainda não existem no executor embutido de testes"); },
};
const apelidos = { toBeCalled: "toHaveBeenCalled", toBeCalledTimes: "toHaveBeenCalledTimes", toBeCalledWith: "toHaveBeenCalledWith", lastCalledWith: "toHaveBeenLastCalledWith", nthCalledWith: "toHaveBeenNthCalledWith", toReturn: "toHaveReturned", toReturnTimes: "toHaveReturnedTimes", toReturnWith: "toHaveReturnedWith", lastReturnedWith: "toHaveLastReturnedWith", toThrowError: "toThrow" };

class Afirmacao {
  constructor(recebido, nao, promessa, rotulo) { this.recebido = recebido; this.nao = nao; this.promessa = promessa; this.rotulo = rotulo; }
  get not() { return new Afirmacao(this.recebido, !this.nao, this.promessa, this.rotulo); }
  get resolves() { return new Afirmacao(this.recebido, this.nao, "resolves", this.rotulo); }
  get rejects() { return new Afirmacao(this.recebido, this.nao, "rejects", this.rotulo); }
}
function aplica(a, nome, matcher, recebido, args) {
  const r = matcher.call({ isNot: a.nao, promessa: a.promessa, equals: (x, y) => iguais(x, y, false), utils: { stringify: fmt, printReceived: fmt, printExpected: fmt } }, recebido, ...args);
  if (!!r.pass === a.nao) {
    const texto = typeof r.mensagem === "function" ? r.mensagem(a.nao) : typeof r.message === "function" ? r.message() : `${nome} falhou`;
    const extra = r.diff && !a.nao ? { esperado: r.esperado, recebido: r.recebido, mostraDiff: true } : {};
    throw new AssertionError((a.rotulo ? a.rotulo + ": " : "") + texto, extra);
  }
}
function defineMatcher(nome, matcher) {
  Afirmacao.prototype[nome] = function (...args) {
    afirmacoes++;
    if (!this.promessa) { aplica(this, nome, matcher, this.recebido, args); return; }
    const modo = this.promessa;
    return Promise.resolve(this.recebido).then(
      (v) => { if (modo === "rejects") throw new AssertionError(`promise resolved ${fmt(v)} instead of rejecting`); aplica(this, nome, matcher, v, args); },
      (e) => { if (modo === "resolves") throw new AssertionError(`promise rejected ${fmt(e)} instead of resolving`); aplica(this, nome, matcher, e, args); },
    );
  };
}
for (const [nome, m] of Object.entries(matchers)) defineMatcher(nome, m);
for (const [apelido, nome] of Object.entries(apelidos)) defineMatcher(apelido, matchers[nome]);

function expect(recebido, rotulo) { return new Afirmacao(recebido, false, null, rotulo); }
expect.soft = expect;
expect.any = (C) => new Assimetrico("Any", C, (v) => (C === String ? typeof v === "string" || v instanceof String : C === Number ? typeof v === "number" || v instanceof Number : C === Boolean ? typeof v === "boolean" || v instanceof Boolean : C === BigInt ? typeof v === "bigint" : C === Symbol ? typeof v === "symbol" : C === Function ? typeof v === "function" : C === Object ? v !== null && typeof v === "object" : v instanceof C));
expect.anything = () => new Assimetrico("Anything", undefined, (v) => v != null);
const assimetricos = (inverso) => ({
  objectContaining: (o) => new Assimetrico("ObjectContaining", o, (v) => v != null && typeof v === "object" && Object.keys(o).every((k) => k in v && iguais(v[k], o[k], false)), inverso),
  arrayContaining: (arr) => new Assimetrico("ArrayContaining", arr, (v) => Array.isArray(v) && arr.every((x) => v.some((y) => iguais(y, x, false))), inverso),
  stringContaining: (s) => new Assimetrico("StringContaining", s, (v) => typeof v === "string" && v.includes(s), inverso),
  stringMatching: (r) => new Assimetrico("StringMatching", r, (v) => typeof v === "string" && (typeof r === "string" ? new RegExp(r) : r).test(v), inverso),
  closeTo: (x, d = 2) => new Assimetrico("CloseTo", x, (v) => typeof v === "number" && Math.abs(v - x) < 10 ** -d / 2, inverso),
});
Object.assign(expect, assimetricos(false));
expect.not = assimetricos(true);
expect.assertions = (n) => { afirmacoesEsperadas = n; };
expect.hasAssertions = () => { exigeAfirmacao = true; };
expect.unreachable = (msg) => { throw new AssertionError(msg ? `expected not to be reached: ${msg}` : "expected not to be reached"); };
expect.extend = (novos) => {
  for (const [nome, fn] of Object.entries(novos)) {
    defineMatcher(nome, function (recebido, ...args) {
      const r = fn.call(this, recebido, ...args);
      return { pass: r.pass, mensagem: () => (typeof r.message === "function" ? r.message() : String(r.message || nome)) };
    });
  }
};
expect.addEqualityTesters = () => {};
expect.getState = () => ({ assertionCalls: afirmacoes, currentTestName: testeAtual ? nomeCompleto(testeAtual) : undefined });

// ---------------------------------------------------------------- vi

const espioes = new Set();
let ordemDeChamada = 0;
function criaMock(impl, restaurar) {
  let padrao = impl, umaVez = [], nome = "spy";
  const estado = { calls: [], results: [], instances: [], contexts: [], invocationCallOrder: [], lastCall: undefined };
  function mock(...args) {
    estado.calls.push(args); estado.lastCall = args; estado.instances.push(this); estado.contexts.push(this);
    estado.invocationCallOrder.push(++ordemDeChamada);
    const f = umaVez.length ? umaVez.shift() : padrao;
    const i = estado.results.push({ type: "incomplete", value: undefined }) - 1;
    try {
      const v = f ? (new.target ? Reflect.construct(f, args, new.target) : f.apply(this, args)) : undefined;
      estado.results[i] = { type: "return", value: v };
      return v;
    } catch (e) {
      estado.results[i] = { type: "throw", value: e };
      throw e;
    }
  }
  const limpa = () => { for (const k of ["calls", "results", "instances", "contexts", "invocationCallOrder"]) estado[k] = []; estado.lastCall = undefined; };
  Object.assign(mock, {
    _isMockFunction: true, mock: estado,
    getMockName: () => nome, mockName: (n) => { nome = n; return mock; },
    getMockImplementation: () => padrao,
    mockImplementation: (f) => { padrao = f; return mock; },
    mockImplementationOnce: (f) => { umaVez.push(f); return mock; },
    mockReturnValue: (v) => mock.mockImplementation(() => v),
    mockReturnValueOnce: (v) => mock.mockImplementationOnce(() => v),
    mockResolvedValue: (v) => mock.mockImplementation(() => Promise.resolve(v)),
    mockResolvedValueOnce: (v) => mock.mockImplementationOnce(() => Promise.resolve(v)),
    mockRejectedValue: (e) => mock.mockImplementation(() => Promise.reject(e)),
    mockRejectedValueOnce: (e) => mock.mockImplementationOnce(() => Promise.reject(e)),
    mockReturnThis: () => mock.mockImplementation(function () { return this; }),
    mockClear: () => { limpa(); return mock; },
    mockReset: () => { limpa(); padrao = impl; umaVez = []; return mock; },
    mockRestore: () => { mock.mockReset(); if (restaurar) restaurar(); espioes.delete(mock); return mock; },
    withImplementation: (f, corpo) => { const antes = padrao; padrao = f; const r = corpo(); if (r && typeof r.then === "function") return r.finally(() => { padrao = antes; }); padrao = antes; return r; },
  });
  espioes.add(mock);
  return mock;
}
const naoExiste = (api, porque) => () => { throw new Error(`Odete: vi.${api} ainda não existe no executor embutido de testes (${porque})`); };
const globaisTrocados = new Map(), envsTrocados = new Map();
const vi = {
  fn: (impl) => criaMock(impl),
  spyOn(obj, metodo, acesso) {
    let dono = obj, d;
    while (dono && !(d = Object.getOwnPropertyDescriptor(dono, metodo))) dono = Object.getPrototypeOf(dono);
    if (!d) throw new TypeError(`${String(metodo)} does not exist`);
    const proprio = dono === obj;
    const restaura = () => { if (proprio) Object.defineProperty(obj, metodo, d); else delete obj[metodo]; };
    if (!proprio || d.configurable !== false) {
      if (acesso === "get" || acesso === "set") {
        const m = criaMock(d[acesso], restaura);
        Object.defineProperty(obj, metodo, { ...d, [acesso]: m, configurable: true });
        return m;
      }
      const original = d.get ? d.get.call(obj) : d.value;
      if (typeof original !== "function") throw new TypeError(`${String(metodo)} is not a function`);
      const m = criaMock(original, restaura);
      Object.defineProperty(obj, metodo, { value: m, writable: true, configurable: true, enumerable: d.enumerable });
      return m;
    }
    throw new TypeError(`Odete: não dá para espionar ${String(metodo)}: a propriedade não é configurável (export de módulo ES?)`);
  },
  isMockFunction: ehEspiao,
  mocked: (x) => x,
  clearAllMocks() { for (const m of espioes) m.mockClear(); return vi; },
  resetAllMocks() { for (const m of espioes) m.mockReset(); return vi; },
  restoreAllMocks() { for (const m of [...espioes]) m.mockRestore(); return vi; },
  stubGlobal(k, v) { if (!globaisTrocados.has(k)) globaisTrocados.set(k, Object.getOwnPropertyDescriptor(globalThis, k)); globalThis[k] = v; return vi; },
  unstubAllGlobals() { for (const [k, d] of globaisTrocados) { if (d) Object.defineProperty(globalThis, k, d); else delete globalThis[k]; } globaisTrocados.clear(); return vi; },
  stubEnv(k, v) { if (!envsTrocados.has(k)) envsTrocados.set(k, process.env[k]); process.env[k] = v; return vi; },
  unstubAllEnvs() { for (const [k, v] of envsTrocados) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } envsTrocados.clear(); return vi; },
  async waitFor(fn, o = {}) {
    const limite = typeof o === "number" ? o : o.timeout ?? 1000, passo = o.interval ?? 50, t0 = agora();
    for (;;) {
      try { return await fn(); } catch (e) { if (agora() - t0 > limite) throw e; }
      await new Promise((r) => setTimeout(r, passo));
    }
  },
  hoisted: (f) => f(),
  mock: naoExiste("mock", "trocar módulos exige interceptar o carregamento; injete a dependência ou use vi.spyOn"),
  doMock: naoExiste("doMock", "trocar módulos exige interceptar o carregamento"),
  unmock() {}, doUnmock() {},
  importActual: naoExiste("importActual", "trocar módulos exige interceptar o carregamento"),
  importMock: naoExiste("importMock", "trocar módulos exige interceptar o carregamento"),
  useFakeTimers: naoExiste("useFakeTimers", "relógio falso"),
  useRealTimers: () => vi,
  setSystemTime: naoExiste("setSystemTime", "relógio falso"),
};
for (const f of ["advanceTimersByTime", "advanceTimersByTimeAsync", "runAllTimers", "runAllTimersAsync", "runOnlyPendingTimers", "advanceTimersToNextTimer"]) vi[f] = naoExiste(f, "relógio falso");

// Tipos só existem para o tsc: em tempo de execução, qualquer cadeia vale.
const semTipo = new Proxy(function () {}, { get: () => semTipo, apply: () => semTipo });

// ---------------------------------------------------------------- execução

let testeAtual = null;
class Pulo extends Error {}

function nomeCompleto(t) {
  const partes = [];
  for (let s = t; s && s.pai; s = s.pai) partes.unshift(s.nome);
  return partes.join(" > ");
}
function comLimite(fn, args, limite, oque) {
  return new Promise((ok, falha) => {
    let feito = false;
    const relogio = limite > 0 ? setTimeout(() => { if (!feito) { feito = true; falha(new Error(`${oque} timed out in ${limite}ms.`)); } }, limite) : null;
    const fim = (f) => (v) => { if (feito) return; feito = true; if (relogio) clearTimeout(relogio); f(v); };
    try { Promise.resolve(fn(...args)).then(fim(ok), fim(falha)); } catch (e) { fim(falha)(e); }
  });
}

// Roda as fábricas dos describe na ordem, depois que o arquivo inteiro carregou (como o vitest).
async function coletar(s) {
  for (const f of s.filhos) {
    if (f.tipo !== "suite" || typeof f.fabrica !== "function") continue;
    const antes = atual;
    atual = f;
    try { await f.fabrica(); } catch (e) { f.erro = e; }
    atual = antes;
    await coletar(f);
  }
}

// skip e todo descem pela árvore; `only` num arquivo deixa de fora tudo o que não é only.
function decide(s, herdado, temOnly, dentroDoOnly) {
  for (const f of s.filhos) {
    const modo = herdado !== "run" ? herdado : f.modo === "only" ? "run" : f.modo;
    const noOnly = dentroDoOnly || f.modo === "only";
    if (f.tipo === "suite") decide(f, modo, temOnly, noOnly);
    else f.decisao = modo !== "run" ? modo : temOnly && !noOnly ? "skip" : padraoDeNome && !padraoDeNome.test(nomeCompleto(f).replace(/ > /g, " ")) ? "skip" : "run";
  }
}
const comErroInterno = (s) => !!s.erro || s.filhos.some((f) => f.tipo === "suite" && comErroInterno(f));
const algumOnly = (s) => s.filhos.some((f) => f.modo === "only" || (f.tipo === "suite" && algumOnly(f)));
const testesDe = (s) => s.filhos.flatMap((f) => (f.tipo === "suite" ? testesDe(f) : [f]));
const ancestrais = (s) => { const a = []; for (let x = s; x; x = x.pai) a.unshift(x); return a; };

async function rodarSuite(s, erroHerdado) {
  const testes = testesDe(s);
  if (!testes.some((t) => t.decisao === "run")) {
    for (const t of testes) t.estado = t.decisao === "todo" ? "todo" : "skip";
    return;
  }
  let erro = erroHerdado || s.erro;
  const depois = [...s.ganchos.afterAll];
  if (!erro) {
    for (const g of s.ganchos.beforeAll) {
      try { const r = await comLimite(g.fn, [{}], g.tempo ?? 10000, "Hook"); if (typeof r === "function") depois.unshift({ fn: r }); } catch (e) { erro = e; break; }
    }
  }
  for (const f of s.filhos) {
    if (f.tipo === "suite") await rodarSuite(f, erro);
    else await rodarTeste(f, erro);
  }
  for (const g of depois) {
    try { await comLimite(g.fn, [{}], g.tempo ?? 10000, "Hook"); } catch (e) { errosSoltos.push(e); }
  }
}

async function rodarTeste(t, erroHerdado) {
  if (t.decisao !== "run") { t.estado = t.decisao === "todo" ? "todo" : "skip"; return; }
  const t0 = agora();
  testeAtual = t; afirmacoes = 0; afirmacoesEsperadas = null; exigeAfirmacao = false;
  const limpezas = (t.limpezas = []);
  const cadeia = ancestrais(t.pai);
  const ctx = {
    task: { name: t.nome, type: "test" }, expect,
    skip: (c) => { if (c === undefined || c === true) throw new Pulo(); },
    onTestFinished: (f) => limpezas.push(f), onTestFailed: () => {}, signal: new AbortController().signal,
  };
  let erro = erroHerdado;
  if (!erro) {
    try {
      for (const s of cadeia) for (const g of s.ganchos.beforeEach) {
        const r = await comLimite(g.fn, [ctx], g.tempo ?? 10000, "Hook");
        if (typeof r === "function") limpezas.unshift(r);
      }
      await comLimite(t.fn, [ctx], t.tempo ?? limitePadrao, "Test");
      if (afirmacoesEsperadas !== null && afirmacoes !== afirmacoesEsperadas) throw new AssertionError(`expected number of assertions to be ${afirmacoesEsperadas}, but got ${afirmacoes}`);
      if (exigeAfirmacao && afirmacoes === 0) throw new AssertionError("expected any number of assertion, but got none");
    } catch (e) { erro = e; }
  }
  for (const s of [...cadeia].reverse()) for (const g of s.ganchos.afterEach) {
    try { await comLimite(g.fn, [ctx], g.tempo ?? 10000, "Hook"); } catch (e) { erro = erro || e; }
  }
  for (const f of limpezas) { try { await f(); } catch (e) { erro = erro || e; } }
  testeAtual = null;
  t.duracao = agora() - t0;
  if (erro instanceof Pulo) { t.estado = "skip"; return; }
  if (t.esperaFalha) { t.estado = erro ? "pass" : "fail"; if (!erro) t.erro = new AssertionError("Expect test to fail"); return; }
  t.estado = erro ? "fail" : "pass";
  t.erro = erro || null;
}

// ---------------------------------------------------------------- saída

function descreveErro(e) {
  if (!(e instanceof Error)) return `Error: ${fmt(e)}`;
  let s = `${e.name || "Error"}: ${e.message}`;
  if (e.mostraDiff) s += "\n\n" + diff(e.esperado, e.recebido);
  else if (!(e instanceof AssertionError) && e.stack) {
    // Só os quadros do projeto. Em TS a linha é a do código que o esbuild gerou, não a do fonte.
    const pilha = String(e.stack).split("\n").filter((l) => l.includes(raiz + "/") && !l.includes("/node_modules/")).slice(0, 3);
    if (pilha.length) s += "\n" + pilha.map((l) => " ❯ " + l.trim().replace(raiz + "/", "")).join("\n");
  }
  return s;
}
const plural = (n, palavra) => `${n} ${palavra}${n === 1 ? "" : "s"}`;
function contagem(itens, rotulo) {
  const q = (e) => itens.filter((x) => x.estado === e).length;
  const partes = [];
  if (q("fail")) partes.push(`${q("fail")} failed`);
  if (q("pass")) partes.push(`${q("pass")} passed`);
  if (q("skip")) partes.push(`${q("skip")} skipped`);
  if (q("todo")) partes.push(`${q("todo")} todo`);
  return `${rotulo}  ${partes.join(" | ") || "no tests"} (${itens.length})`;
}

const errosSoltos = [];
process.on("uncaughtException", (e) => errosSoltos.push(e));

// O módulo "vitest" que os testes importam. Módulo embutido ganha de node_modules no require.
const api = {
  describe, suite: describe, it, test: it, expect, vi, vitest: vi,
  beforeAll: gancho("beforeAll"), afterAll: gancho("afterAll"), beforeEach: gancho("beforeEach"), afterEach: gancho("afterEach"),
  onTestFinished: (f) => { if (testeAtual) testeAtual.limpezas.push(f); }, onTestFailed: () => {},
  assert: require("assert"), expectTypeOf: () => semTipo, assertType: () => {},
  bench: it.skip, inject: () => undefined,
};
__nodeDefine("vitest", (module) => { module.exports = api; });
// `globals: true` do vitest: os mesmos nomes sem import. Não atrapalha quem importa.
for (const k of ["describe", "suite", "it", "test", "expect", "vi", "beforeAll", "afterAll", "beforeEach", "afterEach"]) globalThis[k] = api[k];

async function principal() {
  const inicio = agora();
  const relogio = new Date();
  escreve(` RUN  v${opcoes.versao || "?"} ${raiz}`);
  escreve("");
  const arquivos = [];
  for (const arquivo of opcoes.arquivos || []) {
    const t0 = agora();
    const s = new Suite(rel(arquivo), null, "run", null);
    s.arquivo = arquivo;
    arquivos.push(s);
    // Isolamento como o do vitest (um registro de módulos por arquivo), menos node_modules:
    // o código do projeto carrega de novo, as dependências não.
    for (const k of Object.keys(require.cache)) if (!k.includes("/node_modules/")) delete require.cache[k];
    atual = s;
    try { require(arquivo); await coletar(s); } catch (e) { s.erro = e; }
    atual = null;
    decide(s, "run", algumOnly(s), false);
    if (!s.erro) await rodarSuite(s, null);
    s.duracao = agora() - t0;
    // O vitest isola cada arquivo; aqui o mínimo é desfazer o que os testes trocaram.
    vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.unstubAllEnvs();
    const testes = testesDe(s);
    const falhos = testes.filter((t) => t.estado === "fail");
    const pulados = testes.filter((t) => t.estado === "skip" || t.estado === "todo").length;
    s.estado = comErroInterno(s) || falhos.length ? "fail" : testes.length && pulados === testes.length ? "skip" : "pass";
    const resumo = [plural(testes.length, "test")];
    if (falhos.length) resumo.push(`${falhos.length} failed`);
    if (pulados) resumo.push(`${pulados} skipped`);
    escreve(` ${s.estado === "fail" ? "❯" : s.estado === "skip" ? "↓" : "✓"} ${rel(arquivo)} (${resumo.join(" | ")}) ${ms(s.duracao)}`);
    for (const t of testes) {
      if (t.estado === "fail") { escreve(`   × ${nomeCompleto(t)} ${ms(t.duracao)}`); escreve(`     → ${String(t.erro && t.erro.message || t.erro).split("\n")[0]}`); }
      else if (opcoes.detalhado) escreve(`   ${t.estado === "pass" ? "✓" : "↓"} ${nomeCompleto(t)}${t.estado === "pass" ? " " + ms(t.duracao) : ""}`);
    }
  }
  const comErro = (s) => [...(s.erro ? [s] : []), ...s.filhos.filter((f) => f.tipo === "suite").flatMap(comErro)];
  const suitesFalhas = arquivos.flatMap(comErro);
  const todos = arquivos.flatMap(testesDe);
  const falhos = todos.filter((t) => t.estado === "fail");
  if (suitesFalhas.length) {
    escreve("");
    escreve(`${LINHA.repeat(7)} Failed Suites ${suitesFalhas.length} ${LINHA.repeat(7)}`);
    for (const s of suitesFalhas) {
      const arquivo = ancestrais(s)[0].nome;
      escreve("");
      escreve(s.pai ? ` FAIL  ${arquivo} > ${nomeCompleto(s)}` : ` FAIL  ${arquivo} [ ${arquivo} ]`);
      escreve(descreveErro(s.erro));
    }
  }
  if (falhos.length) {
    escreve("");
    escreve(`${LINHA.repeat(7)} Failed Tests ${falhos.length} ${LINHA.repeat(7)}`);
    falhos.forEach((t, i) => {
      escreve("");
      escreve(` FAIL  ${ancestrais(t)[0].nome} > ${nomeCompleto(t)}`);
      escreve(descreveErro(t.erro));
      escreve("");
      escreve(`${LINHA.repeat(24)}[${i + 1}/${falhos.length}]${LINHA}`);
    });
  }
  if (errosSoltos.length) {
    escreve("");
    escreve(`${LINHA.repeat(7)} Unhandled Errors ${LINHA.repeat(7)}`);
    for (const e of errosSoltos) { escreve(""); escreve(descreveErro(e)); }
  }
  escreve("");
  escreve(` ${contagem(arquivos, "Test Files")}`);
  escreve(`      ${contagem(todos, "Tests")}`);
  escreve(`   Start at  ${relogio.toTimeString().slice(0, 8)}`);
  escreve(`   Duration  ${ms(agora() - inicio)}`);
  escreve("");
  // Sai na hora: timers esquecidos pelos testes não seguram o processo (o vitest encerra os
  // workers do mesmo jeito).
  process.exit(suitesFalhas.length || falhos.length || errosSoltos.length ? 1 : 0);
}
principal().catch((e) => {
  if (e && e.__odeteExit) return; // o process.exit do fim, que se propaga como exceção
  console.error(e && e.stack || String(e));
  process.exit(1);
});
