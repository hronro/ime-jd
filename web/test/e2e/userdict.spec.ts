import { readFileSync } from "node:fs";
import type { Page } from "@playwright/test";
import { editor, expect, isMobile, ready, test } from "./fixtures";

test.beforeEach(({}, info) => {
  test.skip(isMobile(info.project.name), "the phone layout has its own test");
});

async function openManager(page: Page) {
  await page.getByRole("button", { name: "用户自造词" }).click();
  await expect(page.locator(".ud")).toBeVisible();
}

/** Add a phrase through the table: 词 typed with the IME, 编码 as letters. */
async function addPhrase(page: Page, word: string, keys: string) {
  await page.getByRole("button", { name: "添加", exact: true }).click();
  await expect(page.locator(".ud-input")).toBeFocused();
  await page.keyboard.type(word);
  await page.keyboard.press("Tab");
  await page.keyboard.type(keys);
  await page.keyboard.press("Enter");
}

test("a phrase added in the table is typed at once; libjd's verdicts show", async ({ page }) => {
  await ready(page);
  await openManager(page);
  await page.locator(".ud-enable").click();
  await addPhrase(page, "n ", "zzzzzz");
  await expect(page.locator(".ud-row")).toHaveCount(1);
  await expect(page.locator(".ud-cell-keys").first()).toHaveText("zzzzzz");
  await addPhrase(page, "n ", "zzzzzz");
  await expect(page.locator(".ud-verdict").nth(1)).toHaveText("与第 1 条重复，不生效");
  await expect(page.locator(".ud-status")).toHaveText("共 2 条，1 条重复");

  await page.getByRole("button", { name: "移除重复词条" }).click();
  await expect(page.locator(".confirm-title")).toHaveText("移除 1 条重复词条？");
  await page.getByRole("button", { name: "移除", exact: true }).click();
  await expect(page.locator(".ud-row")).toHaveCount(1);

  await page.keyboard.press("Escape");
  await expect(page.locator(".ud")).toBeHidden();
  await editor(page).click();
  await page.keyboard.type("zzzzzz ");
  await expect(editor(page)).toHaveValue("你");
});

test("the text view edits the same file, with libjd's notes as lint marks", async ({ page }) => {
  await ready(page);
  await openManager(page);
  await page.getByRole("radio", { name: "文本" }).check();
  const content = page.locator(".cm-content");
  await expect(content).toBeVisible();
  await content.click();
  await page.keyboard.press("ControlOrMeta+End");
  await page.keyboard.type("n ");
  await page.keyboard.press("Tab");
  // After the TAB the IME steps aside: the 编码 is plain letters.
  await page.keyboard.type("zzzzzz");
  await page.keyboard.press("Enter");
  await page.keyboard.type("bad line");
  await expect(page.locator(".ud-text-status")).toContainText("已保存", { timeout: 5000 });
  await expect(page.locator(".cm-lintRange-error")).toHaveCount(1);

  await page.getByRole("radio", { name: "表格" }).check();
  await expect(page.locator(".ud-row")).toHaveCount(2);
  await expect(page.locator(".ud-verdict").nth(1)).toHaveText("缺少制表符（无编码），不生效");
});

test("import appends a file's rows as they are; export writes the file", async ({ page }) => {
  // The <input type=file> / download path that Firefox and Safari take.
  await page.addInitScript(() => {
    delete (window as Partial<Window>).showOpenFilePicker;
    delete (window as Partial<Window>).showSaveFilePicker;
  });
  await ready(page);
  await openManager(page);
  const chooser = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: "从文本文件导入…" }).click();
  await (await chooser).setFiles({
    name: "phrases.txt",
    mimeType: "text/plain",
    buffer: Buffer.from("﻿# comment\n键道\tzzzzzz\n键道\tzzzzzz\n", "utf8"),
  });
  await expect(page.locator(".ud-row")).toHaveCount(2);
  await expect(page.locator(".ud-notice")).toContainText("已追加 2 条词条");
  await expect(page.locator(".ud-verdict").nth(1)).toHaveText("与第 1 条重复，不生效");

  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "导出…" }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe("用户自造词.txt");
  const text = readFileSync((await file.path())!, "utf8");
  expect(text).toContain("键道\tzzzzzz\n键道\tzzzzzz\n");
  expect(text.startsWith("# 键道用户自造词")).toBe(true);
});
