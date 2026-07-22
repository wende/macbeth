import path from "path"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"
import treelocator from "@treelocator/vite"
import { inspectAttr } from "kimi-plugin-inspect-react"

// https://vite.dev/config/
export default defineConfig({
  base: process.env.VITE_BASE_PATH ?? "/macbeth/",
  plugins: [
    react({
      babel: {
        plugins: [["@locator/babel-jsx/dist", { env: "development" }]],
      },
    }),
    treelocator(),
    inspectAttr(),
  ],
  server: {
    port: 3000,
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
})
