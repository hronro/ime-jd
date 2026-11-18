import type { Page } from "@playwright/test";
import { editor, expect, isMobile, ready, test } from "./fixtures";

test.beforeEach(({}, info) => {
  test.skip(isMobile(info.project.name), "hardware-keyboard behaviour");
});

/** The page's own shortcut modifier (⌘ on Apple platforms, Ctrl elsewhere). */
const modifier = (page: Page) =>
  page.evaluate(() => {
    const p = (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform ?? navigator.platform;
    return /mac|iphone|ipad|ipod/i.test(p) || /Mac OS X/.test(navigator.userAgent) ? "Meta" : "Control";
  });

test("letters compose in the caret popup; space commits the first candidate", async ({ page }) => {
  await ready(page);
  await page.keyboard.type("nk");
  const popup = page.locator(".cand-popup");
  await expect(popup).toBeVisible();
  await expect(popup.locator(".cand-code")).toHaveText("nk");
  await expect(popup.locator(".cand")).toHaveCount(9);
  const first = await popup.locator(".cand-value").first().textContent();
  await page.keyboard.press(" ");
  await expect(editor(page)).toHaveValue(first!);
  await expect(popup).toBeHidden();
});

test("digits pick; = and - page; enter commits the letters; escape cancels", async ({ page }) => {
  await ready(page);
  await page.keyboard.type("nk");
  const popup = page.locator(".cand-popup");
  const third = await popup.locator(".cand-value").nth(2).textContent();
  await page.keyboard.press("3");
  await expect(editor(page)).toHaveValue(third!);

  await page.keyboard.type("nk");
  await page.keyboard.press("=");
  await expect(popup.locator(".cand-page")).toContainText("2");
  const onPage2 = await popup.locator(".cand-value").first().textContent();
  await page.keyboard.press(" ");
  await expect(editor(page)).toHaveValue(third! + onPage2!);

  await page.keyboard.type("nk");
  await page.keyboard.press("Enter");
  await expect(editor(page)).toHaveValue(third! + onPage2! + "nk");

  await page.keyboard.type("nk");
  await page.keyboard.press("Escape");
  await expect(popup).toBeHidden();
  await expect(editor(page)).toHaveValue(third! + onPage2! + "nk");
});

test("punctuation converts and commits with the anchor (n. → 你。)", async ({ page }) => {
  await ready(page);
  await page.keyboard.type("n.");
  await expect(editor(page)).toHaveValue("你。");
});

test("shift alone switches 中/英", async ({ page }) => {
  await ready(page);
  const mode = page.locator(".mode");
  await expect(mode).toHaveText("中");
  await page.keyboard.press("Shift");
  await expect(mode).toHaveText("英");
  await page.keyboard.type("ab c");
  await expect(editor(page)).toHaveValue("ab c");
  await page.keyboard.press("Shift");
  await expect(mode).toHaveText("中");
});

test("clicking a candidate commits it and keeps the editor focused", async ({ page }) => {
  await ready(page);
  await page.keyboard.type("nk");
  const second = page.locator(".cand-value").nth(1);
  const value = await second.textContent();
  await second.click();
  await expect(editor(page)).toHaveValue(value!);
  await expect(editor(page)).toBeFocused();
});

test("copy all, then clear — and undo the clear", async ({ page, context, browserName }) => {
  if (browserName === "chromium") await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await ready(page);
  const mod = await modifier(page);
  await page.keyboard.type("n.");
  await page.keyboard.press(`${mod}+Enter`);
  await expect(page.locator(".toast")).toContainText("已复制 2 字");
  if (browserName === "chromium") expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("你。");

  await page.keyboard.press(`${mod}+Backspace`);
  await expect(editor(page)).toHaveValue("");
  await page.locator(".toast-action").click();
  await expect(editor(page)).toHaveValue("你。");
});

test("the draft survives a reload", async ({ page }) => {
  await ready(page);
  await page.keyboard.type("n.");
  await page.waitForTimeout(700);
  await page.reload();
  await expect(page.locator(".loading")).toHaveCount(0);
  await expect(editor(page)).toHaveValue("你。");
});

test("feature code is not fetched until it is used", async ({ page }) => {
  const fetched: string[] = [];
  page.on("request", (r) => fetched.push(new URL(r.url()).pathname));
  await ready(page);
  await page.keyboard.type("nk ");
  const lazy = fetched.filter((p) => /UserDict|TextEditor|CandidateBar|Lookup|Settings|Help/.test(p));
  expect(lazy).toEqual([]);
  await page.getByRole("button", { name: "编码反查" }).click();
  await expect(page.locator(".lookup-form")).toBeVisible();
  expect(fetched.some((p) => /LookupDialog/.test(p))).toBe(true);
});
