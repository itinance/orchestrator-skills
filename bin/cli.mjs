#!/usr/bin/env node
// Installs the skills of this package into a Claude Code skills folder.
// No dependencies, no network access: it only copies files that ship in the package.

import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const PKG_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PKG = JSON.parse(readFileSync(join(PKG_ROOT, 'package.json'), 'utf8'));

const HELP = `${PKG.name} ${PKG.version}

Usage:
  ${PKG.name} install [skill...] [options]   Copy skills into .claude/skills
  ${PKG.name} list                           List the skills in this package
  ${PKG.name} --help | --version

Without skill names, install copies all skills.

Options:
  -g, --global     Install into ~/.claude/skills (all projects)
                   Default: ./.claude/skills (this project)
  --dir <path>     Install into <path> instead
  -f, --force      Replace a skill folder that already exists
  -n, --dry-run    Print what would be copied, change nothing
`;

export function listSkills(root = PKG_ROOT) {
  return readdirSync(root, { withFileTypes: true })
    .filter((e) => e.isDirectory() && existsSync(join(root, e.name, 'SKILL.md')))
    .map((e) => e.name)
    .sort();
}

export function parseArgs(argv) {
  const opts = { command: null, skills: [], global: false, dir: null, force: false, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') opts.command = 'help';
    else if (a === '-v' || a === '--version') opts.command = 'version';
    else if (a === '-g' || a === '--global') opts.global = true;
    else if (a === '-f' || a === '--force') opts.force = true;
    else if (a === '-n' || a === '--dry-run') opts.dryRun = true;
    else if (a === '--dir') {
      opts.dir = argv[++i];
      if (!opts.dir) throw new Error('--dir needs a path');
    } else if (a.startsWith('--dir=')) opts.dir = a.slice('--dir='.length);
    else if (a.startsWith('-')) throw new Error(`Unknown option: ${a}`);
    else if (!opts.command) opts.command = a;
    else opts.skills.push(a);
  }
  if (opts.global && opts.dir) throw new Error('Use either --global or --dir, not both');
  return opts;
}

export function targetDir(opts, { cwd = process.cwd(), home = homedir() } = {}) {
  if (opts.dir) return resolve(cwd, opts.dir);
  if (opts.global) return join(home, '.claude', 'skills');
  return join(cwd, '.claude', 'skills');
}

export function install(opts, { root = PKG_ROOT, cwd, home, log = console.log } = {}) {
  const available = listSkills(root);
  const unknown = opts.skills.filter((s) => !available.includes(s));
  if (unknown.length) {
    throw new Error(`Unknown skill: ${unknown.join(', ')}. Available: ${available.join(', ')}`);
  }
  const chosen = opts.skills.length ? opts.skills : available;
  const dest = targetDir(opts, { cwd, home });

  const clashes = chosen.filter((s) => existsSync(join(dest, s)));
  if (clashes.length && !opts.force) {
    throw new Error(
      `Already installed in ${dest}: ${clashes.join(', ')}. Use --force to replace.`,
    );
  }

  const prefix = opts.dryRun ? '[dry run] ' : '';
  if (!opts.dryRun) mkdirSync(dest, { recursive: true });
  for (const skill of chosen) {
    const to = join(dest, skill);
    if (!opts.dryRun) {
      if (existsSync(to)) rmSync(to, { recursive: true, force: true });
      cpSync(join(root, skill), to, { recursive: true, verbatimSymlinks: true });
    }
    log(`${prefix}${clashes.includes(skill) ? 'replaced' : 'installed'} ${skill} -> ${to}`);
  }
  if (!opts.dryRun) log('The skills are available in the next Claude Code session.');
  return { dest, installed: chosen };
}

function main(argv) {
  const opts = parseArgs(argv);
  switch (opts.command) {
    case null:
    case 'help':
      process.stdout.write(HELP);
      return;
    case 'version':
      console.log(PKG.version);
      return;
    case 'list':
      for (const s of listSkills()) console.log(s);
      return;
    case 'install':
    case 'add':
      install(opts);
      return;
    default:
      throw new Error(`Unknown command: ${opts.command}. Run with --help.`);
  }
}

const isMain = (() => {
  try {
    return statSync(process.argv[1]).ino === statSync(fileURLToPath(import.meta.url)).ino;
  } catch {
    return false;
  }
})();

if (isMain) {
  try {
    main(process.argv.slice(2));
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
  }
}
