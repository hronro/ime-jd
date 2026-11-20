import { test as base, expect, type Page } from "@playwright/test";

/**
 * Console errors that are the browser's, not the page's. WebKit has no
 * `interactive-widget` (index.html sets it for Chrome and Firefox on
 * Android) and says so at error level wherever it reads the viewport tag:
 * Safari on iOS, and Playwright's Linux WebKit in every project.
 */
const BROWSER_NOTES = new Set(['Viewport argument key "interactive-widget" not recognized and ignored.']);

/** Every page: no uncaught errors or console errors. */
export const test = base.extend<{ errors: string[] }>({
  errors: [
    async ({ page }, use) => {
      const errors: string[] = [];
      page.on("pageerror", (e) => errors.push(String(e)));
      page.on("console", (m) => {
        if (m.type() === "error" && !BROWSER_NOTES.has(m.text())) errors.push(m.text());
      });
      await use(errors);
      expect(errors, "console errors").toEqual([]);
    },
    { auto: true },
  ],
});

export { expect };

export async function ready(page: Page): Promise<void> {
  await page.goto("/");
  await expect(page.locator(".loading")).toHaveCount(0, { timeout: 20_000 });
}

/** What a touch keyboard sends: a cancelable beforeinput per character. */
export async function softType(page: Page, text: string): Promise<void> {
  for (const ch of text) await page.keyboard.insertText(ch);
}

export const editor = (page: Page) => page.locator(".editor");

export const isMobile = (projectName: string) => projectName === "pixel" || projectName === "iphone";
