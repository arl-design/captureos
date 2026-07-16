export const APP_NAME = 'CaptureOS';
export const APP_TAGLINE = 'Minifigure Booth';
export const APP_VERSION = 'captureOS v2.0.0';

/** "1:42 PM" */
export function formatTime(iso: string | Date): string {
  const d = typeof iso === 'string' ? new Date(iso) : iso;
  return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

/** "May 18, 2025" */
export function formatDate(d: Date): string {
  return d.toLocaleDateString([], { month: 'long', day: 'numeric', year: 'numeric' });
}
