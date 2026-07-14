import type { Photo, Settings } from './types';

const API = '/api/admin';
const TOKEN_KEY = 'captureos_admin_token';

export interface Diagnostics {
  camera: { ok: boolean; camera: string };
  photos: { pending: number; accepted: number; discarded: number };
  disk: { totalBytes: number; freeBytes: number } | null;
  database: { path: string; sizeBytes: number };
  uptimeSeconds: number;
  node: string;
  memoryRss: number;
}

export interface BackupEntry {
  filename: string;
  sizeBytes: number;
}

export class AuthError extends Error {}

export function getToken(): string | null {
  return sessionStorage.getItem(TOKEN_KEY);
}

export function clearToken(): void {
  sessionStorage.removeItem(TOKEN_KEY);
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API}${path}`, {
    ...init,
    headers: {
      ...(init?.headers ?? {}),
      Authorization: `Bearer ${getToken() ?? ''}`,
      ...(init?.body ? { 'Content-Type': 'application/json' } : {}),
    },
  });
  if (res.status === 401) {
    clearToken();
    throw new AuthError('session expired');
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((body as { error?: string }).error ?? `${path} failed (${res.status})`);
  }
  return body as T;
}

export const adminApi = {
  async login(pin: string): Promise<void> {
    const res = await fetch(`${API}/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pin }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      throw new Error((body as { error?: string }).error ?? 'login failed');
    }
    sessionStorage.setItem(TOKEN_KEY, (body as { token: string }).token);
  },

  diagnostics: () => request<Diagnostics>('/diagnostics'),
  photos: () => request<{ photos: Photo[] }>('/photos?limit=500'),
  deletePhoto: (id: number) =>
    request<{ ok: boolean }>(`/photos/${id}`, { method: 'DELETE' }),
  settings: () => request<Settings>('/settings'),
  saveSettings: (patch: Partial<Settings>) =>
    request<Settings>('/settings', { method: 'POST', body: JSON.stringify(patch) }),
  changePin: (pin: string) =>
    request<{ ok: boolean }>('/pin', { method: 'POST', body: JSON.stringify({ pin }) }),
  createBackup: () => request<{ filename: string }>('/backup', { method: 'POST' }),
  backups: () => request<{ backups: BackupEntry[] }>('/backups'),
  logs: () => request<{ backend: string[]; camera: string[] }>('/logs?lines=300'),

  async downloadBackup(filename: string): Promise<void> {
    const res = await fetch(`${API}/backups/${encodeURIComponent(filename)}`, {
      headers: { Authorization: `Bearer ${getToken() ?? ''}` },
    });
    if (!res.ok) throw new Error('download failed');
    const url = URL.createObjectURL(await res.blob());
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  },
};
