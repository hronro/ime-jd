// 文本: the phrases file in a real text editor — CodeMirror 6, the web's
// answer to the desktop clients' 用文本编辑器打开. Comments and blank lines
// survive here (a table edit rewrites the file without them, as everywhere).
// libjd's notes show as lint marks with the same words and colors as the
// table's status column; every change is saved after a short pause.

import { createEffect, createSignal, onSettled, Show } from "solid-js";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { HighlightStyle, StreamLanguage, syntaxHighlighting } from "@codemirror/language";
import { type Diagnostic, linter, lintGutter } from "@codemirror/lint";
import { highlightSelectionMatches, search, searchKeymap } from "@codemirror/search";
import { EditorState } from "@codemirror/state";
import {
  drawSelection,
  EditorView,
  highlightActiveLine,
  highlightActiveLineGutter,
  highlightTrailingWhitespace,
  highlightWhitespace,
  keymap,
  lineNumbers,
} from "@codemirror/view";
import { tags } from "@lezer/highlight";
import { buildErrorMessage, dict } from "../dict/service";
import { ime } from "../ime/controller";
import { codemirrorTarget } from "../ime/targets/codemirror";
import { problemForNote, problemText } from "./problem";
import "./editor.css";

const SAVE_DELAY = 400;

/** `#` comments, the 词, the TAB, the 编码 — just enough color to read by. */
const phrases = StreamLanguage.define<{ field: number }>({
  name: "jd-phrases",
  startState: () => ({ field: 0 }),
  token(stream, state) {
    if (stream.sol()) {
      state.field = 0;
      stream.eatSpace();
      if (stream.peek() === "#") {
        stream.skipToEnd();
        return "comment";
      }
    }
    if (state.field === 0) {
      if (stream.eat("\t")) {
        state.field = 1;
        return null;
      }
      stream.eatWhile(/[^\t]/);
      return "string";
    }
    stream.skipToEnd();
    return "keyword";
  },
});

const phraseColors = HighlightStyle.define([
  { tag: tags.comment, color: "var(--ink-3)", fontStyle: "italic" },
  { tag: tags.string, color: "var(--ink)" },
  { tag: tags.keyword, color: "var(--seal)", fontFamily: "var(--font-mono)" },
]);

function diagnostics(view: EditorView): Diagnostic[] {
  const text = view.state.doc.toString();
  let report;
  try {
    const built = dict.jd.buildUserDict(text);
    built.dict.dispose();
    report = built.report;
  } catch (e) {
    return [{ from: 0, to: Math.min(text.length, view.state.doc.line(1).to), severity: "error", message: buildErrorMessage(e) }];
  }
  const out: Diagnostic[] = [];
  for (const note of report.notes) {
    if (note.line > view.state.doc.lines) continue;
    const problem = problemForNote(note);
    if (!problem) continue;
    const line = view.state.doc.line(note.line);
    out.push({
      from: line.from,
      to: line.to,
      severity: problem.kind === "invalid" ? "error" : problem.kind === "shared" ? "warning" : "hint",
      message: problemText(problem, "行"),
    });
  }
  return out;
}

export default function TextEditor(props: { active: boolean }) {
  let host: HTMLDivElement | undefined;
  let view: EditorView | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  /** The text this editor last saved (or loaded): its own echo. */
  let mine = dict.text();
  const [state, setState] = createSignal<"saved" | "saving" | "error">("saved");
  const [error, setError] = createSignal("");

  const save = () => {
    clearTimeout(timer);
    if (!view) return;
    const text = view.state.doc.toString();
    if (text === mine) {
      setState("saved");
      return;
    }
    mine = text;
    setState("saving");
    dict.save(text).then(
      () => setState("saved"),
      (e: unknown) => {
        setError(`无法保存用户自造词：${(e as Error).message ?? e}`);
        setState("error");
      },
    );
  };

  onSettled(() => {
    view = new EditorView({
      parent: host!,
      state: EditorState.create({
        doc: dict.text(),
        extensions: [
          lineNumbers(),
          highlightActiveLineGutter(),
          highlightActiveLine(),
          drawSelection(),
          history(),
          search({ top: true }),
          highlightSelectionMatches(),
          highlightWhitespace(),
          highlightTrailingWhitespace(),
          phrases,
          syntaxHighlighting(phraseColors),
          lintGutter(),
          linter(diagnostics, { delay: 250 }),
          EditorState.tabSize.of(8),
          EditorView.lineWrapping,
          EditorView.contentAttributes.of({
            spellcheck: "false",
            autocorrect: "off",
            autocapitalize: "off",
            "aria-label": "用户自造词文本",
          }),
          keymap.of([
            // TAB separates 词 and 编码: it is text here, not indentation or focus.
            {
              key: "Tab",
              run: (v) => {
                v.dispatch(v.state.replaceSelection("\t"), { scrollIntoView: true, userEvent: "input.type" });
                return true;
              },
            },
            { key: "Mod-s", run: () => (save(), true) },
            ...defaultKeymap,
            ...historyKeymap,
            ...searchKeymap,
          ]),
          EditorView.updateListener.of((update) => {
            if (!update.docChanged) return;
            setState("saving");
            clearTimeout(timer);
            timer = setTimeout(save, SAVE_DELAY);
          }),
        ],
      }),
    });
    const unregister = ime.register(view.contentDOM, codemirrorTarget(view));
    return () => {
      save();
      unregister();
      view?.destroy();
      view = undefined;
    };
  });

  // Phrases changed elsewhere (the table, another tab, the linked file):
  // follow, unless an edit here is still waiting to be saved.
  createEffect(
    () => dict.text(),
    (text) => {
      if (!view || text === mine || state() === "saving") return;
      mine = text;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
      setState("saved");
    },
  );

  // Leaving the view saves at once; coming back focuses the editor.
  createEffect(
    () => props.active,
    (active) => {
      if (!active) save();
      else queueMicrotask(() => view?.focus());
    },
  );

  return (
    <div class="ud-text">
      <div ref={(el) => (host = el)} class="ud-cm" />
      <p class="ud-text-status" aria-live="polite">
        <Show when={state() !== "error"} fallback={<span class="tone-bad">{error()}</span>}>
          {state() === "saving" ? "正在保存…" : "已保存"}
        </Show>
        <span class="ud-text-tip">每行一条：词、制表符（Tab）、编码。以 # 开头的行是注释。</span>
      </p>
    </div>
  );
}
