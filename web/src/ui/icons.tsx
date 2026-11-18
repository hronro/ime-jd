// A small stroke icon set, drawn for this client: 24-unit grid, round caps,
// currentColor. Decorative — every button that uses one carries its own label.
import type { JSX } from "@solidjs/web";

function Svg(props: { children: JSX.Element; class?: string }) {
  return (
    <svg
      class={props.class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      {props.children}
    </svg>
  );
}

export const CopyIcon = () => (
  <Svg>
    <rect x="8.5" y="8.5" width="11" height="11" rx="2.5" />
    <path d="M15.5 8.5V6.5A2 2 0 0 0 13.5 4.5H6.5A2 2 0 0 0 4.5 6.5V13.5A2 2 0 0 0 6.5 15.5H8.5" />
  </Svg>
);

export const CheckIcon = () => (
  <Svg>
    <path d="M5 12.5l4.5 4.5L19 7.5" />
  </Svg>
);

export const EraseIcon = () => (
  <Svg>
    <path d="M14.2 4.8l5 5a1.5 1.5 0 0 1 0 2.1L12 19.1H7.6l-2.8-2.8a1.5 1.5 0 0 1 0-2.1l7.3-9.4a1.5 1.5 0 0 1 2.1 0z" />
    <path d="M9.3 9.6l5.1 5.1" />
    <path d="M12 19.1h7.5" />
  </Svg>
);

export const LookupIcon = () => (
  <Svg>
    <circle cx="10.5" cy="10.5" r="6" />
    <path d="M15 15l4.5 4.5" />
    <path d="M8.2 10.5h4.6M10.5 8.2v4.6" />
  </Svg>
);

export const BookIcon = () => (
  <Svg>
    <path d="M12 6.5C10.4 5.2 8.2 4.6 5 4.6v13.2c3.2 0 5.4.6 7 1.9 1.6-1.3 3.8-1.9 7-1.9V4.6c-3.2 0-5.4.6-7 1.9z" />
    <path d="M12 6.5v13.2" />
  </Svg>
);

export const MoreIcon = () => (
  <Svg>
    <circle cx="6" cy="12" r="1.2" fill="currentColor" stroke="none" />
    <circle cx="12" cy="12" r="1.2" fill="currentColor" stroke="none" />
    <circle cx="18" cy="12" r="1.2" fill="currentColor" stroke="none" />
  </Svg>
);

export const SlidersIcon = () => (
  <Svg>
    <path d="M4.5 7h9M17.5 7h2M4.5 17h3M11.5 17h8" />
    <circle cx="15.5" cy="7" r="2" />
    <circle cx="9.5" cy="17" r="2" />
  </Svg>
);

export const HelpIcon = () => (
  <Svg>
    <circle cx="12" cy="12" r="8" />
    <path d="M9.7 9.6a2.4 2.4 0 0 1 4.6.9c0 1.7-2.3 2.1-2.3 3.6" />
    <circle cx="12" cy="16.9" r="0.6" fill="currentColor" />
  </Svg>
);

export const InstallIcon = () => (
  <Svg>
    <path d="M12 4.5v10M8 10.5l4 4 4-4" />
    <path d="M5 15.5v2a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-2" />
  </Svg>
);

export const CloseIcon = () => (
  <Svg>
    <path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />
  </Svg>
);

export const PlusIcon = () => (
  <Svg>
    <path d="M12 5.5v13M5.5 12h13" />
  </Svg>
);

export const MinusIcon = () => (
  <Svg>
    <path d="M5.5 12h13" />
  </Svg>
);

export const ImportIcon = () => (
  <Svg>
    <path d="M14 4.5H7.5a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V9z" />
    <path d="M14 4.5V9h4.5" />
    <path d="M12 11v5.5M9.5 14l2.5 2.5 2.5-2.5" />
  </Svg>
);

export const ExportIcon = () => (
  <Svg>
    <path d="M14 4.5H7.5a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V9z" />
    <path d="M14 4.5V9h4.5" />
    <path d="M12 16.5V11M9.5 13.5L12 11l2.5 2.5" />
  </Svg>
);

export const LinkIcon = () => (
  <Svg>
    <path d="M10 14a3.5 3.5 0 0 0 5 0l3-3a3.5 3.5 0 0 0-5-5l-1 1" />
    <path d="M14 10a3.5 3.5 0 0 0-5 0l-3 3a3.5 3.5 0 0 0 5 5l1-1" />
  </Svg>
);

export const TableIcon = () => (
  <Svg>
    <rect x="4.5" y="5" width="15" height="14" rx="2" />
    <path d="M4.5 10h15M10 10v9" />
  </Svg>
);

export const TextIcon = () => (
  <Svg>
    <path d="M5 6.5h14M5 10.5h14M5 14.5h9M5 18.5h6" />
  </Svg>
);

export const ChevronLeft = () => (
  <Svg>
    <path d="M14.5 6.5L9 12l5.5 5.5" />
  </Svg>
);

export const ChevronRight = () => (
  <Svg>
    <path d="M9.5 6.5L15 12l-5.5 5.5" />
  </Svg>
);

export const ChevronDown = () => (
  <Svg>
    <path d="M6.5 9.5L12 15l5.5-5.5" />
  </Svg>
);

export const ChevronUp = () => (
  <Svg>
    <path d="M6.5 14.5L12 9l5.5 5.5" />
  </Svg>
);

export const RefreshIcon = () => (
  <Svg>
    <path d="M18.5 9A7 7 0 0 0 6 7.5L4.5 9M5.5 15A7 7 0 0 0 18 16.5l1.5-1.5" />
    <path d="M4.5 5v4h4M19.5 19v-4h-4" />
  </Svg>
);

export const TabIcon = () => (
  <Svg>
    <path d="M4.5 12h12M12.5 8l4 4-4 4M19.5 7v10" />
  </Svg>
);

export const SearchIcon = () => (
  <Svg>
    <circle cx="10.5" cy="10.5" r="6" />
    <path d="M15 15l4.5 4.5" />
  </Svg>
);

export const WarnIcon = () => (
  <Svg>
    <path d="M12 4.5l8.5 15h-17z" />
    <path d="M12 10v4.5" />
    <circle cx="12" cy="17" r="0.6" fill="currentColor" />
  </Svg>
);

export const OfflineIcon = () => (
  <Svg>
    <path d="M7 17.5h10a4 4 0 0 0 .6-8A6 6 0 0 0 6.2 10 3.8 3.8 0 0 0 7 17.5z" />
    <path d="M9.5 13.5l2 2 3.5-3.5" />
  </Svg>
);
