import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The app always calls /api/* on its own origin — in the cluster the ingress
// routes that prefix to the backend, in the container nginx proxies it, and
// here the dev server proxies it. One URL shape, three environments.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: process.env.BACKEND_URL || 'http://localhost:8001',
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: false,
  },
})
