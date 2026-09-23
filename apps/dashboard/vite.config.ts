import react from '@vitejs/plugin-react';
import { resolve } from 'node:path';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      // The dashboard consumes the contract from source rather than from the built package:
      // Vite compiles the TypeScript directly, so a contract change is visible here without
      // a build step, and the shared schemas stay the single source of truth (ADR-010).
      '@pharmaet/contracts': resolve(__dirname, '../../packages/contracts/src/index.ts'),
    },
  },
  server: {
    port: 5173,
    proxy: {
      // The dashboard is served as a static bundle alongside the same NestJS API in
      // production (docs/03 §7), so development proxies rather than pointing at a second
      // origin — same-origin in both places, and no CORS surprise at deploy time.
      '/api': { target: 'http://localhost:3000', changeOrigin: true },
    },
  },
  // GitHub Pages serves a project site under /<repo>/, so assets need that prefix. Local
  // dev and any root-served host set BASE_PATH to '/' (the default).
  base: process.env.BASE_PATH ?? '/',
  build: { outDir: 'dist', sourcemap: true },
});
