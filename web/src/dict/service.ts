// The user dictionary as the page uses it: the phrases text (source of
// truth), libjd's verdict on it (the build report), and the live engine that
// merges it in while 启用用户自造词 is on — or, with 忽略内置词库, types
// from it alone, on the empty dictionary. Every client's rules apply:
//  - libjd is the only judge of a line; nothing here validates;
//  - a failed rebuild keeps the last good dictionary in use;
//  - the blob cache is tagged with libjd's hash of the text, and is for the
//    dictionary it was built on (a cache for the other one reads as stale);
//  - with only the phrases to type from and none to be had, the IME says so
//    and lets keys through as typed; never the built-in dictionary instead.

import { type Accessor, createSignal, type Setter } from "solid-js";
import {
  type Dict,
  type Engine,
  type JdModule,
  type UserDict,
  UserDictError,
  type UserDictLimits,
  type UserDictReport,
} from "jd";
import { ime } from "../ime/controller";
import { setUserDictEnabled, setUserDictOnly, userDictEnabled, userDictOnly } from "../storage/settings";
import { showToast } from "../ui/toast";
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
  /** The empty dictionary the phrases sit on with 忽略内置词库, built once. */
  #empty: Dict | null = null;
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

  /** Whether the phrases are all there is to type from right now. */
  get typesUserDictOnly(): boolean {
    return userDictEnabled() && userDictOnly();
  }

  /**
   * The dictionary the phrases are built on: the empty one, or the built-in
   * one (null). The switches are passed in where one has just been set: a
   * Solid signal reads its old value until the batch is flushed.
   */
  #base(userOnly = userDictOnly()): Dict | null {
    if (!userOnly) return null;
    this.#empty ??= this.jd.emptyDict();
    return this.#empty;
  }

  /**
   * An engine on `dict`, by the switches. With only the phrases to type from
   * and none to be had, an engine on the empty dictionary — nothing to type
   * from — and the IME told why, so keys pass as typed.
   */
  #engineFor(dict: UserDict | null, enabled = userDictEnabled(), userOnly = userDictOnly()): Engine {
    if (!(enabled && userOnly)) {
      ime.setNotice(null);
      return this.jd.createEngine({ userDict: dict });
    }
    const empty = this.#base(true)!;
    if (dict) {
      ime.setNotice(null);
      return this.jd.createEngine({ dict: empty, userDict: dict });
    }
    const why = `用户自造词未能加载：${this.error() ?? "没有词条"}`;
    if (ime.notice() !== why) showToast(`${why}。忽略内置词库时，暂时直接输入字母。`, { tone: "error" });
    ime.setNotice(why);
    return this.jd.createEngine({ dict: empty });
  }

  /** The first engine, from what storage holds — a cached blob when it matches. */
  async boot(jd: JdModule): Promise<Engine> {
    this.#jd = jd;
    const stored = await readStoredDict();
    this.#adoptStored(stored);
    if (stored.source.kind === "file" && stored.text !== null) this.#fileStamp = await this.#stamp(stored.source.handle);
    const dict = userDictEnabled() ? this.#dictAtBoot(stored) : null;
    const engine = this.#engineFor(dict);
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
        return jd.loadUserDict(cached.bytes, { dict: this.#base() });
      } catch {
        return null;
      }
    }
    const bytes = encoder.encode(text);
    const tag = jd.hashUserDictText(bytes);
    if (cached && cached.tag === tag.toString()) {
      try {
        return jd.loadUserDict(cached.bytes, { dict: this.#base() });
      } catch {
        // stale (another libjd, or the other base) or corrupt: rebuild below
      }
    }
    return this.#build(text, { bytes, tag })?.dict ?? null;
  }

  /**
   * Build `text`; on success record the report and cache the blob. Encoded
   * once, for both the hash and the build: 500 000 phrases are 8 MB of UTF-8.
   */
  #build(
    text: string,
    encoded?: { bytes: Uint8Array; tag: bigint },
    userOnly = userDictOnly(),
  ): { dict: UserDict; report: UserDictReport } | null {
    try {
      const bytes = encoded?.bytes ?? encoder.encode(text);
      const tag = encoded?.tag ?? this.jd.hashUserDictText(bytes);
      const built = this.jd.buildUserDict(bytes, { sourceTag: tag, dict: this.#base(userOnly) });
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
      this.#swap(null, false);
      return;
    }
    const built = this.#build(this.text());
    this.#swap(built?.dict ?? null, true);
  }

  /** 忽略内置词库: rebuild the phrases on the other base, and adopt them. */
  setUserOnly(on: boolean): void {
    setUserDictOnly(on);
    const built = this.#build(this.text(), undefined, on);
    if (userDictEnabled()) this.#swap(built?.dict ?? null, true, on);
    else built?.dict.dispose();
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

  #swap(dict: UserDict | null, enabled = userDictEnabled(), userOnly = userDictOnly()): void {
    const old = this.#live;
    if (!old) return;
    const engine = this.#engineFor(dict, enabled, userOnly);
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
