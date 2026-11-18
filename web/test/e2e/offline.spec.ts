import { editor, expect, ready, test } from "./fixtures";

test("works offline once cached — features never opened included", async ({ page, context }, info) => {
  test.skip(info.project.name !== "chromium", "service worker checked once");
  await ready(page);
  await expect(page.locator(".chip-offline")).toBeVisible({ timeout: 20_000 });
  await page.evaluate(() => navigator.serviceWorker.ready);

  await context.setOffline(true);
  await page.reload();
  await expect(page.locator(".loading")).toHaveCount(0, { timeout: 20_000 });
  await page.keyboard.type("n.");
  await expect(editor(page)).toHaveValue("你。");

  await page.getByRole("button", { name: "用户自造词" }).click();
  await page.getByRole("radio", { name: "文本" }).check();
  await expect(page.locator(".cm-content")).toBeVisible();
  await context.setOffline(false);
});
