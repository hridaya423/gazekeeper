import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const dist = join(root, "..", "dist");

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (p.endsWith(".html")) out.push(p);
  }
  return out;
}

const files = walk(dist);

// Collect routable page paths from generated files
const pages = new Set();
for (const f of files) {
  const rel = f.slice(dist.length + 1).replace(/\\/g, "/");
  if (rel.endsWith("/index.html")) {
    pages.add("/" + rel.slice(0, -"index.html".length));
  } else if (rel.endsWith(".html")) {
    pages.add("/" + rel.slice(0, -".html".length));
  }
}
pages.add("/"); // dist/index.html normalizes to "/"

// Non-page assets that internal links may point at
const assets = new Set();
function walkAll(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walkAll(p);
    else assets.add("/" + p.slice(dist.length + 1).replace(/\\/g, "/"));
  }
}
walkAll(dist);

let dead = 0;
const linkRe = /(?:href|src)="([^"]+)"/g;

for (const f of files) {
  const html = readFileSync(f, "utf8");
  for (const m of html.matchAll(linkRe)) {
    const url = m[1];
    if (!url.startsWith("/") || url.startsWith("//")) continue; // external or protocol-relative
    const clean = url.split("#")[0].split("?")[0];
    if (clean === "" || clean === "/") continue;
    const withSlash = clean.endsWith("/") ? clean : clean + "/";
    if (pages.has(withSlash) || pages.has(clean)) continue;
    // allow deep links into hashed asset dirs via direct file match
    if (assets.has(clean) || assets.has(clean.replace(/\/$/, ""))) continue;
    console.log(`DEAD: ${url} (in ${f.replace(dist + "/", "")})`);
    dead++;
  }
}

if (dead > 0) {
  console.log(`\n${dead} dead internal links`);
  process.exit(1);
}
console.log(`OK: ${files.length} pages checked, all internal links resolve`);
