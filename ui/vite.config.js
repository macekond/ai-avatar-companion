import { defineConfig } from 'vite'

export default defineConfig({
  server: {
    port: 5173,
    open: false,   // run.py opens the browser
  },
})
