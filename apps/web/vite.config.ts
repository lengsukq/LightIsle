import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

export default defineConfig({
  plugins: [vue()],
  base: "/",
  server: { proxy: { "/api": { target: "http://127.0.0.1:5251", changeOrigin: false } } },
  build: { outDir: "dist", assetsDir: "assets", sourcemap: false },
});

