/// <reference types="vite/client" />

interface ImportMetaEnv {
  /**
   * Absolute base URL of the API, baked in at build time for a deployed bundle (e.g.
   * `https://pharmaet-staging.fly.dev/api`). Unset in development, where the Vite proxy
   * serves `/api` same-origin.
   */
  readonly VITE_API_BASE_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
