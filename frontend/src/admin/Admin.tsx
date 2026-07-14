import { useCallback, useEffect, useState } from 'react';

import { CameraIcon } from '../components/Icons';
import {
  adminApi,
  AuthError,
  clearToken,
  getToken,
  type BackupEntry,
  type Diagnostics,
} from '../lib/admin';
import { APP_NAME, APP_VERSION, formatTime } from '../lib/meta';
import type { Photo, Settings } from '../lib/types';

type Tab = 'settings' | 'diagnostics' | 'photos' | 'backups' | 'logs';

// LAN administration panel (admin console). PIN login -> tabbed console.
export function Admin() {
  const [authed, setAuthed] = useState(() => getToken() !== null);
  const [tab, setTab] = useState<Tab>('settings');

  const onExpired = useCallback((err: unknown) => {
    if (err instanceof AuthError) setAuthed(false);
  }, []);

  if (!authed) return <Login onSuccess={() => setAuthed(true)} />;

  return (
    <div className="admin">
      <header className="admin-header">
        <div className="wall-logo"><CameraIcon size="1.4em" /></div>
        <h1>
          {APP_NAME} <span>Admin</span>
        </h1>
        <button
          className="admin-btn ghost"
          onClick={() => {
            clearToken();
            setAuthed(false);
          }}
        >
          Log out
        </button>
      </header>

      <nav className="admin-tabs">
        {(['settings', 'diagnostics', 'photos', 'backups', 'logs'] as Tab[]).map((t) => (
          <button key={t} className={tab === t ? 'active' : ''} onClick={() => setTab(t)}>
            {t[0].toUpperCase() + t.slice(1)}
          </button>
        ))}
      </nav>

      <main className="admin-body">
        {tab === 'settings' && <SettingsTab onAuthError={onExpired} />}
        {tab === 'diagnostics' && <DiagnosticsTab onAuthError={onExpired} />}
        {tab === 'photos' && <PhotosTab onAuthError={onExpired} />}
        {tab === 'backups' && <BackupsTab onAuthError={onExpired} />}
        {tab === 'logs' && <LogsTab onAuthError={onExpired} />}
      </main>

      <footer className="admin-footer">{APP_VERSION}</footer>
    </div>
  );
}

function Login({ onSuccess }: { onSuccess: () => void }) {
  const [pin, setPin] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    adminApi
      .login(pin)
      .then(onSuccess)
      .catch((err: Error) => setError(err.message))
      .finally(() => setBusy(false));
  };

  return (
    <div className="admin login-screen">
      <form className="login-card" onSubmit={submit}>
        <div className="wall-logo"><CameraIcon size="1.6em" /></div>
        <h1>{APP_NAME} Admin</h1>
        <input
          type="password"
          inputMode="numeric"
          autoComplete="off"
          placeholder="PIN"
          value={pin}
          onChange={(e) => setPin(e.target.value)}
          autoFocus
        />
        {error && <div className="admin-error">{error}</div>}
        <button className="admin-btn" disabled={busy || pin.length === 0}>
          {busy ? '…' : 'Unlock'}
        </button>
      </form>
    </div>
  );
}

interface TabProps {
  onAuthError: (err: unknown) => void;
}

function SettingsTab({ onAuthError }: TabProps) {
  const [form, setForm] = useState<Settings | null>(null);
  const [newPin, setNewPin] = useState('');
  const [note, setNote] = useState<string | null>(null);

  useEffect(() => {
    adminApi.settings().then(setForm).catch(onAuthError);
  }, [onAuthError]);

  if (!form) return <p className="muted">Loading…</p>;

  const num = (key: keyof Settings) => ({
    value: String(form[key]),
    onChange: (e: React.ChangeEvent<HTMLInputElement>) =>
      setForm({ ...form, [key]: Number(e.target.value) }),
  });

  const save = () => {
    setNote(null);
    adminApi
      .saveSettings(form)
      .then((s) => {
        setForm(s);
        setNote('Settings saved');
      })
      .catch((err) => {
        onAuthError(err);
        setNote(String(err.message ?? err));
      });
  };

  const savePin = () => {
    setNote(null);
    adminApi
      .changePin(newPin)
      .then(() => {
        setNewPin('');
        setNote('PIN changed');
      })
      .catch((err) => {
        onAuthError(err);
        setNote(String(err.message ?? err));
      });
  };

  return (
    <div className="admin-panel">
      <div className="form-grid">
        <label>Gallery title
          <input
            value={form.gallery_title}
            onChange={(e) => setForm({ ...form, gallery_title: e.target.value })}
          />
        </label>
        <label>Gallery mode
          <select
            value={form.gallery_mode}
            onChange={(e) =>
              setForm({ ...form, gallery_mode: e.target.value as Settings['gallery_mode'] })}
          >
            <option value="grid">Grid</option>
            <option value="slideshow">Slideshow</option>
          </select>
        </label>
        <label>Countdown (s)<input type="number" min={1} max={10} {...num('countdown_seconds')} /></label>
        <label>Slideshow interval (s)<input type="number" min={2} max={60} {...num('slideshow_interval_seconds')} /></label>
        <label>JPEG quality<input type="number" min={50} max={100} {...num('jpeg_quality')} /></label>
        <label>Max width (px)<input type="number" min={640} max={4056} {...num('max_width')} /></label>
      </div>
      <button className="admin-btn" onClick={save}>Save settings</button>

      <h3>Change admin PIN</h3>
      <div className="pin-row">
        <input
          type="password"
          inputMode="numeric"
          placeholder="New PIN (4-8 digits)"
          value={newPin}
          onChange={(e) => setNewPin(e.target.value)}
        />
        <button className="admin-btn ghost" onClick={savePin} disabled={newPin.length < 4}>
          Change PIN
        </button>
      </div>
      {note && <div className="admin-note">{note}</div>}
    </div>
  );
}

function DiagnosticsTab({ onAuthError }: TabProps) {
  const [diag, setDiag] = useState<Diagnostics | null>(null);

  const refresh = useCallback(() => {
    adminApi.diagnostics().then(setDiag).catch(onAuthError);
  }, [onAuthError]);

  useEffect(refresh, [refresh]);

  if (!diag) return <p className="muted">Loading…</p>;

  const gb = (n: number) => (n / 1024 ** 3).toFixed(1) + ' GB';
  const diskUsed = diag.disk ? diag.disk.totalBytes - diag.disk.freeBytes : 0;

  return (
    <div className="admin-panel">
      <div className="diag-grid">
        <div className="diag-card">
          <h4>Camera</h4>
          <p>
            <span className={`dot ${diag.camera.ok ? 'good' : 'bad'}`} />
            {diag.camera.ok ? 'Connected' : 'Disconnected'} ({diag.camera.camera})
          </p>
        </div>
        <div className="diag-card">
          <h4>Photos</h4>
          <p>{diag.photos.accepted} accepted · {diag.photos.pending} pending · {diag.photos.discarded} discarded</p>
        </div>
        <div className="diag-card">
          <h4>Storage</h4>
          {diag.disk ? (
            <>
              <p>{gb(diag.disk.freeBytes)} free of {gb(diag.disk.totalBytes)}</p>
              <div className="meter">
                <span style={{ width: `${(diskUsed / diag.disk.totalBytes) * 100}%` }} />
              </div>
            </>
          ) : (
            <p className="muted">unavailable</p>
          )}
        </div>
        <div className="diag-card">
          <h4>Database</h4>
          <p>{(diag.database.sizeBytes / 1024).toFixed(0)} KB</p>
        </div>
        <div className="diag-card">
          <h4>Backend</h4>
          <p>up {Math.floor(diag.uptimeSeconds / 60)} min · {diag.node} · {(diag.memoryRss / 1024 ** 2).toFixed(0)} MB RSS</p>
        </div>
      </div>
      <button className="admin-btn ghost" onClick={refresh}>Refresh</button>
    </div>
  );
}

function PhotosTab({ onAuthError }: TabProps) {
  const [photos, setPhotos] = useState<Photo[]>([]);

  useEffect(() => {
    adminApi.photos().then((r) => setPhotos(r.photos)).catch(onAuthError);
  }, [onAuthError]);

  const remove = (photo: Photo) => {
    if (!window.confirm('Delete this photo permanently?')) return;
    adminApi
      .deletePhoto(photo.id)
      .then(() => setPhotos((prev) => prev.filter((p) => p.id !== photo.id)))
      .catch(onAuthError);
  };

  const visible = photos.filter((p) => p.status !== 'discarded');

  if (visible.length === 0) return <p className="muted">No photos.</p>;

  return (
    <div className="admin-panel">
      <div className="admin-photos">
        {visible.map((p) => (
          <figure key={p.id} className="card">
            <img src={p.thumbUrl} alt={`Capture ${p.photoId}`} loading="lazy" />
            <figcaption>
              <span>{formatTime(p.capturedAt)} · {p.status}</span>
              <button onClick={() => remove(p)} aria-label={`Delete photo ${p.id}`}>✕</button>
            </figcaption>
          </figure>
        ))}
      </div>
    </div>
  );
}

function BackupsTab({ onAuthError }: TabProps) {
  const [backups, setBackups] = useState<BackupEntry[]>([]);
  const [note, setNote] = useState<string | null>(null);

  const refresh = useCallback(() => {
    adminApi.backups().then((r) => setBackups(r.backups)).catch(onAuthError);
  }, [onAuthError]);

  useEffect(refresh, [refresh]);

  const create = () => {
    setNote(null);
    adminApi
      .createBackup()
      .then((r) => {
        setNote(`Backup created: ${r.filename}`);
        refresh();
      })
      .catch((err) => {
        onAuthError(err);
        setNote(String(err.message ?? err));
      });
  };

  return (
    <div className="admin-panel">
      <button className="admin-btn" onClick={create}>Create backup now</button>
      {note && <div className="admin-note">{note}</div>}
      <table className="admin-table">
        <thead><tr><th>File</th><th>Size</th><th /></tr></thead>
        <tbody>
          {backups.map((b) => (
            <tr key={b.filename}>
              <td>{b.filename}</td>
              <td>{(b.sizeBytes / 1024).toFixed(0)} KB</td>
              <td>
                <button
                  className="admin-btn ghost"
                  onClick={() => adminApi.downloadBackup(b.filename).catch(onAuthError)}
                >
                  Download
                </button>
              </td>
            </tr>
          ))}
          {backups.length === 0 && (
            <tr><td colSpan={3} className="muted">No backups yet.</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

function LogsTab({ onAuthError }: TabProps) {
  const [logs, setLogs] = useState<{ backend: string[]; camera: string[] } | null>(null);

  const refresh = useCallback(() => {
    adminApi.logs().then(setLogs).catch(onAuthError);
  }, [onAuthError]);

  useEffect(refresh, [refresh]);

  if (!logs) return <p className="muted">Loading…</p>;

  return (
    <div className="admin-panel">
      <button className="admin-btn ghost" onClick={refresh}>Refresh</button>
      <h3>Backend</h3>
      <pre className="log-view">{logs.backend.join('\n') || '(empty)'}</pre>
      <h3>Camera service</h3>
      <pre className="log-view">{logs.camera.join('\n') || '(empty)'}</pre>
    </div>
  );
}
