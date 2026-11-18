import { editor, expect, isMobile, ready, test } from "./fixtures";

test.beforeEach(({}, info) => {
  test.skip(isMobile(info.project.name), "covered by the touch tests");
});

test("looks up the selection, then a word typed in the dialog", async ({ page }) => {
  await ready(page);
  await page.keyboard.type("n ");
  const word = await editor(page).inputValue();
  await editor(page).selectText();
  await page.getByRole("button", { name: "编码反查" }).click();
  await expect(page.locator(".lookup-title")).toHaveText(`「${word}」的编码`);
  await expect(page.locator(".lookup-keys").first()).toHaveText("n");

  // The dialog's field types through the IME too.
  await page.keyboard.type("dk ");
  await page.keyboard.press("Enter");
  await expect(page.locator(".lookup-title")).not.toHaveText(`「${word}」的编码`);
  await expect(page.locator(".lookup-keys").first()).toBeVisible();
});

test("says when nothing is found", async ({ page }) => {
  await ready(page);
  await page.getByRole("button", { name: "编码反查" }).click();
  await page.locator("#lookup-input").fill("𠀀𠀀𠀀");
  await page.keyboard.press("Enter");
  await expect(page.locator(".lookup-title")).toHaveText("没有找到「𠀀𠀀𠀀」");
  await expect(page.locator(".lookup-message")).toHaveText("内置词库中没有这个词。用户自造词未启用，不在查询范围内。");
});
