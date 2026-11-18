import { For, Show } from "solid-js";
import { openDialog } from "../app/dialogs";
import { dict } from "../dict/service";
import {
  codeHints,
  FONT_SIZES,
  fontSize,
  setCodeHints,
  setFontSize,
  setTheme,
  type Theme,
  theme,
  userDictEnabled,
} from "../storage/settings";
import { Dialog } from "../ui/Dialog";
import { ChevronRight } from "../ui/icons";
import { Switch } from "../ui/Switch";
import "./settings.css";

const THEMES: readonly { value: Theme; label: string }[] = [
  { value: "system", label: "跟随系统" },
  { value: "light", label: "浅色" },
  { value: "dark", label: "深色" },
];

export default function SettingsDialog(props: { open: boolean; onClose: () => void }) {
  const sizeIndex = () => FONT_SIZES.indexOf(fontSize() as (typeof FONT_SIZES)[number]);
  return (
    <Dialog open={props.open} title="设置" size="s" onClose={props.onClose}>
      <div class="settings">
        <section class="set-group">
          <h3 class="set-heading">外观</h3>
          <div class="segmented" role="radiogroup" aria-label="外观">
            <For each={THEMES}>
              {(option) => (
                <label class="segment">
                  <input
                    type="radio"
                    name="theme"
                    value={option.value}
                    checked={theme() === option.value}
                    onChange={() => setTheme(option.value)}
                  />
                  <span>{option.label}</span>
                </label>
              )}
            </For>
          </div>
        </section>

        <section class="set-group">
          <h3 class="set-heading">
            <label for="font-size">字号</label>
            <span class="set-value">{fontSize()} px</span>
          </h3>
          <input
            id="font-size"
            class="slider"
            type="range"
            min="0"
            max={FONT_SIZES.length - 1}
            step="1"
            value={sizeIndex()}
            onInput={(e) => setFontSize(FONT_SIZES[Number(e.currentTarget.value)]!)}
          />
          <p class="set-preview" style={{ "font-size": `${fontSize()}px` }}>
            键道输入法，快意书写。
          </p>
        </section>

        <section class="set-group">
          <div class="set-row">
            <div>
              <label class="set-title" for="code-hints">
                编码提示
              </label>
              <p class="set-note">打出的词有更好的编码时——按键更少，或按键一样多但不用选重——在下方提示这个编码。</p>
            </div>
            <Switch id="code-hints" label="编码提示" checked={codeHints()} onChange={setCodeHints} />
          </div>
        </section>

        <section class="set-group">
          <button
            type="button"
            class="set-link"
            onClick={() => {
              props.onClose();
              openDialog("userdict");
            }}
          >
            <span>
              <span class="set-title">用户自造词</span>
              <span class="set-note">
                <Show when={userDictEnabled()} fallback="未启用">
                  已启用
                  <Show when={dict.report()}>{(r) => `，${r().entries} 条生效`}</Show>
                </Show>
              </span>
            </span>
            <ChevronRight />
          </button>
        </section>

        <p class="set-version">键道输入法网页版 {__JD_VERSION__}</p>
      </div>
    </Dialog>
  );
}
