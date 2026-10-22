import { describe, expect, test } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import {
  SITE_NAME,
  SITE_URL,
  DMG_URL,
  APPCAST_URL,
  CURRENT_VERSION,
  MACOS_REQUIREMENT,
  releaseAssetUrl,
} from "../../src/utils/site";
import { COMPARISON_APPS } from "../../src/utils/compare";

const ROOT = resolve(import.meta.dirname, "../..");

describe("site config", () => {
  test("version strings are consistent", () => {
    expect(CURRENT_VERSION).toMatch(/^v\d+\.\d+\.\d+$/);
    const pkg = JSON.parse(readFileSync(resolve(ROOT, "package.json"), "utf8"));
    expect(pkg.version.replace(/^v/, "")).toBe(
      CURRENT_VERSION.replace(/^v/, ""),
    );
  });

  test("release assets resolve on the site domain", () => {
    expect(releaseAssetUrl("v9.9.9")).toBe(
      `${SITE_URL}/releases/GazeKeeper.v9.9.9.dmg`,
    );
    expect(DMG_URL).toBe(`${SITE_URL}/releases/GazeKeeper.dmg`);
    expect(APPCAST_URL).toBe(`${SITE_URL}/appcast.xml`);
  });

  test("site name and macOS floor stay stable", () => {
    expect(SITE_NAME).toBe("GazeKeeper");
    expect(MACOS_REQUIREMENT).toMatch(/^macOS \d+$/);
  });
});

describe("no stale brand", () => {
  function walk(dir: string): string[] {
    return readdirSync(resolve(ROOT, dir), { withFileTypes: true }).flatMap(
      (d) =>
        d.isDirectory()
          ? walk(`${dir}/${d.name}`)
          : [`${dir}/${d.name}`],
    );
  }

  // The compare page and its data legitimately name LookAway as a
  // competitor; everywhere else the old brand must not appear.
  const allowed = new Set(["src/pages/compare.astro", "src/utils/compare.ts"]);

  test("LookAway does not appear in site source", () => {
    const offenders = walk("src")
      .filter((f) => !allowed.has(f))
      .filter((f) => /\.(astro|ts|css|md|tsx?)$/.test(f))
      .filter((f) => /lookaway/i.test(readFileSync(resolve(ROOT, f), "utf8")));
    expect(offenders).toEqual([]);
  });

  test("public assets carry no old brand", () => {
    const offenders = walk("public").filter((f) =>
      /lookaway/i.test(readFileSync(resolve(ROOT, f), "utf8")),
    );
    expect(offenders).toEqual([]);
  });
});

describe("comparison data", () => {
  test("every app has rows and a unique slug", () => {
    const slugs = COMPARISON_APPS.map((a) => a.slug);
    expect(new Set(slugs).size).toBe(slugs.length);
    for (const app of COMPARISON_APPS) {
      expect(app.rows.length).toBeGreaterThanOrEqual(4);
      expect(app.verdict.length).toBeGreaterThan(40);
    }
  });
});

describe("route coverage", () => {
  function pages(dir: string): string[] {
    const clean = dir.replace(/^\//, "");
    return readdirSync(resolve(ROOT, "src/pages", clean), {
      withFileTypes: true,
    }).flatMap((d) =>
      d.isDirectory() ? pages(`${clean}/${d.name}`) : [`${clean}/${d.name}`],
    );
  }

  const allPages = pages("").map((p) => p.replace(/^\//, ""));
  const routeSet = new Set(
    allPages.flatMap((p) => {
      if (p === "index.astro") return ["/", "/index.astro"];
      if (p.endsWith("/index.astro"))
        return ["/" + p.replace(/\/index\.astro$/, ""), p];
      if (p.includes("[..."))
        return ["/" + p.split("/[...")[0], "/" + p.replace(/\.astro$/, "")];
      const dyn = p.match(/^(.*)\/\[[^\]]+\]\.astro$/);
      if (dyn) return [`/${dyn[1]}/`, `/${p.replace(/\.astro$/, "")}`];
      return ["/" + p.replace(/\.astro$/, ""), p];
    }),
  );

  function routeExists(href: string): boolean {
    const clean = href.replace(/\/$/, "");
    if (clean === "") return routeSet.has("/");
    if (
      routeSet.has(clean) ||
      routeSet.has(clean + "/index.astro") ||
      routeSet.has(clean + ".astro")
    )
      return true;
    // /docs/introduction resolves via the docs/[slug].astro dynamic route
    const parent = clean.slice(0, clean.lastIndexOf("/"));
    for (const r of routeSet) {
      if (r.startsWith(parent + "/[") || r.startsWith(parent.slice(1) + "/["))
        return true;
    }
    return false;
  }

  test("footer links all resolve to real pages", () => {
    const footer = readFileSync(
      resolve(ROOT, "src/components/common/Footer.astro"),
      "utf8",
    );
    const hrefs = [...footer.matchAll(/href:\s*"([^"]+)"/g)].map((m) => m[1]);
    for (const href of hrefs) {
      expect(routeExists(href), `footer link ${href} has no page`).toBe(true);
    }
  });

  test("header links all resolve to real pages", () => {
    const header = readFileSync(
      resolve(ROOT, "src/components/common/Header.astro"),
      "utf8",
    );
    const hrefs = [...header.matchAll(/\{ href: "([^"]+)", label/g)].map(
      (m) => m[1],
    );
    const home = readFileSync(resolve(ROOT, "src/pages/index.astro"), "utf8");
    for (const href of hrefs) {
      const [path, hash] = href.split("#");
      expect(routeExists(path), `header link ${href} has no page`).toBe(true);
      if (hash) {
        expect(path, `header anchor ${href} must target the home page`).toBe("/");
        expect(home, `header anchor ${href} has no target`).toContain(`id="${hash}"`);
      }
    }
  });

  test("docs sidebar links resolve to real docs pages", () => {
    const docs = readFileSync(resolve(ROOT, "src/layouts/Docs.astro"), "utf8");
    const slugs = [...docs.matchAll(/slug: "([^"]+)"/g)].map((m) => m[1]);
    for (const slug of slugs) {
      expect(
        routeExists(`/docs/${slug}`),
        `docs link /docs/${slug} has no page`,
      ).toBe(true);
      // every sidebar slug must have a backing content file
      expect(() =>
        readFileSync(resolve(ROOT, `src/content/docs/${slug}.md`)),
      ).not.toThrow();
    }
  });
});
