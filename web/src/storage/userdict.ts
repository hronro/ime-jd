// Where the user's phrases live, and the compiled cache beside them — the
// iOS/Android design: the text is the single source of truth, the blob is a
// cache tagged with the text's hash, so a stale or foreign blob is rebuilt.
//
// The text lives in IndexedDB, or — where the File System Access API exists
// and the user linked one — in a real file on disk.

import { dbDelete, dbGet, dbSet } from "./db";

const TEXT = "userdict.text";
const BLOB = "userdict.blob";
const FILE = "userdict.file";

export interface CachedBlob {
  /** libjd's hash of the text the blob was built from, as a decimal string. */
  readonly tag: string;
  readonly bytes: Uint8Array;
}

export type DictSource =
  | { readonly kind: "browser" }
  | { readonly kind: "file"; readonly handle: FileSystemFileHandle };

export interface StoredDict {
  readonly source: DictSource;
  /** The phrases, or null when a linked file cannot be read right now. */
  readonly text: string | null;
  readonly cache: CachedBlob | null;
  /** A linked file that needs the user's permission again. */
  readonly needsPermission: boolean;
  /** Why the text could not be read, if it could not. */
  readonly error: string | null;
}

export class NotUtf8Error extends Error {
  constructor() {
    super("文件不是 UTF-8 编码");
  }
}

/**
 * Bytes to text: strictly UTF-8, a byte-order mark dropped (TextDecoder's
 * default) — libjd would otherwise keep U+FEFF as part of line 1.
 */
export function decodeText(bytes: ArrayBuffer | Uint8Array): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new NotUtf8Error();
  }
}

export async function readFileText(handle: FileSystemFileHandle): Promise<string> {
  const file = await handle.getFile();
  return decodeText(await file.arrayBuffer());
}

export async function readStoredDict(): Promise<StoredDict> {
  const [handle, cache] = await Promise.all([dbGet<FileSystemFileHandle>(FILE), dbGet<CachedBlob>(BLOB)]);
  if (!handle) {
    const text = (await dbGet<string>(TEXT)) ?? "";
    return { source: { kind: "browser" }, text, cache: cache ?? null, needsPermission: false, error: null };
  }
  const source = { kind: "file", handle } as const;
  const permission = await handle.queryPermission?.({ mode: "readwrite" }).catch(() => "prompt" as const);
  if (permission !== undefined && permission !== "granted") {
    return { source, text: null, cache: cache ?? null, needsPermission: true, error: null };
  }
  try {
    return { source, text: await readFileText(handle), cache: cache ?? null, needsPermission: false, error: null };
  } catch (e) {
    const error = e instanceof NotUtf8Error ? e.message : `无法读取文件：${(e as Error).message}`;
    return { source, text: null, cache: cache ?? null, needsPermission: false, error };
  }
}

export async function writeBrowserText(text: string): Promise<void> {
  await dbSet(TEXT, text);
}

export async function writeFileText(handle: FileSystemFileHandle, text: string): Promise<void> {
  const writable = await handle.createWritable();
  await writable.write(text);
  await writable.close();
}

export async function cacheBlob(tag: bigint, bytes: Uint8Array): Promise<void> {
  await dbSet(BLOB, { tag: tag.toString(), bytes } satisfies CachedBlob);
}

export async function linkFile(handle: FileSystemFileHandle): Promise<void> {
  await dbSet(FILE, handle);
}

export async function unlinkFile(): Promise<void> {
  await dbDelete(FILE);
}

/** Durable storage, asked once the user has phrases worth keeping. */
export async function persistStorage(): Promise<boolean> {
  try {
    if (await navigator.storage?.persisted?.()) return true;
    return (await navigator.storage?.persist?.()) ?? false;
  } catch {
    return false;
  }
}
