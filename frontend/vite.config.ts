import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// In production nginx handles these routes; this proxy mirrors that
// layout for `npm run dev`.
const backend = 'http://127.0.0.1:3000';

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': { target: backend, rewrite: (p) => p.replace(/^\/api/, '') },
      '/photos': backend,
      '/thumbnails': backend,
    },
  },
});
