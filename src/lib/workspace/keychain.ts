type NativeSecrets = {
  secretGet?: (key: string) => Promise<string | null>;
  secretSet?: (key: string, value: string) => Promise<void>;
  secretDelete?: (key: string) => Promise<void>;
};

type Host = typeof globalThis & { coloNative?: NativeSecrets };

function native(): NativeSecrets | null {
  const n = (globalThis as Host).coloNative;
  if (n?.secretGet && n.secretSet) return n;
  return null;
}

export function keychainReady() {
  return !!native();
}

export async function keychainGet(key: string): Promise<string | null> {
  const n = native();
  if (n?.secretGet) return n.secretGet(key);
  return null;
}

export async function keychainSet(key: string, value: string): Promise<boolean> {
  const n = native();
  if (!n?.secretSet) return false;
  await n.secretSet(key, value);
  return true;
}

export async function keychainDel(key: string): Promise<void> {
  const n = native();
  if (n?.secretDelete) await n.secretDelete(key);
}
