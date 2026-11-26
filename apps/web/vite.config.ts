import { defineConfig, loadEnv } from "vite";
import vue from "@vitejs/plugin-vue";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, ".", "LIGHTISLE_");
  const coreTarget = env.LIGHTISLE_CORE_URL || "http://127.0.0.1:16666";
  return {
    plugins: [vue()],
    base: "/",
    server: {
      proxy: {
        "/api": { target: coreTarget, changeOrigin: false },
        "/apps": { target: coreTarget, changeOrigin: false },
        "/dav": { target: coreTarget, changeOrigin: false },
        "/s/": { target: coreTarget, changeOrigin: false },
      },
    },
    build: { outDir: "dist", assetsDir: "assets", sourcemap: false },
  };
});

