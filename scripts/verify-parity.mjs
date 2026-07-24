#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [catalogPath, manifestPath] = process.argv.slice(2);
if (!catalogPath || !manifestPath) {
  console.error("usage: verify-parity.mjs CATALOG.json MANIFEST.json");
  process.exit(64);
}
const load = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const fail = (message) => { console.error(`parity: ${message}`); process.exitCode = 1; };
const nonblank = (value) => typeof value === "string" && value.trim().length > 0;
const keyForExport = (entry) => `${entry.module}::${entry.name}`;
const states = new Set(["ported", "deferred", "not-applicable"]);

const catalog = load(catalogPath);
const manifest = load(manifestPath);
if (catalog.schema_version !== 1 || manifest.schema_version !== 1) fail("unsupported schema version");
for (const field of ["repository", "commit"]) {
  if (catalog.upstream?.[field] !== manifest.upstream?.[field]) fail(`upstream ${field} differs from catalog`);
}

const vectorMetadata = new Map();
for (const vector of manifest.vectors ?? []) {
  if (!nonblank(vector.path)) { fail("vector path is required"); continue; }
  if (vectorMetadata.has(vector.path)) fail(`duplicate vector metadata: ${vector.path}`);
  vectorMetadata.set(vector.path, vector);
}

function validateEntries(label, catalogEntries, manifestEntries, key) {
  if (!Array.isArray(manifestEntries)) return fail(`${label} entries must be an array`);
  const expected = new Set(catalogEntries.map(key));
  const actual = new Set();
  for (const entry of manifestEntries) {
    const entryKey = key(entry);
    if (actual.has(entryKey)) fail(`duplicate ${label} entry: ${entryKey}`);
    actual.add(entryKey);
    if (!states.has(entry.state)) fail(`${label} ${entryKey} has invalid state`);
    if ((entry.state === "deferred" || entry.state === "not-applicable") && !nonblank(entry.rationale)) {
      fail(`${label} ${entryKey} requires rationale`);
    }
    if (entry.state === "ported") {
      if (!nonblank(entry.lisp_symbol) || !nonblank(entry.lisp_test) || !Array.isArray(entry.vectors) || entry.vectors.length === 0) {
        fail(`ported ${label} ${entryKey} requires lisp_symbol, lisp_test, and vectors`);
      } else {
        for (const vectorPath of entry.vectors) {
          if (!vectorMetadata.has(vectorPath)) fail(`ported ${label} ${entryKey} references missing vector metadata: ${vectorPath}`);
        }
      }
    }
  }
  for (const entryKey of expected) if (!actual.has(entryKey)) fail(`unclassified upstream ${label}: ${entryKey}`);
  for (const entryKey of actual) if (!expected.has(entryKey)) fail(`stale ${label} entry: ${entryKey}`);
}
validateEntries("test file", catalog.test_files, manifest.test_files, (entry) => typeof entry === "string" ? entry : entry.path);
validateEntries("export", catalog.exports, manifest.exports, keyForExport);

for (const vector of manifest.vectors ?? []) {
  if (!nonblank(vector.path) || path.isAbsolute(vector.path) || vector.path.split(path.sep).includes("..")) fail(`unsafe vector path: ${vector.path}`);
  const fullPath = path.resolve("/workspace", vector.path);
  if (!fs.existsSync(fullPath)) { fail(`missing vector: ${vector.path}`); continue; }
  const digest = crypto.createHash("sha256").update(fs.readFileSync(fullPath)).digest("hex");
  if (digest !== vector.sha256) fail(`checksum mismatch: ${vector.path}`);
  if (vector.upstream_commit !== manifest.upstream?.commit) fail(`vector commit mismatch: ${vector.path}`);
  if (!nonblank(vector.target_lisp_test) || !nonblank(vector.generation_command) || !nonblank(vector.source?.pytest_node) || !nonblank(vector.source?.symbol)) fail(`incomplete provenance: ${vector.path}`);
}

if (process.exitCode) process.exit(process.exitCode);
console.log(`parity: ${catalog.test_files.length} test files and ${catalog.exports.length} exports classified`);
