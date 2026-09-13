import type { FileMap } from "./types";
import { compileToUrls, importData } from "./bundle";
import { esmImports, lockOfFiles } from "./npm-lock";
import { detectStack, parsePkg } from "./npm";
import type { PreviewFetch } from "./preview-types";

type NestHandler = {
  method: string;
  path: string;
  prefix: string;
  key: string;
  inst: Record<string, unknown>;
};

type ColoGlobal = typeof globalThis & {
  __coloHttp?: { handler: (req: unknown, res: unknown) => unknown; port?: number };
  __coloNest?: { handlers: NestHandler[]; prefix: string };
  __coloFs?: FileMap;
  __coloLogs?: string[];
};

const G = globalThis as ColoGlobal;

function dataUrl(src: string) {
  return `data:text/javascript;charset=utf-8,${encodeURIComponent(src)}`;
}

const SHIM_FS = `
const files = globalThis.__coloFs || {};
function norm(p){ return String(p||"").replace(/^\\.\\//,"").replace(/^\\/+/,""); }
export function readFileSync(p, enc){ const v = files[norm(p)]; if (v===undefined) { const e=new Error("ENOENT "+p); e.code="ENOENT"; throw e; } return v; }
export function existsSync(p){ return files[norm(p)]!==undefined; }
export function writeFileSync(p, data){ files[norm(p)] = String(data); }
export function readdirSync(p){
  const dir = norm(p).replace(/\\/+$/,"");
  const out = new Set();
  const prefix = dir ? dir+"/" : "";
  for (const k of Object.keys(files)) {
    if (dir && k!==dir && !k.startsWith(prefix)) continue;
    const rest = dir ? k.slice(prefix.length) : k;
    if (!rest) continue;
    out.add(rest.split("/")[0]);
  }
  return [...out];
}
export function mkdirSync(){}
export function statSync(p){
  const v = files[norm(p)];
  const isDir = v===undefined && readdirSync(p).length>=0 && Object.keys(files).some(k => k===norm(p) || k.startsWith(norm(p)+"/"));
  if (v===undefined && !isDir) { const e=new Error("ENOENT "+p); e.code="ENOENT"; throw e; }
  return { isFile:()=>v!==undefined, isDirectory:()=>v===undefined, size: (v||"").length };
}
export const promises = {
  readFile: async (p,e)=>readFileSync(p,e),
  writeFile: async (p,d)=>{ writeFileSync(p,d); },
  mkdir: async ()=>{},
  readdir: async (p)=>readdirSync(p),
  stat: async (p)=>statSync(p),
};
export default { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync, statSync, promises };
`;

const SHIM_PATH = `
export function join(...xs){ return xs.filter(Boolean).join("/").replace(/\\/+/g,"/"); }
export function resolve(...xs){ return join(...xs); }
export function dirname(p){ const i=String(p).lastIndexOf("/"); return i<=0? "." : p.slice(0,i); }
export function basename(p, ext){ const b=String(p).split("/").pop()||""; return ext && b.endsWith(ext) ? b.slice(0,-ext.length) : b; }
export function extname(p){ const b=basename(p); const i=b.lastIndexOf("."); return i<0?"":b.slice(i); }
export function isAbsolute(p){ return String(p).startsWith("/"); }
export const sep = "/";
export const posix = { join, resolve, dirname, basename, extname, isAbsolute, sep };
export default { join, resolve, dirname, basename, extname, isAbsolute, sep, posix };
`;

const SHIM_HTTP = `
function resProto(){
  const chunks = [];
  const headers = {};
  let status = 200;
  const res = {
    statusCode: 200,
    setHeader(k,v){ headers[String(k).toLowerCase()] = String(v); },
    getHeader(k){ return headers[String(k).toLowerCase()]; },
    writeHead(s, h){ status = s; res.statusCode = s; if (h) Object.entries(h).forEach(([k,v])=>res.setHeader(k,v)); },
    write(c){ chunks.push(String(c)); },
    end(c){ if (c) chunks.push(String(c)); res.body = chunks.join(""); res.status = status; res.headers = headers; res.__done?.(); },
    json(o){ res.setHeader("content-type","application/json"); res.end(JSON.stringify(o)); },
    on(){ return res; },
  };
  return res;
}
export function createServer(handler){
  const server = {
    listen(port, host, cb){
      const fn = typeof host === "function" ? host : typeof cb === "function" ? cb : typeof port === "function" ? port : null;
      globalThis.__coloHttp = { handler, port: typeof port === "number" ? port : 3000 };
      fn?.();
      return server;
    },
    close(cb){ globalThis.__coloHttp = null; cb?.(); },
    on(){ return server; },
    address(){ return { port: 3000, address: "127.0.0.1" }; },
  };
  return server;
}
export { resProto as __coloRes };
export default { createServer };
`;

const SHIM_PROCESS = `
const proc = {
  env: { NODE_ENV: "development", NEXT_RUNTIME: "edge" },
  argv: ["node", "main"],
  cwd: () => "/",
  exit: () => {},
  nextTick: (fn) => queueMicrotask(fn),
  version: "v22.0.0-colo",
  versions: { node: "22.0.0-colo" },
  platform: "darwin",
  stdout: { write: (s) => { (globalThis.__coloLogs ||= []).push(String(s)); } },
  stderr: { write: (s) => { (globalThis.__coloLogs ||= []).push(String(s)); } },
};
export default proc;
export const env = proc.env;
export const argv = proc.argv;
export const cwd = proc.cwd;
export const exit = proc.exit;
export const nextTick = proc.nextTick;
`;

const SHIM_URL = `
export const URL = globalThis.URL;
export const URLSearchParams = globalThis.URLSearchParams;
export function parse(u){ try { const x=new URL(u, "http://localhost"); return { href:x.href, protocol:x.protocol, host:x.host, pathname:x.pathname, search:x.search, query: Object.fromEntries(x.searchParams) }; } catch { return { href:u, pathname:u }; } }
export function format(o){ return o.href || o.pathname || ""; }
export default { URL, URLSearchParams, parse, format };
`;

const SHIM_UTIL = `
export function promisify(fn){ return (...a) => new Promise((res, rej) => fn(...a, (e, v) => e ? rej(e) : res(v))); }
export function inherits(c, p){ c.prototype = Object.create(p.prototype); }
export function inspect(v){ try { return JSON.stringify(v); } catch { return String(v); } }
export default { promisify, inherits, inspect };
`;

const SHIM_EVENTS = `
export class EventEmitter {
  constructor(){ this._h = {}; }
  on(ev, fn){ (this._h[ev] ||= []).push(fn); return this; }
  once(ev, fn){ const w=(...a)=>{ this.off(ev,w); fn(...a); }; return this.on(ev,w); }
  off(ev, fn){ this._h[ev] = (this._h[ev]||[]).filter(x=>x!==fn); return this; }
  emit(ev, ...a){ (this._h[ev]||[]).forEach(fn=>fn(...a)); return true; }
  removeListener(ev, fn){ return this.off(ev, fn); }
  addListener(ev, fn){ return this.on(ev, fn); }
}
export default { EventEmitter };
`;

const SHIM_STUB = (name: string) => `
const s = new Proxy(function(){}, { get: () => s, apply: () => s });
export default s;
export const ${name.replace(/\\W/g, "_") || "mod"} = s;
`;

const SHIM_NEXT_LINK = `
import React from "https://esm.sh/react@19";
export default function Link({ href="#", children, className, onClick, ...rest }){
  return React.createElement("a", { href, className, onClick, ...rest }, children);
}
`;

const SHIM_NEXT_IMAGE = `
import React from "https://esm.sh/react@19";
export default function Image({ src, alt="", width, height, className, ...rest }){
  return React.createElement("img", { src, alt, width, height, className, ...rest });
}
`;

const SHIM_NEXT_NAV = `
export function useRouter(){
  return {
    push: (h) => { location.hash = String(h); },
    replace: (h) => { location.hash = String(h); },
    back: () => history.back(),
    pathname: location.pathname,
    query: {},
    prefetch: async () => {},
  };
}
export function usePathname(){ return location.pathname || "/"; }
export function useSearchParams(){ return new URLSearchParams(location.search); }
export function useParams(){ return {}; }
export function redirect(h){ location.href = h; }
export function notFound(){ throw new Error("NEXT_NOT_FOUND"); }
export function useSelectedLayoutSegment(){ return null; }
`;

const SHIM_NEXT_HEAD = `
import React from "https://esm.sh/react@19";
export default function Head({ children }){ return React.createElement(React.Fragment, null, children); }
`;

const SHIM_NEXT_HEADERS = `
export function headers(){ return new Headers(); }
export function cookies(){ return { get: () => undefined, getAll: () => [], set(){}, delete(){} }; }
export function draftMode(){ return { isEnabled: false }; }
`;

const SHIM_NEXT_SERVER = `
export class NextRequest extends Request {}
export class NextResponse extends Response {
  static json(data, init){ return Response.json(data, init); }
  static redirect(url, status){ return Response.redirect(url, status); }
  static next(){ return new Response(null, { status: 200 }); }
  static rewrite(url){ return new Response(null, { headers: { "x-colo-rewrite": String(url) } }); }
}
export { NextResponse as default };
`;

const SHIM_NEXT_DYNAMIC = `
import React from "https://esm.sh/react@19";
export default function dynamic(loader){
  const C = React.lazy(loader);
  return function Dyn(props){ return React.createElement(React.Suspense, { fallback: null }, React.createElement(C, props)); };
}
`;

const SHIM_NEST_COMMON = `
function deco(kind, path=""){
  return function(...args){
    const rec = (cls, key) => {
      cls.__routes = cls.__routes || [];
      cls.__routes.push({ method: kind, path: path || "", key });
    };
    if (args[1] && args[1].kind === "method") {
      args[1].addInitializer(function(){ rec(this.constructor, args[1].name); });
      return args[0];
    }
    if (typeof args[0] === "object" && args[1]) {
      rec(args[0].constructor, args[1]);
      return;
    }
  };
}
export function Controller(prefix=""){
  return function(...args){
    const cls = args[0];
    if (typeof cls === "function") { cls.__prefix = prefix || ""; return cls; }
    if (args[1]?.kind === "class") { args[0].__prefix = prefix || ""; return args[0]; }
  };
}
export const Get = (p="") => deco("GET", p);
export const Post = (p="") => deco("POST", p);
export const Put = (p="") => deco("PUT", p);
export const Patch = (p="") => deco("PATCH", p);
export const Delete = (p="") => deco("DELETE", p);
export const Options = (p="") => deco("OPTIONS", p);
export const Head = (p="") => deco("HEAD", p);
export const All = (p="") => deco("ALL", p);
export function Module(meta={}){ return (cls) => { cls.__module = meta; return cls; }; }
export function Injectable(){ return (cls) => cls; }
export function Inject(){ return () => {}; }
export function Optional(){ return () => {}; }
export function Global(){ return (cls) => cls; }
export function Body(){ return () => {}; }
export function Param(){ return () => {}; }
export function Query(){ return () => {}; }
export function Headers(){ return () => {}; }
export function Req(){ return () => {}; }
export function Res(){ return () => {}; }
export function Next(){ return () => {}; }
export function HttpCode(){ return () => {}; }
export function Header(){ return () => {}; }
export function UseGuards(){ return () => {}; }
export function UsePipes(){ return () => {}; }
export function UseInterceptors(){ return () => {}; }
export function UseFilters(){ return () => {}; }
export function SetMetadata(){ return () => {}; }
export function Catch(){ return () => {}; }
export function createParamDecorator(){ return () => () => {}; }
export class HttpException extends Error {
  constructor(response, status=400){ super(typeof response==="string"?response:JSON.stringify(response)); this.response=response; this.status=status; this.getStatus=()=>status; this.getResponse=()=>response; }
}
export const HttpStatus = { OK:200, CREATED:201, BAD_REQUEST:400, UNAUTHORIZED:401, FORBIDDEN:403, NOT_FOUND:404, INTERNAL_SERVER_ERROR:500 };
export class Logger { log(){} error(){} warn(){} debug(){} verbose(){} }
export class ValidationPipe { transform(x){ return x; } }
export class ParseIntPipe { transform(x){ return parseInt(x,10); } }
export const RequestMethod = { GET:0, POST:1, PUT:2, DELETE:3, PATCH:4, ALL:5, OPTIONS:6, HEAD:7 };
`;

const SHIM_NEST_CORE = `
function walk(mod, controllers, providers){
  if (!mod) return;
  const meta = mod.__module || {};
  for (const c of meta.controllers || []) controllers.push(c);
  for (const p of meta.providers || []) providers.push(p);
  for (const i of meta.imports || []) walk(i, controllers, providers);
}
function make(Ctr, providers){
  try { return new Ctr(); } catch {}
  try { return new Ctr(...providers.map(P => { try { return new P(); } catch { return {}; } })); } catch {}
  return Object.create(Ctr.prototype);
}
export const NestFactory = {
  async create(module){
    const controllers = [];
    const providers = [];
    walk(module, controllers, providers);
    const insts = providers.map(P => { try { return new P(); } catch { return {}; } });
    const handlers = [];
    for (const C of controllers) {
      const inst = make(C, insts);
      const prefix = C.__prefix || "";
      const routes = C.__routes || C.prototype?.__routes || [];
      for (const r of routes) handlers.push({ ...r, prefix, inst });
    }
    let globalPrefix = "";
    const app = {
      setGlobalPrefix(p){ globalPrefix = p || ""; return app; },
      use(){ return app; },
      enableCors(){ return app; },
      useGlobalPipes(){ return app; },
      useGlobalFilters(){ return app; },
      useGlobalInterceptors(){ return app; },
      useGlobalGuards(){ return app; },
      getHttpAdapter(){ return { getInstance(){ return {}; } }; },
      async listen(port, cb){
        globalThis.__coloNest = { handlers, prefix: globalPrefix, port };
        if (typeof cb === "function") cb();
        return app;
      },
      close: async () => {},
    };
    return app;
  },
};
export default { NestFactory };
`;

const SHIM_NEST_EXPRESS = `export class ExpressAdapter {}
export default { ExpressAdapter };
`;

function shimMap(): Record<string, string> {
  const fs = dataUrl(SHIM_FS);
  const path = dataUrl(SHIM_PATH);
  const http = dataUrl(SHIM_HTTP);
  const proc = dataUrl(SHIM_PROCESS);
  const url = dataUrl(SHIM_URL);
  const util = dataUrl(SHIM_UTIL);
  const events = dataUrl(SHIM_EVENTS);
  const stub = (n: string) => dataUrl(SHIM_STUB(n));
  const nextLink = dataUrl(SHIM_NEXT_LINK);
  const nextImage = dataUrl(SHIM_NEXT_IMAGE);
  const nextNav = dataUrl(SHIM_NEXT_NAV);
  const nextHead = dataUrl(SHIM_NEXT_HEAD);
  const nextHeaders = dataUrl(SHIM_NEXT_HEADERS);
  const nextServer = dataUrl(SHIM_NEXT_SERVER);
  const nextDyn = dataUrl(SHIM_NEXT_DYNAMIC);
  const nestCommon = dataUrl(SHIM_NEST_COMMON);
  const nestCore = dataUrl(SHIM_NEST_CORE);
  const nestEx = dataUrl(SHIM_NEST_EXPRESS);
  return {
    fs,
    "node:fs": fs,
    path,
    "node:path": path,
    http,
    "node:http": http,
    https: http,
    "node:https": http,
    url,
    "node:url": url,
    util,
    "node:util": util,
    events,
    "node:events": events,
    process: proc,
    "node:process": proc,
    os: stub("os"),
    "node:os": stub("os"),
    stream: stub("stream"),
    "node:stream": stub("stream"),
    buffer: stub("buffer"),
    "node:buffer": stub("buffer"),
    crypto: stub("crypto"),
    "node:crypto": stub("crypto"),
    child_process: stub("child_process"),
    "node:child_process": stub("child_process"),
    net: stub("net"),
    "node:net": stub("net"),
    zlib: stub("zlib"),
    tty: stub("tty"),
    "next/link": nextLink,
    "next/image": nextImage,
    "next/navigation": nextNav,
    "next/router": nextNav,
    "next/head": nextHead,
    "next/headers": nextHeaders,
    "next/server": nextServer,
    "next/dynamic": nextDyn,
    "next/script": nextHead,
    "@nestjs/common": nestCommon,
    "@nestjs/core": nestCore,
    "@nestjs/platform-express": nestEx,
  };
}

export function shimImportMap(): Record<string, string> {
  return shimMap();
}

function pick(files: FileMap, names: string[]) {
  return names.find((n) => files[n] !== undefined);
}

export function nextPageEntry(files: FileMap): { path: string; code: string; html: string } | null {
  const page = pick(files, [
    "app/page.tsx",
    "app/page.jsx",
    "app/page.js",
    "src/app/page.tsx",
    "src/app/page.jsx",
    "src/app/page.js",
    "pages/index.tsx",
    "pages/index.jsx",
    "pages/index.js",
    "src/pages/index.tsx",
    "src/pages/index.jsx",
    "src/pages/index.js",
  ]);
  if (!page) return null;
  const layout = pick(files, ["app/layout.tsx", "app/layout.jsx", "app/layout.js", "src/app/layout.tsx", "src/app/layout.jsx"]);
  const code = `import React from "react";
import { createRoot } from "react-dom/client";
import Page from "/${page}";
${layout ? `import Layout from "/${layout}";` : ""}
const el = document.getElementById("root") || document.body.appendChild(Object.assign(document.createElement("div"), { id: "root" }));
const page = React.createElement(Page);
const tree = ${layout ? "React.createElement(Layout, null, page)" : "page"};
createRoot(el).render(tree);
`;
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Next · Colo</title></head><body><div id="root"></div><script type="module" src="/__colo_next_entry.jsx"></script></body></html>`;
  return { path: "__colo_next_entry.jsx", code, html };
}

function nestEntry(files: FileMap) {
  return pick(files, ["src/main.ts", "src/main.js", "main.ts", "main.js", "src/main.tsx"]);
}

function matchSeg(pat: string, got: string) {
  if (pat.startsWith("[...") && pat.endsWith("]")) return true;
  if (pat.startsWith("[") && pat.endsWith("]")) return true;
  return pat === got;
}

function paramsOf(pat: string[], got: string[]) {
  const params: Record<string, string> = {};
  for (let i = 0; i < pat.length; i++) {
    const p = pat[i]!;
    if (p.startsWith("[...") && p.endsWith("]")) {
      params[p.slice(4, -1)] = got.slice(i).join("/");
      return params;
    }
    if (p.startsWith("[") && p.endsWith("]")) params[p.slice(1, -1)] = got[i] ?? "";
  }
  return params;
}

export function matchNextApi(files: FileMap, urlPath: string) {
  const rest = urlPath.replace(/^[/]+/, "").replace(/^api[/]?/, "");
  const segs = rest.split("/").filter(Boolean);
  const routes: { file: string; pat: string[]; score: number }[] = [];
  for (const k of Object.keys(files)) {
    let m = k.match(/^(?:src[/])?app[/]api[/]route[.][jt]sx?$/);
    if (m) {
      routes.push({ file: k, pat: [], score: 3 });
      continue;
    }
    m = k.match(/^(?:src[/])?app[/]api[/](.+)[/]route[.][jt]sx?$/);
    if (m) {
      const pat = m[1]!.split("/");
      const catchAll = pat.some((p) => p.startsWith("[..."));
      const dyn = pat.some((p) => p.startsWith("["));
      routes.push({ file: k, pat, score: catchAll ? 0 : dyn ? 1 : 2 });
      continue;
    }
    m = k.match(/^(?:src[/])?pages[/]api[/](.+)[.][jt]sx?$/);
    if (m) {
      const pat = m[1]!.split("/");
      const catchAll = pat.some((p) => p.startsWith("[..."));
      routes.push({ file: k, pat, score: catchAll ? 0 : 2 });
    }
  }
  routes.sort((a, b) => b.score - a.score);
  for (const r of routes) {
    const catchAll = r.pat.some((p) => p.startsWith("[..."));
    if (!catchAll && r.pat.length !== segs.length) continue;
    if (catchAll && segs.length < r.pat.filter((p) => !p.startsWith("[...")).length) continue;
    if (r.pat.every((p, i) => matchSeg(p, segs[i] ?? "")) || (r.pat.length === 0 && segs.length === 0)) {
      return { file: r.file, params: paramsOf(r.pat, segs), pages: /pages[/]api[/]/.test(r.file) };
    }
  }
  return null;
}

function bareFor(files: FileMap) {
  return { ...esmImports(lockOfFiles(files)), ...shimMap() };
}

function bindFs(files: FileMap) {
  G.__coloFs = files;
}

async function loadEntry(files: FileMap, entry: string) {
  bindFs(files);
  const urls = compileToUrls(files, [entry], bareFor(files));
  const url = urls?.[entry];
  if (!url) throw new Error(`não compilou ${entry} (ciclo ou arquivo faltando)`);
  return importData(url);
}

function jsonFetch(status: number, body: unknown, contentType = "application/json;charset=utf-8"): PreviewFetch {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  return { status, body: text, contentType };
}

async function asFetch(value: unknown): Promise<PreviewFetch> {
  if (value instanceof Response) {
    const text = await value.text();
    return {
      status: value.status,
      body: text,
      contentType: value.headers.get("content-type") || "text/plain;charset=utf-8",
    };
  }
  if (value && typeof value === "object" && "status" in (value as object) && "body" in (value as object)) {
    const v = value as { status?: number; body?: unknown; headers?: Record<string, string> };
    return jsonFetch(v.status || 200, v.body, v.headers?.["content-type"]);
  }
  if (value === undefined || value === null) return jsonFetch(200, { ok: true });
  return jsonFetch(200, value);
}

async function runNextApi(files: FileMap, hit: NonNullable<ReturnType<typeof matchNextApi>>, method: string, body: string | null, urlPath: string) {
  const mod = await loadEntry(files, hit.file);
  const req = new Request(`https://colo.preview/${String(urlPath).replace(/^[/]+/, "")}`, {
    method,
    body: method === "GET" || method === "HEAD" ? undefined : body ?? undefined,
    headers: { "content-type": "application/json" },
  });
  if (hit.pages) {
    const handler = (mod.default || mod.handler) as
      | ((req: unknown, res: unknown) => unknown)
      | undefined;
    if (!handler) return jsonFetch(500, { error: "pages/api sem export default" });
    let payload = "";
    let status = 200;
    const headers: Record<string, string> = {};
    const nodeReq = {
      method,
      url: `/${hit.file}`,
      query: hit.params,
      body: body ? safeJson(body) : {},
      headers: { "content-type": "application/json" },
    };
    const nodeRes = {
      statusCode: 200,
      setHeader(k: string, v: string) {
        headers[k.toLowerCase()] = v;
      },
      status(n: number) {
        status = n;
        nodeRes.statusCode = n;
        return nodeRes;
      },
      json(o: unknown) {
        payload = JSON.stringify(o);
        headers["content-type"] = "application/json;charset=utf-8";
      },
      send(o: unknown) {
        payload = typeof o === "string" ? o : JSON.stringify(o);
      },
      end(o?: unknown) {
        if (o !== undefined) nodeRes.send(o);
      },
    };
    await handler(nodeReq, nodeRes);
    return { status, body: payload || "{}", contentType: headers["content-type"] || "application/json;charset=utf-8" };
  }
  const fn =
    (mod[method] as ((req: Request, ctx: { params: Record<string, string> }) => unknown) | undefined) ||
    (mod[method.toLowerCase()] as ((req: Request, ctx: { params: Record<string, string> }) => unknown) | undefined);
  if (!fn) return jsonFetch(405, { error: `${method} não exportado em ${hit.file}` });
  return asFetch(await fn(req, { params: hit.params }));
}

function safeJson(s: string) {
  try {
    return JSON.parse(s);
  } catch {
    return s;
  }
}

function nestPath(h: NestHandler, globalPrefix: string) {
  const parts = [globalPrefix, h.prefix, h.path].filter(Boolean).map((p) => String(p).replace(/^[/]+|[/]+$/g, ""));
  return "/" + parts.filter(Boolean).join("/");
}

function matchNest(urlPath: string, method: string) {
  const nest = G.__coloNest;
  if (!nest?.handlers?.length) return null;
  const want = ("/" + urlPath.replace(/^[/]+/, "")).replace(/[/]+$/, "") || "/";
  for (const h of nest.handlers) {
    if (h.method !== "ALL" && h.method !== method) continue;
    const p = nestPath(h, nest.prefix).replace(/[/]+$/, "") || "/";
    const got = want.split("/");
    const pat = p.split("/");
    if (pat.length !== got.length && !p.includes(":")) continue;
    let ok = pat.length === got.length;
    const params: Record<string, string> = {};
    if (ok) {
      for (let i = 0; i < pat.length; i++) {
        if (pat[i]!.startsWith(":")) params[pat[i]!.slice(1)] = got[i] ?? "";
        else if (pat[i] !== got[i]) ok = false;
      }
    }
    if (ok) return { h, params };
  }
  return null;
}

async function invokeNest(h: NestHandler, method: string, urlPath: string, body: string | null, params: Record<string, string>) {
  const fn = (h.inst as Record<string, (...a: unknown[]) => unknown>)[h.key];
  if (typeof fn !== "function") return jsonFetch(500, { error: `handler ${h.key} sumiu` });
  const payload = body ? safeJson(body) : undefined;
  const req = { method, url: "/" + urlPath, params, query: params, body: payload };
  let value: unknown;
  try {
    const n = fn.length;
    if (n <= 0) value = await fn.call(h.inst);
    else if (n === 1) value = await fn.call(h.inst, payload ?? params ?? req);
    else value = await fn.call(h.inst, req, { json: (o: unknown) => o, send: (o: unknown) => o });
  } catch (e) {
    const ex = e as { status?: number; getStatus?: () => number; response?: unknown; message?: string };
    const status = ex.getStatus?.() || ex.status || 500;
    return jsonFetch(status, ex.response ?? { error: ex.message || String(e) });
  }
  return asFetch(value);
}

async function invokeHttp(urlPath: string, method: string, body: string | null) {
  const http = G.__coloHttp;
  if (!http?.handler) return null;
  let payload = "";
  let status = 200;
  const headers: Record<string, string> = {};
  const req = {
    method,
    url: "/" + urlPath.replace(/^[/]+/, ""),
    headers: { "content-type": "application/json" },
    body: body ? safeJson(body) : undefined,
    on() {},
  };
  const res = {
    statusCode: 200,
    setHeader(k: string, v: string) {
      headers[k.toLowerCase()] = String(v);
    },
    writeHead(s: number, h?: Record<string, string>) {
      status = s;
      if (h) Object.entries(h).forEach(([k, v]) => {
        headers[k.toLowerCase()] = String(v);
      });
    },
    write(c: string) {
      payload += String(c);
    },
    end(c?: string) {
      if (c) payload += String(c);
      status = res.statusCode || status;
    },
    json(o: unknown) {
      headers["content-type"] = "application/json;charset=utf-8";
      payload = JSON.stringify(o);
    },
    status(n: number) {
      status = n;
      res.statusCode = n;
      return res;
    },
    send(o: unknown) {
      payload = typeof o === "string" ? o : JSON.stringify(o);
    },
  };
  await http.handler(req, res);
  return {
    status,
    body: payload || "",
    contentType: headers["content-type"] || "text/plain;charset=utf-8",
  };
}

let nestBootedFor = "";

export async function bootProject(files: FileMap) {
  const pkg = parsePkg(files["package.json"]);
  const stack = detectStack(pkg);
  const key = `${stack.id}:${Object.keys(files)
    .filter((k) => k.endsWith(".ts") || k.endsWith(".js"))
    .sort()
    .map((k) => `${k}:${files[k]?.length ?? 0}`)
    .join("|")}`;
  if (stack.id === "nest") {
    const main = nestEntry(files);
    if (!main) return { ok: false, out: "Nest: falta src/main.ts" };
    if (nestBootedFor !== key) {
      G.__coloNest = undefined;
      G.__coloLogs = [];
      try {
        await loadEntry(files, main);
        nestBootedFor = key;
      } catch (e) {
        return { ok: false, out: `Nest boot falhou: ${e instanceof Error ? e.message : e}` };
      }
    }
    const n = G.__coloNest?.handlers?.length ?? 0;
    return {
      ok: true,
      out: `Nest no Colo · ${n} rota${n === 1 ? "" : "s"} no Preview (sem TCP, sem Prisma nativo).`,
    };
  }
  if (stack.id === "next") {
    const page = nextPageEntry(files);
    const apis = Object.keys(files).filter((k) => /(^|[/])(app|pages)[/]api[/]/.test(k)).length;
    return {
      ok: true,
      out: page
        ? `Next no Colo · página ${page.path.replace("__colo_next_entry.jsx", "app/page")} no Preview${apis ? `, ${apis} route handler` : ""}. Sem SSR/next build.`
        : `Next no Colo · sem app/page.tsx; Route Handlers ainda respondem em /api.`,
    };
  }
  return { ok: true, out: "" };
}

export async function dispatchRuntime(
  files: FileMap,
  url: string,
  method = "GET",
  body: string | null = null,
): Promise<PreviewFetch | null> {
  let path = url.replace(/[?#].*$/, "").replace(/^[/]+/, "");
  try {
    if (/^https?:/i.test(url) || url.startsWith("//")) {
      const u = new URL(url.startsWith("//") ? `https:${url}` : url);
      path = u.pathname.replace(/^[/]+/, "");
    }
  } catch {
    /* keep */
  }

  const nextHit = matchNextApi(files, path.startsWith("api/") ? path : `api/${path}`);
  if (nextHit || path.startsWith("api/") || /(^|[/])app[/]api[/]/.test(path)) {
    const hit = nextHit || matchNextApi(files, path);
    if (hit) {
      try {
        return await runNextApi(files, hit, method.toUpperCase(), body, path);
      } catch (e) {
        return jsonFetch(500, { error: e instanceof Error ? e.message : String(e), file: hit.file });
      }
    }
  }

  const pkg = parsePkg(files["package.json"]);
  const stack = detectStack(pkg);
  if (stack.id === "nest" && !G.__coloNest) {
    await bootProject(files);
  }
  const nestHit = matchNest(path, method.toUpperCase()) || matchNest(path.replace(/^api[/]/, ""), method.toUpperCase());
  if (nestHit) {
    try {
      return await invokeNest(nestHit.h, method.toUpperCase(), path, body, nestHit.params);
    } catch (e) {
      return jsonFetch(500, { error: e instanceof Error ? e.message : String(e) });
    }
  }

  const httpRes = await invokeHttp(path, method.toUpperCase(), body);
  if (httpRes) return httpRes;

  return null;
}

export async function runNode(entry: string, argv: string[], files: FileMap): Promise<string> {
  const path = entry.replace(/^[/]+/, "");
  if (files[path] === undefined) {
    const alt = [path, `${path}.js`, `${path}.ts`, `${path}.mjs`].find((p) => files[p] !== undefined);
    if (!alt) return `node: ${entry}: não existe`;
    return runNode(alt, argv, files);
  }
  G.__coloLogs = [];
  G.__coloHttp = undefined;
  bindFs(files);
  (G as { process?: { argv: string[] } }).process = {
    ...(G as { process?: object }).process,
    argv: ["node", path, ...argv],
  } as { argv: string[] };
  try {
    await loadEntry(files, path);
  } catch (e) {
    return `node ${path}\n${e instanceof Error ? e.message : String(e)}`;
  }
  const logs = (G.__coloLogs || []).join("");
  const http = (globalThis as ColoGlobal).__coloHttp;
  const extra = http ? `\nhttp.listen :${http.port ?? 3000} — o Preview encaminha fetch pra cá.` : "";
  return logs.trim() ? logs.trim() + extra : `node ${path} ok${extra}`;
}

export function runtimeHint(files: FileMap) {
  const stack = detectStack(parsePkg(files["package.json"]));
  const isolated = typeof window !== "undefined" && !!window.crossOriginIsolated;
  if (isolated) {
    return `${stack.label}: npm run dev/start usa o Node deste iPad.`;
  }
  if (stack.id === "next") {
    return "Next no Colo (sem isolamento): app/page no Preview + Route Handlers em /api. Sem next build, sem SSR.";
  }
  if (stack.id === "nest") {
    return "Nest no Colo (sem isolamento): src/main.ts com decorators shim. Preview chama as rotas. Sem TCP, Prisma nativo ou microservices.";
  }
  if (stack.kind === "ssr") {
    return `${stack.label}: sem origem isolada o Colo só emula o client. No app em tela cheia o Node sobe.`;
  }
  return "";
}
