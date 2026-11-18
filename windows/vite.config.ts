import { defineConfig } from "vite";
import { resolve } from "node:path";

// Two pages: the panel (index.html) and the see-through drawing layer (overlay.html).
export default defineConfig({
  clearScreen: false,
  // The ringtone clips live in ../Ringtones (shared with the Mac app).
  server: { port: 5173, strictPort: true, fs: { allow: [".."] } },
  build: {
    target: "es2022",
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        overlay: resolve(__dirname, "overlay.html"),
      },
    },
  },
});
