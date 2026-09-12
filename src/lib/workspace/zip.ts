function crcTable() {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
}

const CRC = crcTable();

function crc32(bytes: Uint8Array) {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC[(c ^ bytes[i]!) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function u16(n: number) {
  const b = new Uint8Array(2);
  new DataView(b.buffer).setUint16(0, n, true);
  return b;
}

function u32(n: number) {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n, true);
  return b;
}

function concat(parts: Uint8Array[]) {
  const len = parts.reduce((a, p) => a + p.length, 0);
  const out = new Uint8Array(len);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

export function zipFiles(files: Record<string, string>): Blob {
  const enc = new TextEncoder();
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;
  const names = Object.keys(files).sort();
  for (const name of names) {
    const body = enc.encode(files[name] ?? "");
    const path = enc.encode(name.replace(/^\/+/, ""));
    const crc = crc32(body);
    const local = concat([
      u32(0x04034b50),
      u16(20),
      u16(0x0800),
      u16(0),
      u16(0),
      u16(0),
      u32(crc),
      u32(body.length),
      u32(body.length),
      u16(path.length),
      u16(0),
      path,
      body,
    ]);
    const central = concat([
      u32(0x02014b50),
      u16(20),
      u16(20),
      u16(0x0800),
      u16(0),
      u16(0),
      u16(0),
      u32(crc),
      u32(body.length),
      u32(body.length),
      u16(path.length),
      u16(0),
      u16(0),
      u16(0),
      u16(0),
      u32(0),
      u32(offset),
      path,
    ]);
    locals.push(local);
    centrals.push(central);
    offset += local.length;
  }
  const center = concat(centrals);
  const eocd = concat([
    u32(0x06054b50),
    u16(0),
    u16(0),
    u16(names.length),
    u16(names.length),
    u32(center.length),
    u32(offset),
    u16(0),
  ]);
  return new Blob([concat([...locals, center, eocd])], { type: "application/zip" });
}

export async function unzipFiles(buf: ArrayBuffer): Promise<Record<string, string>> {
  const u8 = new Uint8Array(buf);
  const view = new DataView(buf);
  const files: Record<string, string> = {};
  const dec = new TextDecoder();
  let i = 0;
  while (i + 30 <= u8.length) {
    if (view.getUint32(i, true) !== 0x04034b50) break;
    const method = view.getUint16(i + 8, true);
    const comp = view.getUint32(i + 18, true);
    const nameLen = view.getUint16(i + 26, true);
    const extra = view.getUint16(i + 28, true);
    const name = dec.decode(u8.subarray(i + 30, i + 30 + nameLen));
    const start = i + 30 + nameLen + extra;
    const slice = u8.subarray(start, start + comp);
    i = start + comp;
    if (!name || name.endsWith("/") || name.startsWith("__MACOSX")) continue;
    if (/\.(png|jpe?g|gif|webp|woff2?|pdf|zip|ico)$/i.test(name)) continue;
    try {
      let bytes = slice;
      if (method === 8) {
        const ds = new DecompressionStream("deflate-raw");
        const stream = new Blob([slice]).stream().pipeThrough(ds);
        bytes = new Uint8Array(await new Response(stream).arrayBuffer());
      } else if (method !== 0) {
        continue;
      }
      files[name.replace(/^\/+/, "")] = dec.decode(bytes);
    } catch {
      /* skip */
    }
  }
  return files;
}

export async function importZipFile(file: File) {
  return unzipFiles(await file.arrayBuffer());
}

export type SaveOffer = { href: string; name: string };

function isAbort(e: unknown) {
  return e instanceof DOMException && (e.name === "AbortError" || e.name === "NotAllowedError");
}

export function safeName(name: string, ext: string) {
  const base = (name || "colo").replace(/[\\/:*?"<>|]+/g, "-").trim() || "colo";
  return base.toLowerCase().endsWith(`.${ext}`) ? base : `${base}.${ext}`;
}

export async function saveBlob(blob: Blob, filename: string): Promise<SaveOffer> {
  const file = new File([blob], filename, { type: "application/octet-stream" });
  const href = URL.createObjectURL(file);
  const nav = navigator as Navigator & {
    share?: (d: ShareData) => Promise<void>;
    canShare?: (d: ShareData) => boolean;
  };
  try {
    if (nav.share && nav.canShare?.({ files: [file] })) {
      await nav.share({ files: [file], title: filename });
    }
  } catch (e) {
    if (!isAbort(e)) {
      /* fallback: o link visível */
    }
  }
  return { href, name: filename };
}

export async function downloadZip(name: string, files: Record<string, string>) {
  return saveBlob(zipFiles(files), safeName(name, "zip"));
}
