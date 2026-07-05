import { defineConfig } from 'vite'

export default defineConfig({
  server: {
    port: 5173,
    open: false,   // run.py opens the browser
  },
  // pixi-live2d-display uses dynamic requires; keep it external-safe
  optimizeDeps: {
    include: ['pixi.js', 'pixi-live2d-display/cubism4'],
  },
})
