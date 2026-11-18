// An on/off switch: a real checkbox (role="switch"), styled.
import "./switch.css";

export function Switch(props: { checked: boolean; onChange: (on: boolean) => void; label: string; id?: string }) {
  return (
    <input
      id={props.id}
      type="checkbox"
      role="switch"
      class="switch"
      aria-label={props.label}
      checked={props.checked}
      onChange={(e) => props.onChange(e.currentTarget.checked)}
    />
  );
}
