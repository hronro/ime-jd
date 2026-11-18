// libjd starts downloading first (engine/load.ts runs at import); the page
// renders while it compiles, and the IME comes up the moment it is ready.
import { jdModule } from "./engine/load";
import "./styles/tokens.css";
import "./styles/base.css";
import { render } from "@solidjs/web";
import { App } from "./app/App";
import { setBootError, setReady } from "./app/boot-state";
import { startHints } from "./app/hints";
import { startPwa } from "./app/pwa-state";
import { dict } from "./dict/service";
import { ime } from "./ime/controller";
import { applyFontSize, fontSize, followOtherTabs } from "./storage/settings";

applyFontSize(fontSize());
followOtherTabs();

render(() => <App />, document.getElementById("root")!);

async function boot(): Promise<void> {
  try {
    const engine = await dict.boot(await jdModule);
    ime.start(engine);
    startHints();
    setReady(true);
  } catch (e) {
    console.error(e);
    setBootError(String(e));
  }
}

void boot();
startPwa();
