#!/usr/bin/env bun

/**
 * Runs all .test files in a directory against the sqllogictest binary,
 * collects pass/fail counts per file, and writes a JSON report compatible
 * with the CoveragePayload type consumed by the site.
 *
 * Usage:
 *   bun testing/sqllogictest/runner.ts [options]
 *
 * Options:
 *   --dir <path>        Directory of .test files  (default: testing/sqllogictest/tests)
 *   --json <path>       Write JSON report to this path
 *   --commit <sha>      Commit SHA to embed in the report
 *   --timeout <sec>     Per-file timeout in seconds (default: 180)
 *   --concurrency <n>   Max parallel workers (default: CPU count)
 *   --memory-mb <mb>    Virtual memory cap per worker in MB (default: 512)
 *   --no-build          Skip `zig build` (binary must already exist)
 *   --fail-fast         Stop on first failure and print details (implies --concurrency 1)
 */

import { readdirSync, writeFileSync, statSync } from "fs";
import { join, resolve, basename } from "path";
import { cpus } from "os";

// ─── Types ─────────────────────────────────────────────────────────────────────

// Matches CoverageFile in SqllogictestCoverage.tsx
interface FileResult {
  path: string;
  passed: number;
  failed: number;
}

// Matches CoveragePayload in SqllogictestCoverage.tsx
interface Report {
  generated_at: number; // unix seconds
  commit: string;
  summary: {
    passed: number;
    failed: number;
    files: number;
  };
  files: FileResult[];
}

// ─── Arg parsing ───────────────────────────────────────────────────────────────

function parseArgs() {
  const args = Bun.argv.slice(2);
  let dir = "testing/sqllogictest/tests";
  let output: string | null = null;
  let commit = "unknown";
  let timeoutSec = 180;
  let concurrency = cpus().length;
  let memoryMb = 512;
  let noBuild = false;
  let failFast = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--dir" && args[i + 1]) dir = args[++i];
    else if ((arg === "--json" || arg === "--output") && args[i + 1])
      output = args[++i];
    else if (arg === "--commit" && args[i + 1]) commit = args[++i];
    else if (arg === "--timeout" && args[i + 1])
      timeoutSec = parseInt(args[++i]);
    else if (arg === "--concurrency" && args[i + 1])
      concurrency = parseInt(args[++i]);
    else if (arg === "--memory-mb" && args[i + 1])
      memoryMb = parseInt(args[++i]);
    else if (arg === "--no-build") noBuild = true;
    else if (arg === "--fail-fast") failFast = true;
  }

  // fail-fast must be sequential so we can stop immediately on the first failure.
  if (failFast) concurrency = 1;

  return { dir, output, commit, timeoutSec, concurrency, memoryMb, noBuild, failFast };
}

// ─── Helpers ───────────────────────────────────────────────────────────────────

function collectTestFiles(dir: string): string[] {
  const results: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      results.push(...collectTestFiles(full));
    } else if (entry.endsWith(".test")) {
      results.push(full);
    }
  }
  return results.sort();
}

// Parses "N passed, M failed" from slt binary output
function parsePassFail(text: string): { passed: number; failed: number } {
  const match = text.match(/(\d+) passed, (\d+) failed/);
  if (!match) return { passed: 0, failed: 0 };
  return { passed: parseInt(match[1]), failed: parseInt(match[2]) };
}

function formatBar(passed: number, total: number, width = 20): string {
  const filled = total === 0 ? width : Math.round((passed / total) * width);
  return "█".repeat(filled) + "░".repeat(width - filled);
}

// Runs a single test file and returns its result.
// Memory is capped via `ulimit -v` (virtual address space) in a shell wrapper.
async function runFile(
  binary: string,
  file: string,
  timeoutSec: number,
  memoryKb: number,
  extraArgs: string[] = []
): Promise<{ passed: number; failed: number; tag: string; elapsed: number; output: string }> {
  const start = Date.now();

  // ulimit -v caps virtual memory (in KB). Wrapping with sh -c ensures the
  // limit applies to the child process without affecting the runner itself.
  const proc = Bun.spawn(
    ["sh", "-c", `ulimit -v ${memoryKb} && exec "$@"`, "--", binary, file, ...extraArgs],
    { stdout: "pipe", stderr: "pipe" }
  );

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill("SIGTERM");
  }, timeoutSec * 1000);

  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exitCode = await proc.exited;
  clearTimeout(timer);

  const elapsed = Date.now() - start;
  const combined = stdout + stderr;
  const { passed, failed } = parsePassFail(combined);

  let tag: string;
  if (timedOut) tag = "TIMEOUT";
  else if (exitCode === 0) tag = "PASS";
  else tag = "FAIL";

  return { passed, failed, tag, elapsed, output: combined };
}

// ─── Main ──────────────────────────────────────────────────────────────────────

const { dir, output, commit, timeoutSec, concurrency, memoryMb, noBuild, failFast } =
  parseArgs();

// Build the binary once
if (!noBuild) {
  process.stdout.write("Building sqllogictest binary... ");
  const build = Bun.spawnSync(["zig", "build"], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (build.exitCode !== 0) {
    console.error("FAILED");
    process.stderr.write(build.stderr?.toString() ?? "");
    process.exit(1);
  }
  console.log("done");
}

const binary = resolve("zig-out/bin/sqllogictest");
const testDir = resolve(dir);
const memoryKb = memoryMb * 1024;

// Discover .test files recursively
let files: string[];
try {
  files = collectTestFiles(testDir);
} catch {
  console.error(`Cannot read directory: ${testDir}`);
  process.exit(1);
}

if (files.length === 0) {
  console.error(`No .test files found in ${testDir}`);
  process.exit(1);
}

console.log(
  `\nRunning ${files.length} files from ${testDir}` +
    `  [concurrency=${concurrency}, timeout=${timeoutSec}s, memory=${memoryMb}MB]\n`
);

// Run files in parallel with a fixed-width worker pool.
// Results are stored by original index so the JSON order matches file order.
const results: FileResult[] = new Array(files.length);
let totalPassed = 0;
let totalFailed = 0;
let cursor = 0; // next file index to dispatch
let stopped = false; // set true by fail-fast to halt further dispatch

const binaryArgs = failFast ? ["--fail-fast"] : [];

async function worker() {
  while (cursor < files.length && !stopped) {
    const idx = cursor++;
    const file = files[idx];
    const name = file.startsWith(testDir + "/")
      ? file.slice(testDir.length + 1)
      : basename(file);

    const { passed, failed, tag, elapsed, output } = await runFile(
      binary,
      file,
      timeoutSec,
      memoryKb,
      binaryArgs
    );

    const total = passed + failed;
    const pct = total === 0 ? 100 : (passed / total) * 100;
    const icon = tag === "PASS" ? "✓" : tag === "TIMEOUT" ? "T" : "✗";

    // Each console.log call is atomic — no interleaving mid-line.
    console.log(
      `${icon} ${name.padEnd(44)} ${formatBar(passed, total)}  ${pct
        .toFixed(1)
        .padStart(6)}%  [${elapsed}ms]`
    );

    if (failFast && tag !== "PASS") {
      // Print the raw binary output so the failure detail is visible.
      process.stderr.write(output);
      stopped = true;
    }

    totalPassed += passed;
    totalFailed += failed;
    results[idx] = { path: name, passed, failed };
  }
}

await Promise.all(Array.from({ length: concurrency }, worker));

// Summary line
const grandTotal = totalPassed + totalFailed;
const grandPct = grandTotal === 0 ? 100 : (totalPassed / grandTotal) * 100;
console.log("\n" + "─".repeat(72));
console.log(
  `  ${totalPassed.toLocaleString()} / ${grandTotal.toLocaleString()} passed` +
    `  (${grandPct.toFixed(2)}%)` +
    `  across ${files.length} files`
);

// Write JSON report
if (output) {
  const report: Report = {
    generated_at: Math.floor(Date.now() / 1000),
    commit,
    summary: {
      passed: totalPassed,
      failed: totalFailed,
      files: results.length,
    },
    files: results,
  };
  writeFileSync(output, JSON.stringify(report, null, 2));
  console.log(`\nReport written to ${output}`);
}

if (totalFailed > 0) process.exit(1);
