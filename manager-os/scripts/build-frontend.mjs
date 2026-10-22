#!/usr/bin/env node
/**
 * Builds the production frontend: static/ (readable sources) → dist/static/
 * (minified). The image ships dist/static; local development keeps serving
 * static/ directly, so there is nothing to rebuild while editing.
 *
 *   npm run build          Tailwind + minification
 *   node scripts/build-frontend.mjs   minification only
 *
 * Same file names and paths as the sources: the Rust service and the HTML
 * keep referencing /static/script.js, /static/style.css, ...
 */
import { build } from "esbuild";
import { minify } from "html-minifier-terser";
import { mkdir, readdir, readFile, rm, stat, writeFile, copyFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SRC = path.join(ROOT, "static");
const OUT = path.join(ROOT, "dist", "static");

/* WPE WebKit 2.38 (Debian bookworm) ≈ Safari 16: esbuild lowers anything newer. */
const TARGET = ["safari16"];

/* Build inputs that must not be shipped to the device. */
const SKIP = new Set(["input.css", "tailwind.config.js"]);

/* Placeholders the Rust service replaces at runtime: they must survive. */
const PLACEHOLDER = "{{KIOSK_HOMEPAGE_URL}}";

const HTML_OPTIONS = {
  collapseWhitespace: true,
  removeComments: true,
  removeRedundantAttributes: true,
  removeScriptTypeAttributes: true,
  removeStyleLinkTypeAttributes: true,
  useShortDoctype: true,
  minifyCSS: true,
  /* Always double quotes: the service inserts the homepage URL escaped for a
     double-quoted JavaScript string. */
  minifyJS: { format: { quote_style: 2 } },
};

async function minifyAsset(file, loader) {
  const result = await build({
    entryPoints: [path.join(SRC, file)],
    outfile: path.join(OUT, file),
    loader: { [`.${loader}`]: loader },
    bundle: false,
    minify: true,
    target: TARGET,
    legalComments: "none",
    charset: "utf8",
    logLevel: "warning",
    write: true,
  });
  if (result.errors.length > 0) {
    throw new Error(`esbuild failed for ${file}`);
  }
}

async function minifyHtml(file) {
  const source = await readFile(path.join(SRC, file), "utf8");
  const output = await minify(source, HTML_OPTIONS);

  const expected = source.split(PLACEHOLDER).length - 1;
  const kept = output.split(PLACEHOLDER).length - 1;
  if (kept !== expected) {
    throw new Error(
      `${file}: ${PLACEHOLDER} appears ${expected} time(s) in the source but ${kept} in the output`,
    );
  }
  if (!/^<!doctype html>/i.test(output)) {
    throw new Error(`${file}: the doctype was lost`);
  }
  await writeFile(path.join(OUT, file), output);
}

function kib(bytes) {
  return (bytes / 1024).toFixed(1).padStart(6) + " KiB";
}

async function main() {
  await rm(OUT, { recursive: true, force: true });
  await mkdir(OUT, { recursive: true });

  const files = (await readdir(SRC, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && !SKIP.has(entry.name) && !entry.name.startsWith("."))
    .map((entry) => entry.name)
    .sort();

  let before = 0;
  let after = 0;
  for (const file of files) {
    const ext = path.extname(file).slice(1);
    if (ext === "html") {
      await minifyHtml(file);
    } else if (ext === "js" || ext === "css") {
      await minifyAsset(file, ext);
    } else {
      await copyFile(path.join(SRC, file), path.join(OUT, file));
    }
    const srcSize = (await stat(path.join(SRC, file))).size;
    const outSize = (await stat(path.join(OUT, file))).size;
    before += srcSize;
    after += outSize;
    console.log(`  ${file.padEnd(28)} ${kib(srcSize)} → ${kib(outSize)}`);
  }
  const saved = before > 0 ? Math.round((1 - after / before) * 100) : 0;
  console.log(`  ${"total".padEnd(28)} ${kib(before)} → ${kib(after)}  (-${saved}%)`);
}

main().catch((error) => {
  console.error(`build-frontend: ${error.message}`);
  process.exit(1);
});
