// @ts-check
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

export default defineConfig({
  site: "https://gazekeeper.hridya.tech",
  trailingSlash: "ignore",
  integrations: [sitemap()],
  markdown: {
    shikiConfig: {
      themes: {
        light: "github-dark-default",
        dark: "github-dark-default",
      },
    },
  },
});
