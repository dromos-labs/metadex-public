#!/usr/bin/env node

// lint-staged pre-commit helper only. Used to improve local devex. Do not use
// this in CI: it depends on the local staged-file list and the current commit diff.
const {spawnSync} = require('child_process');
const path = require('path');

const files = process.argv.slice(2);

if (files.length === 0) process.exit(0);

const rootResult = spawnSync('git', ['rev-parse', '--show-toplevel'], {encoding: 'utf8'});
const repoRoot = rootResult.status === 0 ? rootResult.stdout.trim() : process.cwd();

const normalize = (file) => path.resolve(repoRoot, file);
const trailingContextLines = 3;

// Parse the current commit diff into the set of lines that can carry new diagnostics.
const changedLinesFor = (file) => {
  const diff = spawnSync('git', ['diff', '--unified=0', 'HEAD', '--', file], {encoding: 'utf8'});
  if (diff.status !== 0) return new Set();

  const lines = new Set();
  let nextLine = 0;

  const addTrailingContext = () => {
    if (nextLine === 0) return;

    for (let offset = 0; offset < trailingContextLines; offset += 1) {
      lines.add(nextLine + offset);
    }
  };

  for (const line of diff.stdout.split('\n')) {
    const hunk = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (hunk) {
      addTrailingContext();
      nextLine = Number(hunk[1]);
      continue;
    }

    if (line.startsWith('+++') || line.startsWith('---')) continue;

    if (line.startsWith('+')) {
      lines.add(nextLine);
      nextLine += 1;
    } else if (line.startsWith(' ')) {
      nextLine += 1;
    }
  }

  addTrailingContext();

  return lines;
};

const solidityFiles = files.filter((file) => file.endsWith('.sol'));
const changedLines = new Map(solidityFiles.map((file) => [normalize(file), changedLinesFor(file)]));

const reports = [];

// Use Solhint's own rules, then hide diagnostics that land outside the current commit diff.
// Run per file so Solhint's JSON output stays parseable even when the V3 diff is large.
for (const file of solidityFiles) {
  const solhint = spawnSync('npx', ['--no-install', 'solhint', '--formatter', 'json', file], {
    encoding: 'utf8',
  });

  if (solhint.error) {
    console.error(solhint.error.message);
    process.exit(1);
  }

  const output = solhint.stdout.trim();
  if (output.length === 0) {
    if (solhint.status !== 0) {
      process.stderr.write(solhint.stderr);
      process.exit(solhint.status ?? 1);
    }

    continue;
  }

  try {
    reports.push(...JSON.parse(output));
  } catch {
    process.stdout.write(solhint.stdout);
    process.stderr.write(solhint.stderr);
    process.exit(1);
  }
}

const relevant = reports.filter((report) => {
  if (!report.filePath || !report.line) return false;
  const lines = changedLines.get(normalize(report.filePath));
  return lines?.has(report.line);
});

if (relevant.length === 0) process.exit(0);

const grouped = new Map();
for (const report of relevant) {
  const reports = grouped.get(report.filePath) ?? [];
  reports.push(report);
  grouped.set(report.filePath, reports);
}

let errors = 0;
let warnings = 0;
const severityFor = (report) => String(report.severity).toLowerCase();

for (const [filePath, reports] of grouped) {
  console.error(`\n${filePath}`);

  const lineWidth = Math.max(...reports.map((report) => String(report.line).length), 1);
  const columnWidth = Math.max(...reports.map((report) => String(report.column).length), 1);
  const severityWidth = Math.max(...reports.map((report) => severityFor(report).length), 7);
  const messageWidth = Math.max(...reports.map((report) => report.message.length), 1);

  for (const report of reports) {
    const severity = severityFor(report);
    if (severity === 'error') errors += 1;
    else warnings += 1;

    const location = `${String(report.line).padStart(lineWidth)}:${String(report.column).padEnd(columnWidth)}`;
    console.error(
      `  ${location}  ${severity.padEnd(severityWidth)}  ${report.message.padEnd(messageWidth)}  ${report.ruleId}`,
    );
  }
}

console.error(
  `\n\u2716 ${relevant.length} problem${relevant.length === 1 ? '' : 's'} (${errors} error${errors === 1 ? '' : 's'}, ${warnings} warning${warnings === 1 ? '' : 's'}) on or near lines changed by this commit.`,
);
process.exit(1);
