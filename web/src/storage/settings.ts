// User settings, one localStorage key each, mirrored into signals. The
// appearance override is applied through <meta name="color-scheme"> (see the
// inline script in index.html, which applies it before first paint).

import { createSignal } from "solid-js";
import { readLocal, writeLocal } from "./local";

export type Theme = "system" | "light" | "dark";

const KEYS = {
  theme: "jd.theme",
  fontSize: "jd.fontSize",
  codeHints: "jd.codeHints",
  userDict: "jd.userDict.enabled",
  userDictOnly: "jd.userDict.only",
} as const;

export const FONT_SIZES = [16, 18, 20, 22, 24, 28] as const;
const DEFAULT_FONT_SIZE = 20;

function readTheme(): Theme {
  const value = readLocal(KEYS.theme);
  return value === "light" || value === "dark" ? value : "system";
}

function readFontSize(): number {
  const value = Number(readLocal(KEYS.fontSize));
  return (FONT_SIZES as readonly number[]).includes(value) ? value : DEFAULT_FONT_SIZE;
}

const [theme, setThemeSignal] = createSignal<Theme>(readTheme());
const [fontSize, setFontSizeSignal] = createSignal(readFontSize());
const [codeHints, setCodeHintsSignal] = createSignal(readLocal(KEYS.codeHints) === "1");
// Off by default, as in every client.
const [userDictEnabled, setUserDictSignal] = createSignal(readLocal(KEYS.userDict) === "1");
// 忽略内置词库: off by default, and heeded only while the user dictionary is on.
const [userDictOnly, setUserDictOnlySignal] = createSignal(readLocal(KEYS.userDictOnly) === "1");

export { codeHints, fontSize, theme, userDictEnabled, userDictOnly };

export function applyTheme(value: Theme): void {
  const meta = document.querySelector<HTMLMetaElement>('meta[name="color-scheme"]');
  if (meta) meta.content = value === "system" ? "light dark" : value;
}

export function applyFontSize(value: number): void {
  document.documentElement.style.setProperty("--text-size", `${value}px`);
}

export function setTheme(value: Theme): void {
  writeLocal(KEYS.theme, value === "system" ? null : value);
  setThemeSignal(value);
  applyTheme(value);
}

export function setFontSize(value: number): void {
  writeLocal(KEYS.fontSize, value === DEFAULT_FONT_SIZE ? null : String(value));
  setFontSizeSignal(value);
  applyFontSize(value);
}

export function setCodeHints(value: boolean): void {
  writeLocal(KEYS.codeHints, value ? "1" : null);
  setCodeHintsSignal(value);
}

export function setUserDictEnabled(value: boolean): void {
  writeLocal(KEYS.userDict, value ? "1" : null);
  setUserDictSignal(value);
}

export function setUserDictOnly(value: boolean): void {
  writeLocal(KEYS.userDictOnly, value ? "1" : null);
  setUserDictOnlySignal(value);
}

/** Another tab changed a setting: follow it. */
export function followOtherTabs(): void {
  addEventListener("storage", (e) => {
    switch (e.key) {
      case KEYS.theme:
        setThemeSignal(readTheme());
        applyTheme(readTheme());
        break;
      case KEYS.fontSize:
        setFontSizeSignal(readFontSize());
        applyFontSize(readFontSize());
        break;
      case KEYS.codeHints:
        setCodeHintsSignal(readLocal(KEYS.codeHints) === "1");
        break;
    }
  });
}
