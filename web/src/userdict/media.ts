import { createSignal, onSettled } from "solid-js";

/** A media query as a signal. */
export function useMedia(query: string) {
  const list = matchMedia(query);
  const [matches, setMatches] = createSignal(list.matches);
  onSettled(() => {
    const on = () => setMatches(list.matches);
    list.addEventListener("change", on);
    return () => list.removeEventListener("change", on);
  });
  return matches;
}
