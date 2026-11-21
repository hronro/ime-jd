// The user dictionary as the page uses it: the phrases text (source of
// truth), libjd's verdict on it (the build report), and the live engine that
// merges it in while 启用用户自造词 is on. Every client's rules apply:
//  - libjd is the only judge of a line; nothing here validates;
//  - a failed rebuild keeps the last good dictionary in use;
//  - the blob cache is tagged with libjd's hash of the text.

import { type Accessor, createSignal, type Setter } from "solid-js";
import {
  type Engine,
  type JdModule,
  type UserDict,
  UserDictError,
  type UserDictLimits,
  type UserDictReport,
} from "jd";
import { ime } from "../ime/controller";
import { setUserDictEnabled, userDictEnabled } from "../storage/settings";
import {
  cacheBlob,
  type DictSource,
  NotUtf8Error,
  persistStorage,
  readFileText,
  readStoredDict,
  type StoredDict,
  writeBrowserText,
  writeFileText,
} from "../storage/userdict";

/** libjd's caps (core/include/jd.h), as the loaded module reports them. */
export function userDictLimits(): UserDictLimits {
  return dict.jd.userDictLimits;
}

interface Live {
  readonly engine: Engine;
  readonly dict: UserDict | null;
}

const encoder = new TextEncoder();

export function buildErrorMessage(error: unknown): string {
  if (error instanceof UserDictError) {
    const limits = userDictLimits();
    if (error.status === "tooManyEntries") return `第 ${error.line} 行起超过 ${limits.maxEntries} 条上限`;
    if (error.status === "textTooLong") return `文件超过 ${limits.textMax / (1024 * 1024)} MB 上限`;
    return `无法编译词库（${error.status}）`;
  }
  if (error instanceof NotUtf8Error) return error.message;
  return `无法编译词库（${(error as Error).message}）`;
}

class DictService {
  readonly text: Accessor<string>;
  readonly report: Accessor<UserDictReport | null>;
  readonly source: Accessor<DictSource>;
  readonly needsPermission: Accessor<boolean>;
  /** Why the current text cannot be used (unreadable, over a cap). */
  readonly error: Accessor<string | null>;
  /** Bumped on every rebuild, so views can refresh. */
  readonly revision: Accessor<number>;

  #setText: Setter<string>;
  #setReport: Setter<UserDictReport | null>;
  #setSource: Setter<DictSource>;
  #setNeedsPermission: Setter<boolean>;
  #setError: Setter<string | null>;
  #setRevision: Setter<number>;

  #jd: JdModule | null = null;
  #live: Live | null = null;
  #channel = typeof BroadcastChannel === "function" ? new BroadcastChannel("jd") : null;
  #fileStamp = "";

  constructor() {
    [this.text, this.#setText] = createSignal<string>("");
    [this.report, this.#setReport] = createSignal<UserDictReport | null>(null);
    [this.source, this.#setSource] = createSignal<DictSource>({ kind: "browser" });
    [this.needsPermission, this.#setNeedsPermission] = createSignal<boolean>(false);
    [this.error, this.#setError] = createSignal<string | null>(null);
    [this.revision, this.#setRevision] = createSignal<number>(0);
  }

  get jd(): JdModule {
    if (!this.#jd) throw new Error("libjd not loaded");
    return this.#jd;
  }

  /** The first engine, from what storage holds — a cached blob when it matches. */
  async boot(jd: JdModule): Promise<Engine> {
    this.#jd = jd;
    const stored = await readStoredDict();
    this.#adoptStored(stored);
    if (stored.source.kind === "file" && stored.text !== null) this.#fileStamp = await this.#stamp(stored.source.handle);
    const dict = userDictEnabled() ? this.#dictAtBoot(stored) : null;
    const engine = jd.createEngine({ userDict: dict });
    this.#live = { engine, dict };

    this.#channel?.addEventListener("message", (e) => {
      if ((e.data as { kind?: string })?.kind === "userdict") void this.reload();
    });
    addEventListener("focus", () => void this.#checkFile());
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") void this.#checkFile();
    });
    return engine;
  }

  #adoptStored(stored: StoredDict): void {
    this.#setSource(stored.source);
    this.#setNeedsPermission(stored.needsPermission);
    this.#setError(stored.error);
    if (stored.text !== null) this.#setText(stored.text);
  }

  #dictAtBoot(stored: StoredDict): UserDict | null {
    const jd = this.jd;
    const text = stored.text;
    const cached = stored.cache;
    if (text === null) {
      // The linked file cannot be read yet: keep typing with the last
      // dictionary built from it, until the user grants access again.
      if (!cached) return null;
      try {
        return jd.loadUserDict(cached.bytes);
      } catch {
        return null;
      }
    }
    const bytes = encoder.encode(text);
    const tag = jd.hashUserDictText(bytes);
    if (cached && cached.tag === tag.toString()) {
      try {
        return jd.loadUserDict(cached.bytes);
      } catch {
        // stale (another libjd) or corrupt: rebuild below
      }
    }
    return this.#build(text, { bytes, tag })?.dict ?? null;
  }

  /**
   * Build `text`; on success record the report and cache the blob. Encoded
   * once, for both the hash and the build: 500 000 phrases are 8 MB of UTF-8.
   */
  #build(text: string, encoded?: { bytes: Uint8Array; tag: bigint }): { dict: UserDict; report: UserDictReport } | null {
    try {
      const bytes = encoded?.bytes ?? encoder.encode(text);
      const tag = encoded?.tag ?? this.jd.hashUserDictText(bytes);
      const built = this.jd.buildUserDict(bytes, { sourceTag: tag });
      this.#setReport(built.report);
      this.#setError(null);
      void cacheBlob(tag, built.dict.bytes()).catch(() => {});
      return built;
    } catch (e) {
      this.#setReport(null);
      this.#setError(buildErrorMessage(e));
      return null;
    } finally {
      this.#setRevision((n) => n + 1);
    }
  }

  /** The verdicts for the current text, building it if boot used the cache. */
  ensureReport(): void {
    if (this.report() !== null) return;
    this.#build(this.text())?.dict.dispose();
  }

  /**
   * Make `text` the user's phrases: write it where they live, rebuild, put
   * the new dictionary into the engine (when enabled), and tell other tabs.
   * Throws only when the write itself fails.
   */
  async save(text: string): Promise<void> {
    const source = this.source();
    if (source.kind === "file") {
      await writeFileText(source.handle, text);
      this.#fileStamp = await this.#stamp(source.handle);
    } else {
      await writeBrowserText(text);
    }
    this.#setText(text);
    this.#apply(text);
    this.#channel?.postMessage({ kind: "userdict" });
    if (text.trim() !== "") void persistStorage();
  }

  /** Rebuild `text` and adopt it in the engine when the dictionary is on. */
  #apply(text: string): void {
    const built = this.#build(text);
    if (!built) return; // keep the last good dictionary in use
    if (userDictEnabled()) this.#swap(built.dict);
    else built.dict.dispose();
  }

  setEnabled(on: boolean): void {
    setUserDictEnabled(on);
    if (!on) {
      this.#swap(null);
      return;
    }
    const built = this.#build(this.text());
    this.#swap(built?.dict ?? null);
  }

  /** Re-read storage: another tab saved, or the linked file changed on disk. */
  async reload(): Promise<void> {
    const stored = await readStoredDict();
    this.#adoptStored(stored);
    if (stored.text === null) return;
    if (stored.source.kind === "file") this.#fileStamp = await this.#stamp(stored.source.handle);
    this.#apply(stored.text);
  }

  /** Switch where the phrases live; the caller has already written `text` there. */
  async adoptSource(source: DictSource, text: string): Promise<void> {
    this.#setSource(source);
    this.#setNeedsPermission(false);
    if (source.kind === "file") this.#fileStamp = await this.#stamp(source.handle);
    this.#setText(text);
    this.#apply(text);
    this.#channel?.postMessage({ kind: "userdict" });
  }

  /** Ask again for access to the linked file (needs a user gesture). */
  async reauthorize(): Promise<boolean> {
    const source = this.source();
    if (source.kind !== "file") return true;
    const state = await source.handle.requestPermission?.({ mode: "readwrite" });
    if (state !== "granted") return false;
    await this.reload();
    return true;
  }

  #swap(dict: UserDict | null): void {
    const old = this.#live;
    if (!old) return;
    const engine = this.jd.createEngine({ userDict: dict });
    this.#live = { engine, dict };
    ime.swapEngine(engine, () => {
      old.engine.dispose();
      old.dict?.dispose();
    });
  }

  async #stamp(handle: FileSystemFileHandle): Promise<string> {
    try {
      const file = await handle.getFile();
      return `${file.size}:${file.lastModified}`;
    } catch {
      return "";
    }
  }

  /** The Windows client's approach: size and time tell an edit elsewhere. */
  async #checkFile(): Promise<void> {
    const source = this.source();
    if (source.kind !== "file" || this.needsPermission()) return;
    const stamp = await this.#stamp(source.handle);
    if (stamp === "" || stamp === this.#fileStamp) return;
    this.#fileStamp = stamp;
    try {
      const text = await readFileText(source.handle);
      if (text === this.text()) return;
      this.#setText(text);
      this.#apply(text);
    } catch (e) {
      this.#setError(buildErrorMessage(e));
    }
  }
}

export const dict = new DictService();
