import { createSignal } from "solid-js";

const [ready, setReady] = createSignal(false);
const [bootError, setBootError] = createSignal<string | null>(null);

export { bootError, ready, setBootError, setReady };
