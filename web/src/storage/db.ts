// A one-store IndexedDB wrapper: what the page keeps that is too big or too
// binary for localStorage — the user's phrases (browser mode), the compiled
// dictionary cache, a linked file's handle.

const NAME = "jd";
const STORE = "kv";

let opening: Promise<IDBDatabase> | null = null;

function open(): Promise<IDBDatabase> {
  opening ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(NAME, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  return opening;
}

function run<T>(mode: IDBTransactionMode, body: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return open().then(
    (db) =>
      new Promise<T>((resolve, reject) => {
        const tx = db.transaction(STORE, mode);
        const request = body(tx.objectStore(STORE));
        tx.oncomplete = () => resolve(request.result);
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
      }),
  );
}

export function dbGet<T>(key: string): Promise<T | undefined> {
  return run("readonly", (store) => store.get(key) as IDBRequest<T | undefined>).catch(() => undefined);
}

export function dbSet(key: string, value: unknown): Promise<void> {
  return run("readwrite", (store) => store.put(value, key)).then(() => undefined);
}

export function dbDelete(key: string): Promise<void> {
  return run("readwrite", (store) => store.delete(key)).then(() => undefined);
}
