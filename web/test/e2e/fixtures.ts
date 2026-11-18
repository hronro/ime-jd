import { test as base, expect, type Page } from "@playwright/test";

/** Every page: no uncaught errors or console errors. */
export const test = base.extend<{ errors: string[] }>({
  errors: [
    async ({ page }, use) => {
      const errors: string[] = [];
      page.on("pageerror", (e) => errors.push(String(e)));
      page.on("console", (m) => {
        if (m.type() === "error") errors.push(m.text());
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
