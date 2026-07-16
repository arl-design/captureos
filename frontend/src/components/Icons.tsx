// Inline SVG icons (offline-first: no icon fonts or CDNs).

interface IconProps {
  size?: number | string;
  className?: string;
}

function svgProps({ size = '1em', className }: IconProps) {
  return {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'currentColor',
    className,
    'aria-hidden': true as const,
  };
}

export function ExpandIcon(props: IconProps) {
  return (
    <svg {...svgProps(props)}>
      <path d="M5 5h4V3H3v6h2V5Zm10 0V3h-6v2h4Zm4 10h-2v4h-4v2h6v-6ZM5 15H3v6h6v-2H5v-4Z" />
    </svg>
  );
}

export function CameraIcon(props: IconProps) {
  return (
    <svg {...svgProps(props)}>
      <path d="M9.4 4a2 2 0 0 0-1.6.8L6.7 6.3H5a3 3 0 0 0-3 3V17a3 3 0 0 0 3 3h14a3 3 0 0 0 3-3V9.3a3 3 0 0 0-3-3h-1.7l-1.1-1.5a2 2 0 0 0-1.6-.8H9.4Z" />
      <circle cx="12" cy="13" r="3.4" fill="var(--icon-contrast, #5cddad)" />
      <circle cx="12" cy="13" r="1.9" />
    </svg>
  );
}

export function GearIcon(props: IconProps) {
  return (
    <svg {...svgProps(props)}>
      <path d="M12 8.4A3.6 3.6 0 1 0 12 15.6 3.6 3.6 0 0 0 12 8.4Zm9 5.1a7.6 7.6 0 0 0 0-3l-2.2-.5a7 7 0 0 0-.7-1.6l1.2-1.9a9.6 9.6 0 0 0-2.1-2.1l-1.9 1.2a7 7 0 0 0-1.6-.7L13.5 3a7.6 7.6 0 0 0-3 0l-.5 2.2a7 7 0 0 0-1.6.7L6.5 4.4a9.6 9.6 0 0 0-2.1 2.1l1.2 1.9a7 7 0 0 0-.7 1.6L3 10.5a7.6 7.6 0 0 0 0 3l2.2.5a7 7 0 0 0 .7 1.6l-1.2 1.9a9.6 9.6 0 0 0 2.1 2.1l1.9-1.2a7 7 0 0 0 1.6.7l.5 2.2a7.6 7.6 0 0 0 3 0l.5-2.2a7 7 0 0 0 1.6-.7l1.9 1.2a9.6 9.6 0 0 0 2.1-2.1l-1.2-1.9a7 7 0 0 0 .7-1.6l2.2-.5Z" />
    </svg>
  );
}

export function HomeIcon(props: IconProps) {
  return (
    <svg {...svgProps(props)}>
      <path d="M12 3 2.8 10.8h2.4V20a1 1 0 0 0 1 1H10v-5.4h4V21h3.8a1 1 0 0 0 1-1v-9.2h2.4L12 3Z" />
    </svg>
  );
}

export function PhotosIcon(props: IconProps) {
  return (
    <svg {...svgProps(props)}>
      <path d="M4 4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2H4Zm0 13 4.5-5.5 3 3.6L14 12l6 7H4v-2Z" />
      <circle cx="9" cy="9" r="1.8" />
    </svg>
  );
}

export function ClockIcon(props: IconProps) {
  return (
    <svg {...svgProps(props)}>
      <path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm0 2a8 8 0 1 1 0 16 8 8 0 0 1 0-16Zm-1 3v6l4.6 2.7 1-1.7-3.6-2.1V7h-2Z" />
    </svg>
  );
}

export function WifiIcon(props: IconProps) {
  return (
    <svg {...svgProps(props)}>
      <path d="M12 20.5a1.8 1.8 0 1 0 0-3.6 1.8 1.8 0 0 0 0 3.6ZM12 13c1.9 0 3.7.7 5 2l-1.8 1.8a4.6 4.6 0 0 0-6.4 0L7 15c1.3-1.3 3.1-2 5-2Zm0-4.5c3.2 0 6.1 1.3 8.2 3.4l-1.8 1.8A9.1 9.1 0 0 0 12 11a9.1 9.1 0 0 0-6.4 2.6L3.8 11.9A11.5 11.5 0 0 1 12 8.5Zm0-4.5c4.4 0 8.4 1.8 11.3 4.7l-1.8 1.8A13.5 13.5 0 0 0 12 6.5c-3.7 0-7 1.5-9.5 3.9L.7 8.7A15.9 15.9 0 0 1 12 4Z" />
    </svg>
  );
}
