import { defineConfig } from "vite";
import react from "@vitejs/plugin-react-swc";
import path from "path";
import fs from "fs";

// Read version from mix.exs (single source of truth)
function getAppVersion(): string {
  try {
    const mixContent = fs.readFileSync(path.resolve(__dirname, '../mix.exs'), 'utf-8');
    const match = mixContent.match(/version:\s*"([^"]+)"/);
    return match ? match[1] : '0.0.0';
  } catch {
    return '0.0.0';
  }
}

// https://vitejs.dev/config/
export default defineConfig(({ mode }) => ({
  server: {
    host: "::",
    port: 8080,
    proxy: {
      '/api': 'http://localhost:4000',
      '/terminal': {
        target: 'http://localhost:7681',
        ws: true,
        rewrite: (path) => path.replace(/^\/terminal/, ''),
      },
    },
  },
  build: {
    outDir: path.resolve(__dirname, '../priv/static/spa'),
    emptyOutDir: true,
  },
  define: {
    __APP_VERSION__: JSON.stringify(getAppVersion()),
  },
  plugins: [react()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
}));
