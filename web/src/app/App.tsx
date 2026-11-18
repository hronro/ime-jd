import { createMemo, createSignal, lazy, Loading, onSettled, Show } from "solid-js";
import { ime } from "../ime/controller";
import { ImeLayer } from "../ime/ImeLayer";
import { IME_FIELD_ATTRS } from "../ime/target";
import { flushDraft, loadDraft, saveDraft } from "../storage/draft";
import { codeHints } from "../storage/settings";
import { BookIcon, CopyIcon, EraseIcon, HelpIcon, InstallIcon, LookupIcon, MoreIcon, OfflineIcon, SlidersIcon } from "../ui/icons";
import { showToast } from "../ui/toast";
import { Toasts } from "../ui/Toasts";
import { closeDialog, mounted, openDialog, openDialogName, openLookup } from "./dialogs";
import { hint } from "./hints";
import { MOD, primaryModifier } from "./platform";
import { canInstall, install, offlineReady, updateReady, applyUpdate } from "./pwa-state";
import { ready } from "./boot-state";
import "./app.css";

const LookupDialog = lazy(() => import("../lookup/LookupDialog"));
const UserDictDialog = lazy(() => import("../userdict/UserDictDialog"));
const SettingsDialog = lazy(() => import("../settings/SettingsDialog"));
const HelpDialog = lazy(() => import("../help/HelpDialog"));

/** Characters, not counting whitespace — what 字数 means to a writer. */
const countChars = (text: string) => {
  let n = 0;
  for (const ch of text) if (!/\s/.test(ch)) n++;
  return n;
};

export function App() {
  let editor!: HTMLTextAreaElement;
  let menu!: HTMLDivElement;
  const initial = loadDraft();
  const [chars, setChars] = createSignal(countChars(initial));
  const [empty, setEmpty] = createSignal(initial === "");

  const onEdit = () => {
    const text = editor.value;
    setChars(countChars(text));
    setEmpty(text === "");
    saveDraft(text);
  };

  const copyAll = async () => {
    if (ime.target()?.element === editor) ime.commitAnchor();
    const text = editor.value;
    if (text === "") {
      showToast("没有可复制的内容", { tone: "info" });
      return;
    }
    const n = countChars(text);
    try {
      await navigator.clipboard.writeText(text);
      showToast(`已复制 ${n} 字`);
    } catch {
      if (legacyCopy(text)) showToast(`已复制 ${n} 字`);
      else showToast("复制失败：浏览器不允许访问剪贴板", { tone: "error" });
    }
  };

  const clearAll = () => {
    if (ime.target()?.element === editor) ime.cancel();
    const saved = editor.value;
    if (saved === "") return;
    editor.focus();
    editor.select();
    // Through execCommand, so ⌘Z / Ctrl+Z brings the text back as well.
    if (!ime.edit(() => document.execCommand("delete"))) {
      editor.value = "";
      onEdit();
    }
    flushDraft();
    showToast("已清空", {
      tone: "info",
      action: {
        label: "撤销",
        run: () => {
          editor.focus();
          editor.select();
          if (!ime.edit(() => document.execCommand("insertText", false, saved))) {
            editor.value = saved;
            onEdit();
          }
        },
      },
    });
  };

  // A textarea keeps its selection while the button has focus.
  const lookup = () => {
    const selection = editor.value.slice(editor.selectionStart, editor.selectionEnd).trim();
    openLookup([...selection].length <= 40 ? selection : "");
  };

  onSettled(() => {
    editor.value = initial;
    editor.focus();
    editor.setSelectionRange(initial.length, initial.length);

    const onKey = (e: KeyboardEvent) => {
      if (openDialogName() !== null || !primaryModifier(e) || e.shiftKey || e.altKey) return;
      // Only from the editor or the page itself: another field keeps its
      // own ⌘⌫ / Ctrl+Backspace.
      const active = document.activeElement;
      if (active !== editor && active !== document.body && active !== null) {
        if (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) return;
        if (active instanceof HTMLElement && active.isContentEditable) return;
      }
      if (e.key === "Enter") {
        e.preventDefault();
        void copyAll();
      } else if (e.key === "Backspace") {
        e.preventDefault();
        clearAll();
      }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  });

  const placeMenu = (e: Event) => {
    const toggle = e as ToggleEvent;
    if (toggle.newState !== "open") return;
    const button = document.getElementById("more-button")!.getBoundingClientRect();
    menu.style.translate = `${Math.round(Math.max(8, button.right - menu.offsetWidth))}px ${Math.round(button.bottom + 6)}px`;
  };

  const runMenu = (action: () => void) => () => {
    menu.hidePopover();
    action();
  };

  const modeLabel = createMemo(() => (ime.mode() === "zh" ? "中" : "英"));

  return (
    <div class="app">
      <header class="app-head">
        <a class="brand" href="./" aria-label="键道输入法">
          <img class="brand-seal" src="/icons/jd.svg" alt="" width="34" height="34" />
          <span class="brand-name">键道</span>
          <span class="brand-sub">网页版</span>
        </a>
        <nav class="app-tools" aria-label="工具">
          <button type="button" class="btn btn-quiet tool" aria-label="编码反查" onClick={lookup}>
            <LookupIcon />
            <span class="tool-label">编码反查</span>
          </button>
          <button type="button" class="btn btn-quiet tool" aria-label="用户自造词" onClick={() => openDialog("userdict")}>
            <BookIcon />
            <span class="tool-label">用户自造词</span>
          </button>
          <button
            type="button"
            id="more-button"
            class="btn btn-quiet icon-btn"
            aria-label="更多"
            {...({ popovertarget: "more-menu" } as Record<string, string>)}
          >
            <MoreIcon />
          </button>
        </nav>
        <div ref={(el) => (menu = el)} id="more-menu" class="menu" popover="auto" onToggle={placeMenu} role="menu">
          <button type="button" role="menuitem" class="menu-item" onClick={runMenu(() => openDialog("settings"))}>
            <SlidersIcon />
            设置
          </button>
          <button type="button" role="menuitem" class="menu-item" onClick={runMenu(() => openDialog("help"))}>
            <HelpIcon />
            帮助与快捷键
          </button>
          <Show when={canInstall()}>
            <button type="button" role="menuitem" class="menu-item" onClick={runMenu(() => void install())}>
              <InstallIcon />
              安装为应用
            </button>
          </Show>
        </div>
      </header>

      <main class="sheet">
        <textarea
          ref={(el) => (editor = el)}
          class="editor"
          aria-label="输入区"
          {...IME_FIELD_ATTRS}
          {...({ enterkeyhint: "enter" } as Record<string, string>)}
          onInput={onEdit}
        />
        <Show when={empty() && ime.view().code === ""}>
          <div class="empty" aria-hidden="true">
            <p class="empty-title">在这里用键道输入</p>
            <p class="empty-keys hover-only">
              <span>
                <kbd>Shift</kbd> 中/英
              </span>
              <span>
                <kbd>空格</kbd> 上屏
              </span>
              <span>
                <kbd>1</kbd>–<kbd>9</kbd> 选词
              </span>
              <span>
                <kbd>−</kbd> <kbd>=</kbd> 翻页
              </span>
              <span>
                <kbd>⏎</kbd> 上屏编码
              </span>
            </p>
          </div>
        </Show>
        <Show when={!ready()}>
          <div class="loading" role="status">
            <span class="loading-dot" />
            正在载入词库…
          </div>
        </Show>
      </main>

      <footer class="app-foot">
        <div class="status">
          <button
            type="button"
            class={["mode", { "mode-en": ime.mode() === "en" }]}
            title="切换中/英（Shift）"
            aria-label={`当前${ime.mode() === "zh" ? "中文" : "英文"}，点按切换`}
            onPointerDown={(e) => e.preventDefault()}
            onClick={() => ime.toggleMode()}
          >
            {modeLabel()}
          </button>
          <span class="count">{chars()} 字</span>
          <Show when={codeHints() && hint()}>
            {(h) => (
              <span class="hint" aria-live="polite">
                {h().value}
                <span class="hint-arrow">→</span>
                <span class="hint-code">{h().code}</span>
              </span>
            )}
          </Show>
          <Show when={updateReady()}>
            <button type="button" class="chip chip-seal" onClick={() => void applyUpdate()}>
              有新版本 · 刷新
            </button>
          </Show>
          <Show when={offlineReady() && !updateReady()}>
            <span class="chip chip-offline" title="已缓存，离线也能使用">
              <OfflineIcon />
              <span class="chip-label">可离线使用</span>
            </span>
          </Show>
        </div>
        <div class="actions">
          <button type="button" class="btn btn-quiet clear" aria-label="清空内容" onPointerDown={keepFocus} onClick={clearAll}>
            <EraseIcon />
            <span class="clear-label">清空内容</span>
            <kbd class="hover-only">{MOD}⌫</kbd>
          </button>
          <button type="button" class="btn btn-primary" onPointerDown={keepFocus} onClick={() => void copyAll()}>
            <CopyIcon />
            <span>复制到剪贴板</span>
            <kbd class="hover-only">{MOD}⏎</kbd>
          </button>
        </div>
      </footer>

      <ImeLayer host={null} />
      <Toasts />

      <Loading fallback={null}>
        <Show when={mounted().has("lookup")}>
          <LookupDialog open={openDialogName() === "lookup"} onClose={() => closeDialog("lookup")} />
        </Show>
        <Show when={mounted().has("userdict")}>
          <UserDictDialog open={openDialogName() === "userdict"} onClose={() => closeDialog("userdict")} />
        </Show>
        <Show when={mounted().has("settings")}>
          <SettingsDialog open={openDialogName() === "settings"} onClose={() => closeDialog("settings")} />
        </Show>
        <Show when={mounted().has("help")}>
          <HelpDialog open={openDialogName() === "help"} onClose={() => closeDialog("help")} />
        </Show>
      </Loading>
    </div>
  );
}

/** Pressing a button must not pull focus (and the touch keyboard) off the editor. */
const keepFocus = (e: PointerEvent) => {
  if (document.activeElement instanceof HTMLTextAreaElement) e.preventDefault();
};

/** The last resort when the async clipboard is denied: a hidden selection. */
function legacyCopy(text: string): boolean {
  const field = Object.assign(document.createElement("textarea"), { value: text });
  field.setAttribute("readonly", "");
  field.style.cssText = "position:fixed;inset-block-start:0;opacity:0";
  document.body.append(field);
  field.select();
  try {
    return document.execCommand("copy");
  } finally {
    field.remove();
  }
}
