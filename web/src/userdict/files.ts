// Files in and out: import a phrases file (every browser), export one
// (every browser), and — where the File System Access API exists — link the
// dictionary to a real file the user picked, which then is the source of truth.

import { decodeText, NotUtf8Error } from "../storage/userdict";
import { FILE_NAME } from "./format";

const TXT = [{ description: "文本文件", accept: { "text/plain": [".txt"] } }];

export const canLinkFile = typeof window.showSaveFilePicker === "function" && typeof window.showOpenFilePicker === "function";

export interface PickedFile {
  readonly name: string;
  readonly text: string;
}

export class ReadError extends Error {}

async function read(file: File): Promise<PickedFile> {
  try {
    return { name: file.name, text: decodeText(await file.arrayBuffer()) };
  } catch (e) {
    throw new ReadError(e instanceof NotUtf8Error ? e.message : `无法读取文件：${(e as Error).message}`);
  }
}

const isAbort = (e: unknown) => (e as Error)?.name === "AbortError";

/** One .txt from the user, or null when they cancel. */
export async function pickTextFile(): Promise<PickedFile | null> {
  if (window.showOpenFilePicker) {
    try {
      const [handle] = await window.showOpenFilePicker({ types: TXT, id: "jd-userdict" });
      return handle ? read(await handle.getFile()) : null;
    } catch (e) {
      if (isAbort(e)) return null;
      throw e;
    }
  }
  return new Promise((resolve, reject) => {
    const input = Object.assign(document.createElement("input"), { type: "file", accept: ".txt,text/plain" });
    input.addEventListener("change", () => {
      const file = input.files?.[0];
      if (file) read(file).then(resolve, reject);
      else resolve(null);
    });
    input.addEventListener("cancel", () => resolve(null));
    input.click();
  });
}

/** Save `text` as a file of the user's choosing (or a download). */
export async function exportText(text: string): Promise<boolean> {
  if (window.showSaveFilePicker) {
    try {
      const handle = await window.showSaveFilePicker({ suggestedName: FILE_NAME, types: TXT, id: "jd-userdict" });
      const writable = await handle.createWritable();
      await writable.write(text);
      await writable.close();
      return true;
    } catch (e) {
      if (isAbort(e)) return false;
      throw e;
    }
  }
  const url = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
  const a = Object.assign(document.createElement("a"), { href: url, download: FILE_NAME });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
  return true;
}

/** A new file to keep the phrases in; null when cancelled. */
export async function pickNewFile(): Promise<FileSystemFileHandle | null> {
  try {
    return await window.showSaveFilePicker!({ suggestedName: FILE_NAME, types: TXT, id: "jd-userdict" });
  } catch (e) {
    if (isAbort(e)) return null;
    throw e;
  }
}

/** An existing phrases file, with write access; null when cancelled or refused. */
export async function pickExistingFile(): Promise<FileSystemFileHandle | null> {
  try {
    const [handle] = await window.showOpenFilePicker!({ types: TXT, id: "jd-userdict" });
    if (!handle) return null;
    const state = await handle.requestPermission?.({ mode: "readwrite" });
    return state === undefined || state === "granted" ? handle : null;
  } catch (e) {
    if (isAbort(e)) return null;
    throw e;
  }
}
