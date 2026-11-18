// The IME's adapter for a CodeMirror 6 editor (the phrases text view).
import type { EditorView } from "@codemirror/view";
import type { ImeTarget } from "../target";

export function codemirrorTarget(view: EditorView): ImeTarget {
  return {
    element: view.contentDOM,
    multiline: true,
    wantsTab: true,
    insert(text) {
      view.dispatch(view.state.replaceSelection(text), {
        scrollIntoView: true,
        userEvent: "input.type",
      });
    },
    caretRect() {
      const head = view.state.selection.main.head;
      const rect = view.coordsAtPos(head);
      return rect ? { left: rect.left, top: rect.top, bottom: rect.bottom } : null;
    },
    imeOff() {
      // After the line's first TAB comes the 编码: letters, not Chinese.
      const head = view.state.selection.main.head;
      const line = view.state.doc.lineAt(head);
      const before = line.text.slice(0, head - line.from);
      return before.includes("\t") && !line.text.trimStart().startsWith("#");
    },
    selectedText() {
      const { from, to } = view.state.selection.main;
      return view.state.sliceDoc(from, to);
    },
  };
}

