// Offline readiness, updates and installation. The service worker is
// registered after the page has settled, so it never competes with libjd's
// download; it then precaches every chunk in the background, so features the
// user never opened still work offline.

import { createSignal } from "solid-js";

const [offlineReady, setOfflineReady] = createSignal(false);
const [updateReady, setUpdateReady] = createSignal(false);
const [canInstall, setCanInstall] = createSignal(false);

export { canInstall, offlineReady, updateReady };

let updateSW: ((reload?: boolean) => Promise<void>) | null = null;

interface BeforeInstallPromptEvent extends Event {
  prompt(): Promise<void>;
  readonly userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

let deferredPrompt: BeforeInstallPromptEvent | null = null;
const supportsWebInstall = typeof (Navigator.prototype as { install?: unknown }).install === "function";

export function startPwa(): void {
  if (supportsWebInstall) setCanInstall(true);
  addEventListener("beforeinstallprompt", (e) => {
    e.preventDefault();
    deferredPrompt = e as BeforeInstallPromptEvent;
    setCanInstall(true);
  });
  addEventListener("appinstalled", () => {
    deferredPrompt = null;
    setCanInstall(false);
  });

  if (!("serviceWorker" in navigator) || import.meta.env.DEV) return;
  const register = () =>
    void import("virtual:pwa-register").then(({ registerSW }) => {
      updateSW = registerSW({
        immediate: true,
        onOfflineReady: () => setOfflineReady(true),
        onNeedRefresh: () => setUpdateReady(true),
        onRegisteredSW: (_url, registration) => {
          if (registration?.active) setOfflineReady(true);
          // Look for a new version now and then while the page stays open.
          if (registration) setInterval(() => void registration.update(), 60 * 60 * 1000);
        },
      });
    });
  if (document.readyState === "complete") requestIdleCallbackish(register);
  else addEventListener("load", () => requestIdleCallbackish(register), { once: true });
}

function requestIdleCallbackish(fn: () => void): void {
  if ("requestIdleCallback" in window) requestIdleCallback(fn, { timeout: 4000 });
  else setTimeout(fn, 1500);
}

export async function applyUpdate(): Promise<void> {
  await updateSW?.(true);
}

export async function install(): Promise<void> {
  try {
    const nav = navigator as Navigator & { install?: () => Promise<unknown> };
    if (supportsWebInstall && nav.install) {
      await nav.install();
      return;
    }
    const prompt = deferredPrompt;
    deferredPrompt = null;
    if (!prompt) return;
    await prompt.prompt();
    const { outcome } = await prompt.userChoice;
    if (outcome === "accepted" || !deferredPrompt) setCanInstall(false);
  } catch {
    // Cancelled: the entry stays for another try.
  }
}
