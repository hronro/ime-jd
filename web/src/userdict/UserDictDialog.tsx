// 用户自造词: the phrase manager, after macos/JdIME/UserDict/
// UserDictWindowController.swift — a table of 词 / 编码 / 状态 with libjd's
// verdict per row, 移除重复词条, and the bundled text editor (the desktop
// clients' 用文本编辑器打开); plus import/export, and on Chromium a real file
// on disk as the source of truth. On phones the rows become cards and editing
// moves to a sheet, as on iOS.

import { createEffect, createMemo, createSignal, lazy, Loading, Match, onSettled, Show, Switch as Branch } from "solid-js";
import { buildErrorMessage, dict, userDictLimits } from "../dict/service";
import { IME_FIELD_ATTRS } from "../ime/target";
import { unlinkFile, linkFile, writeBrowserText, readFileText, writeFileText } from "../storage/userdict";
import { userDictEnabled, userDictOnly } from "../storage/settings";
import { ask, ConfirmHost } from "../ui/Confirm";
import { Dialog } from "../ui/Dialog";
import { ExportIcon, ImportIcon, LinkIcon, MinusIcon, PlusIcon, SearchIcon, TableIcon, TextIcon, WarnIcon } from "../ui/icons";
import { Switch } from "../ui/Switch";
import { Cards } from "./Cards";
import { canLinkFile, exportText, pickExistingFile, pickNewFile, pickTextFile, ReadError } from "./files";
import { parse, serialize } from "./format";
import { createModel } from "./model";
import { RowSheet, type SheetState } from "./RowSheet";
import { Table } from "./Table";
import { useMedia } from "./media";
import "./userdict.css";

const TextEditor = lazy(() => import("./TextEditor"));

type View = "table" | "text";

export default function UserDictDialog(props: { open: boolean; onClose: () => void }) {
  const model = createModel();
  const narrow = useMedia("(max-width: 600px)");
  const [view, setView] = createSignal<View>("table");
  const [notice, setNotice] = createSignal<string | null>(null);
  const [sheet, setSheet] = createSignal<SheetState | null>(null);
  let menu: HTMLDivElement | undefined;

  // Opening: make sure libjd's verdicts are there (boot may have used the cache).
  createEffect(
    () => props.open,
    (open) => {
      if (open) dict.ensureReport();
    },
  );

  // The undo offer and notices fade after a while.
  createEffect(
    () => [model.undo(), notice()] as const,
    ([undo, text]) => {
      if (!undo && !text) return;
      const timer = setTimeout(() => {
        model.setUndo(null);
        setNotice(null);
      }, 8000);
      return () => clearTimeout(timer);
    },
  );

  const status = createMemo(() => {
    const c = model.counts();
    const parts = [`共 ${c.total} 条`];
    if (c.invalid > 0) parts.push(`${c.invalid} 条无效`);
    if (c.duplicate > 0) parts.push(`${c.duplicate} 条重复`);
    if (c.shared > 0) parts.push(`${c.shared} 条同码`);
    if (!userDictEnabled()) parts.push("已停用");
    else if (userDictOnly()) parts.push(c.total === 0 ? "已忽略内置词库，但尚无词条：只能输入字母和标点" : "已忽略内置词库");
    return parts.join("，");
  });

  // MARK: - Actions

  const capReached = () =>
    ask({ title: "词条数量已达上限", text: `用户自造词最多 ${userDictLimits().maxEntries} 条。`, buttons: [{ label: "好", value: "ok", tone: "primary" }] });

  const [editRequest, setEditRequest] = createSignal<number | null>(null);

  const add = () => {
    if (narrow()) {
      if (model.rows().length >= userDictLimits().maxEntries) void capReached();
      else setSheet({ mode: "add" });
      return;
    }
    const selected = [...model.selected()];
    const id = model.addRow(selected.length > 0 ? selected[selected.length - 1]! : null);
    if (id === null) void capReached();
    else setEditRequest(id);
  };

  const removeSelected = async () => {
    const ids = model.selected();
    if (ids.size === 0) return;
    if (ids.size > 1) {
      const choice = await ask({
        title: `删除选中的 ${ids.size} 条词条？`,
        text: "删除后立即生效。",
        buttons: [
          { label: "取消", value: "", tone: "quiet" },
          { label: "删除", value: "delete", tone: "danger" },
        ],
      });
      if (choice !== "delete") return;
    }
    model.removeRows(ids);
    setNotice(`已删除 ${ids.size} 条`);
  };

  const invalidNote = (n: number) => `另有 ${n} 条无效的词条（标红），输入法已跳过。`;

  const removeDuplicates = async () => {
    const error = dict.error();
    if (error) {
      const choice = await ask({
        title: "无法移除重复词条",
        text: `用户自造词文件无法读入：${error}。请用文本编辑器修正文件；文件可读后，状态列才会标出无效、重复与同码的词条。`,
        buttons: [
          { label: "用文本编辑器打开", value: "text", tone: "quiet" },
          { label: "好", value: "ok", tone: "primary" },
        ],
      });
      if (choice === "text") setView("text");
      return;
    }
    const rows = model.rows();
    const problems = model.problems();
    const duplicates: number[] = [];
    const shared: number[] = [];
    let invalid = 0;
    let ofRows = 0;
    problems.forEach((p, i) => {
      if (p?.kind === "duplicate") {
        duplicates.push(rows[i]!.id);
        if (p.ofRow !== null) ofRows++;
      } else if (p?.kind === "shared") shared.push(rows[i]!.id);
      else if (p?.kind === "invalid") invalid++;
    });
    if (duplicates.length === 0 && shared.length === 0) {
      let text = "与前面某条词条完全相同、或与内置词库中同一编码下的词相同的词条，算重复，不会生效。";
      if (invalid > 0) text += "\n" + invalidNote(invalid);
      await ask({ title: "没有重复词条", text, buttons: [{ label: "好", value: "ok", tone: "primary" }] });
      return;
    }
    const details: string[] = [];
    if (duplicates.length > 0) {
      details.push(
        `重复：${ofRows} 条与前面的词条相同，${duplicates.length - ofRows} 条与内置词库相同；这些词条不会出现在候选中。`,
      );
    }
    if (shared.length > 0) {
      details.push(
        `同码（保留）：${shared.length} 条词条的编码已有内置词或其他自造词；这些词条仍然生效，并排在内置词之前，多条自造词同码时按表中顺序排列。`,
      );
    }
    if (invalid > 0) details.push(invalidNote(invalid));
    const choice = await ask({
      title: duplicates.length === 0 ? "没有重复词条" : `移除 ${duplicates.length} 条重复词条？`,
      text: details.join("\n"),
      buttons:
        duplicates.length === 0
          ? [
              { label: "选中查看", value: "show", tone: "quiet" },
              { label: "好", value: "ok", tone: "primary" },
            ]
          : [
              { label: "取消", value: "", tone: "quiet" },
              { label: "选中查看", value: "show", tone: "quiet" },
              { label: "移除", value: "remove", tone: "danger" },
            ],
    });
    if (choice === "remove") {
      model.removeRows(new Set(duplicates));
      setNotice(`已移除 ${duplicates.length} 条重复词条`);
    } else if (choice === "show") {
      model.setFilter("");
      setView("table");
      model.setSelected(new Set([...duplicates, ...shared]));
    }
  };

  const importFile = async () => {
    closeMenu();
    try {
      const file = await pickTextFile();
      if (!file) return;
      const rows = parse(file.text);
      if (rows.length === 0) {
        await ask({ title: "文件中没有词条", text: `「${file.name}」里没有可导入的行。`, buttons: [{ label: "好", value: "ok", tone: "primary" }] });
        return;
      }
      // Appended exactly as they are; refused only if libjd could not build
      // the whole result (too many phrases, too much text).
      const merged = serialize([...model.entries(), ...rows]);
      try {
        dict.jd.buildUserDict(merged).dict.dispose();
      } catch (e) {
        await ask({ title: "无法导入", text: `合并后${buildErrorMessage(e)}。`, buttons: [{ label: "好", value: "ok", tone: "primary" }] });
        return;
      }
      model.appendRows(rows);
      setView("table");
      setNotice(`已追加 ${rows.length} 条词条`);
    } catch (e) {
      await ask({ title: "无法导入", text: e instanceof ReadError ? e.message : String(e), buttons: [{ label: "好", value: "ok", tone: "primary" }] });
    }
  };

  const exportFile = async () => {
    closeMenu();
    try {
      if (await exportText(dict.text() || serialize([]))) setNotice("已导出");
    } catch (e) {
      await ask({ title: "无法导出", text: String((e as Error).message ?? e), buttons: [{ label: "好", value: "ok", tone: "primary" }] });
    }
  };

  // MARK: - The file on disk

  const linkNew = async () => {
    closeMenu();
    const handle = await pickNewFile().catch(() => null);
    if (!handle) return;
    const text = dict.text() || serialize([]);
    try {
      await writeFileText(handle, text);
      await linkFile(handle);
      await dict.adoptSource({ kind: "file", handle }, text);
      setNotice(`词条现保存在「${handle.name}」`);
    } catch (e) {
      await ask({ title: "无法关联文件", text: String((e as Error).message ?? e), buttons: [{ label: "好", value: "ok", tone: "primary" }] });
    }
  };

  const linkExisting = async () => {
    closeMenu();
    const handle = await pickExistingFile().catch(() => null);
    if (!handle) return;
    try {
      const text = await readFileText(handle);
      const theirs = parse(text).length;
      const ours = model.rows().length;
      if (ours > 0) {
        const choice = await ask({
          title: `改用「${handle.name}」中的 ${theirs} 条词条？`,
          text: `浏览器中现有的 ${ours} 条词条将不再使用；它们仍保存在浏览器里，取消关联后可以继续用。`,
          buttons: [
            { label: "取消", value: "", tone: "quiet" },
            { label: "改用文件", value: "use", tone: "primary" },
          ],
        });
        if (choice !== "use") return;
      }
      await linkFile(handle);
      await dict.adoptSource({ kind: "file", handle }, text);
      setNotice(`已关联「${handle.name}」`);
    } catch (e) {
      await ask({ title: "无法关联文件", text: e instanceof Error ? e.message : String(e), buttons: [{ label: "好", value: "ok", tone: "primary" }] });
    }
  };

  const unlink = async () => {
    const source = dict.source();
    if (source.kind !== "file") return;
    const choice = await ask({
      title: `取消关联「${source.handle.name}」？`,
      text: "当前的词条会复制回浏览器中保存；磁盘上的文件保持不变。",
      buttons: [
        { label: "取消", value: "", tone: "quiet" },
        { label: "取消关联", value: "unlink", tone: "primary" },
      ],
    });
    if (choice !== "unlink") return;
    const text = dict.text();
    await writeBrowserText(text);
    await unlinkFile();
    await dict.adoptSource({ kind: "browser" }, text);
    setNotice("词条现保存在浏览器中");
  };

  const closeMenu = () => menu?.matches(":popover-open") && menu.hidePopover();

  onSettled(() => {
    // ⌘/Ctrl+F searches the table while the manager is open.
    const onKey = (e: KeyboardEvent) => {
      if (!props.open || view() !== "table") return;
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "f") {
        e.preventDefault();
        document.getElementById("ud-search")?.focus();
      }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  });

  const viewSwitch = (
    <div class="segmented ud-views" role="radiogroup" aria-label="显示方式">
      <label class="segment">
        <input type="radio" name="ud-view" checked={view() === "table"} onChange={() => setView("table")} />
        <TableIcon />
        <span>表格</span>
      </label>
      <label class="segment">
        <input type="radio" name="ud-view" checked={view() === "text"} onChange={() => setView("text")} />
        <TextIcon />
        <span>文本</span>
      </label>
    </div>
  );

  return (
    <Dialog open={props.open} title="用户自造词" size="l" onClose={props.onClose} headerExtra={viewSwitch}>
      <div class="ud">
        <div class="ud-top">
          <label class="ud-enable">
            <Switch label="启用用户自造词" checked={userDictEnabled()} onChange={(on) => dict.setEnabled(on)} />
            <span>启用用户自造词</span>
          </label>
          <label class="ud-enable" title="只用这里的词条打字">
            <Switch
              label="忽略内置词库"
              checked={userDictOnly()}
              disabled={!userDictEnabled()}
              onChange={(on) => dict.setUserOnly(on)}
            />
            <span>忽略内置词库</span>
          </label>
          <Show when={view() === "table"}>
            <div class="ud-search">
              <SearchIcon />
              <input
                id="ud-search"
                type="search"
                class="field"
                placeholder="搜索词或编码"
                aria-label="搜索词或编码"
                {...IME_FIELD_ATTRS}
                value={model.filter()}
                onInput={(e) => model.setFilter(e.currentTarget.value)}
              />
            </div>
          </Show>
        </div>

        <div class="ud-files">
          <span class="ud-source-text">
            <Show when={dict.source().kind === "file" ? (dict.source() as { handle: FileSystemFileHandle }).handle : null} fallback="保存在此浏览器中">
              {(handle) => (
                <>
                  <LinkIcon />
                  保存在磁盘文件<b>「{handle().name}」</b>
                </>
              )}
            </Show>
          </span>
          <Show when={dict.needsPermission()}>
            <button type="button" class="btn btn-primary ud-small" onClick={() => void dict.reauthorize()}>
              授权访问文件
            </button>
          </Show>
          <button type="button" class="btn btn-quiet ud-small" onClick={() => void importFile()}>
            <ImportIcon />
            从文本文件导入…
          </button>
          <button type="button" class="btn btn-quiet ud-small" onClick={() => void exportFile()}>
            <ExportIcon />
            导出…
          </button>
          <Show when={canLinkFile}>
            <Show
              when={dict.source().kind === "file"}
              fallback={
                <>
                  <button
                    type="button"
                    id="ud-link"
                    class="btn btn-quiet ud-small"
                    {...({ popovertarget: "ud-link-menu" } as Record<string, string>)}
                  >
                    <LinkIcon />
                    关联磁盘文件…
                  </button>
                  <div
                    ref={(el) => (menu = el)}
                    id="ud-link-menu"
                    class="menu"
                    popover="auto"
                    role="menu"
                    onToggle={(e) => {
                      if ((e as ToggleEvent).newState !== "open") return;
                      const r = document.getElementById("ud-link")!.getBoundingClientRect();
                      const m = e.currentTarget as HTMLElement;
                      m.style.translate = `${Math.round(Math.min(r.left, innerWidth - m.offsetWidth - 8))}px ${Math.round(r.bottom + 6)}px`;
                    }}
                  >
                    <button type="button" role="menuitem" class="menu-item" onClick={() => void linkNew()}>
                      <ExportIcon />
                      新建文件，写入现有词条…
                    </button>
                    <button type="button" role="menuitem" class="menu-item" onClick={() => void linkExisting()}>
                      <ImportIcon />
                      打开已有文件…
                    </button>
                    <p class="menu-note">关联后，词条直接读写这个文件（例如放在同步盘里），浏览器只保留缓存。</p>
                  </div>
                </>
              }
            >
              <button type="button" class="btn btn-quiet ud-small" onClick={() => void unlink()}>
                取消关联
              </button>
            </Show>
          </Show>
        </div>

        <Show when={dict.error() ?? model.saveError()}>
          {(message) => (
            <p class="ud-error" role="alert">
              <WarnIcon />
              {message()}
            </p>
          )}
        </Show>

        <div class="ud-main">
          <Branch>
            <Match when={view() === "text"}>
              <Loading fallback={<p class="ud-loading">正在载入编辑器…</p>}>
                <TextEditor active={props.open && view() === "text"} />
              </Loading>
            </Match>
            <Match when={narrow()}>
              <Cards model={model} onOpen={(row) => setSheet({ mode: "edit", row })} />
            </Match>
            <Match when={true}>
              <Table model={model} editRequest={editRequest()} onEditHandled={() => setEditRequest(null)} />
            </Match>
          </Branch>
        </div>

        <Show when={model.undo() ?? notice()}>
          <div class="ud-notice" role="status">
            <span>{notice() ?? "已更改"}</span>
            <Show when={model.undo()}>
              <button
                type="button"
                class="btn btn-quiet ud-small"
                onClick={() => {
                  model.restore();
                  setNotice(null);
                }}
              >
                撤销
              </button>
            </Show>
          </div>
        </Show>

        <footer class="ud-bar">
          <Show when={view() === "table"}>
            <div class="ud-actions">
              <button type="button" class="btn ud-small" onClick={add}>
                <PlusIcon />
                添加
              </button>
              <Show when={!narrow()}>
                <button type="button" class="btn ud-small" aria-disabled={model.selected().size === 0 ? "true" : "false"} onClick={() => void removeSelected()}>
                  <MinusIcon />
                  删除<Show when={model.selected().size > 0}>（{model.selected().size}）</Show>
                </button>
              </Show>
              <button type="button" class="btn btn-quiet ud-small" onClick={() => void removeDuplicates()}>
                移除重复词条
              </button>
            </div>
          </Show>
          <span class="ud-status" title={status()}>
            {status()}
          </span>
        </footer>
      </div>

      <RowSheet state={sheet()} model={model} onClose={() => setSheet(null)} />
      <ConfirmHost />
    </Dialog>
  );
}
