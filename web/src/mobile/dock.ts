// Keep an element on the bottom edge of the *visual* viewport — just above a
// touch keyboard. Android Chrome resizes the layout viewport for the keyboard
// (interactive-widget=resizes-content), but the phase-0 probe showed the
// visual viewport ending ~23px above it there, and iOS Safari never resizes
// the layout viewport at all; the visual viewport is right on both.

export function dock(el: HTMLElement, height: number): () => void {
  const vv = window.visualViewport;
  const place = () => {
    const width = vv?.width ?? innerWidth;
    const bottom = vv ? vv.offsetTop + vv.height : innerHeight;
    const left = vv?.offsetLeft ?? 0;
    el.style.inlineSize = `${width}px`;
    el.style.translate = `${Math.round(left)}px ${Math.round(bottom - height)}px`;
  };
  place();
  vv?.addEventListener("resize", place);
  vv?.addEventListener("scroll", place);
  addEventListener("resize", place);
  return () => {
    vv?.removeEventListener("resize", place);
    vv?.removeEventListener("scroll", place);
    removeEventListener("resize", place);
  };
}
