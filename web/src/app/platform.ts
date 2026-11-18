// Apple platforms use ⌘ where others use Ctrl for the copy/clear shortcuts.
const platform =
  (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform ??
  navigator.platform ??
  "";

export const isApple = /mac|iphone|ipad|ipod/i.test(platform) || /Mac OS X/.test(navigator.userAgent);

/** The primary shortcut modifier is held (⌘ on Apple platforms, Ctrl elsewhere). */
export const primaryModifier = (e: KeyboardEvent) => (isApple ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey);

export const MOD = isApple ? "⌘" : "Ctrl+";
