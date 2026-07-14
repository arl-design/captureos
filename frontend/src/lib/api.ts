import type { GalleryResponse, Health, Photo, Settings } from './types';

const API = '/api';

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API}${path}`, init);
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(
      (body as { error?: string }).error ?? `${path} failed (${res.status})`,
    );
  }
  return res.json() as Promise<T>;
}

function post<T>(path: string, body?: unknown): Promise<T> {
  return request<T>(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

export const api = {
  previewUrl: `${API}/preview`,
  health: () => request<Health>('/health'),
  gallery: (limit = 200) => request<GalleryResponse>(`/gallery?limit=${limit}`),
  latest: () => request<Photo>('/latest'),
  settings: () => request<Settings>('/settings'),
  capture: () => post<Photo>('/capture'),
  accept: (id: number) => post<Photo>('/accept', { id }),
  retake: (id: number) => post<{ ok: boolean }>('/retake', { id }),
  focus: (x: number, y: number) =>
    post<{ ok: boolean; window: number[] | null; af_supported: boolean | null }>(
      '/focus',
      { x, y },
    ),
  focusReset: () =>
    post<{ ok: boolean; window: null }>('/focus', { reset: true }),
};

/**
 * Subscribe to backend server-sent events over a single EventSource.
 * Pass a map of event name -> handler; returns an unsubscribe fn.
 */
export function subscribe(
  handlers: Record<string, (data: unknown) => void>,
): () => void {
  const source = new EventSource(`${API}/events`);
  for (const [event, handler] of Object.entries(handlers)) {
    source.addEventListener(event, (e) => {
      try {
        handler(JSON.parse((e as MessageEvent).data));
      } catch {
        // malformed event — ignore
      }
    });
  }
  return () => source.close();
}
