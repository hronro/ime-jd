// localStorage, which can throw (blocked site data) or be missing (some
// private modes). Everything kept here is a convenience the page works
// without: settings and the draft.

export function readLocal(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function writeLocal(key: string, value: string | null): void {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // Not persisted; the page keeps working with what it has in memory.
  }
}
