import { editor, expect, ready, softType, test } from "./fixtures";

test.beforeEach(({}, info) => {
  // Chromium and WebKit insertText go through the input-method path: a cancelable
  // beforeinput per character, as Gboard sends (verified on Android).
  test.skip(info.project.name !== "pixel" && info.project.name !== "iphone", "touch keyboard path");
});

test("a touch keyboard composes into the docked bar", async ({ page }) => {
  await ready(page);
  await editor(page).tap();
  await softType(page, "a");
  const bar = page.locator(".imebar");
  await expect(bar.locator(".imebar-code")).toHaveText("a");
  await expect(bar.locator(".imebar-cell").first()).toBeVisible();
  // Expand to the grid, pick the second.
  await bar.locator(".imebar-expand").tap();
  const second = page.locator(".imegrid-cell").nth(1);
  const word = (await second.textContent())!.replace(/〔.*〕/, "");
  await second.tap();
  await expect(editor(page)).toHaveValue(word);
  // Digits are text; punctuation converts.
  await softType(page, "n1n.");
  await expect(editor(page)).toHaveValue(`${word}你1你。`);
  await expect(editor(page)).toBeFocused();
});

test("the phrase sheet types through the bar inside the dialog", async ({ page }) => {
  await ready(page);
  await page.getByRole("button", { name: "用户自造词" }).tap();
  await page.getByRole("button", { name: "添加", exact: true }).tap();
  const sheet = page.locator(".ud-sheet");
  await expect(sheet).toBeVisible();
  await sheet.locator("input").first().tap();
  await softType(page, "ni");
  await page.locator("dialog .imebar-cell").first().tap();
  await sheet.locator(".ud-sheet-keys").tap();
  await softType(page, "zzzzzz");
  await expect(sheet.locator(".ud-sheet-keys")).toHaveValue("zzzzzz");
  await page.getByRole("button", { name: "保存" }).tap();
  await expect(page.locator(".ud-card")).toHaveCount(1);
  await expect(page.locator(".ud-card-meta code")).toHaveText("zzzzzz");
});

test("an on-screen keyboard that sends real key events (iOS Safari) still gets the bar", async ({ page }) => {
  // iOS Safari's keyboard sends keydown "n"/KeyN/78 like a hardware one
  // (verified in the simulator); what gives it away is the visual viewport,
  // which the keyboard shrinks while the layout viewport stays put.
  await page.addInitScript(() => {
    Object.defineProperty(window.visualViewport!, "height", { get: () => innerHeight - 300 });
  });
  await ready(page);
  await editor(page).tap();
  await page.keyboard.type("nk");
  await expect(page.locator(".imebar-code")).toHaveText("nk");
  await expect(page.locator(".cand-popup")).toHaveCount(0);
  // Its shift key sends ShiftLeft too: no 中/英 switch from it.
  await page.keyboard.press("Shift");
  await expect(page.locator(".mode")).toHaveText("中");
  // Digits are text, not candidate numbers.
  const first = (await page.locator(".imebar-cell").first().textContent())!.replace(/\s*〔.*〕/, "");
  await page.keyboard.type("1");
  await expect(editor(page)).toHaveValue(`${first}1`);
});
