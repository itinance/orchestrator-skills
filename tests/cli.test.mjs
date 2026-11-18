import { strict as assert } from 'node:assert';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { install, listSkills, parseArgs, targetDir } from '../bin/cli.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CLI = join(ROOT, 'bin', 'cli.mjs');
const tmp = mkdtempSync(join(tmpdir(), 'orchestrator-skills-'));
after(() => rmSync(tmp, { recursive: true, force: true }));
const quiet = () => {};

test('lists the skills that ship in the package', () => {
  assert.deepEqual(listSkills(ROOT), ['orchestrating-agent-lanes']);
});

test('target folder: project by default, --global, --dir', () => {
  const env = { cwd: '/p', home: '/h' };
  assert.equal(targetDir(parseArgs(['install']), env), '/p/.claude/skills');
  assert.equal(targetDir(parseArgs(['install', '-g']), env), '/h/.claude/skills');
  assert.equal(targetDir(parseArgs(['install', '--dir', 'x']), env), '/p/x');
  assert.throws(() => parseArgs(['install', '-g', '--dir', 'x']), /either/);
  assert.throws(() => parseArgs(['install', '--bogus']), /Unknown option/);
});

test('installs all skills into the project folder', () => {
  const cwd = join(tmp, 'proj');
  mkdirSync(cwd);
  const { dest } = install(parseArgs(['install']), { root: ROOT, cwd, log: quiet });
  for (const f of ['SKILL.md', 'lane-briefs.md', 'merge-gates.md', 'setup-checklist.md']) {
    assert.ok(existsSync(join(dest, 'orchestrating-agent-lanes', f)), f);
  }
});

test('refuses to overwrite without --force, replaces with --force', () => {
  const cwd = join(tmp, 'proj2');
  const skill = join(cwd, '.claude', 'skills', 'orchestrating-agent-lanes');
  mkdirSync(skill, { recursive: true });
  writeFileSync(join(skill, 'stale.md'), 'old');
  assert.throws(() => install(parseArgs(['install']), { root: ROOT, cwd, log: quiet }), /--force/);
  assert.ok(existsSync(join(skill, 'stale.md')));
  install(parseArgs(['install', '--force']), { root: ROOT, cwd, log: quiet });
  assert.ok(!existsSync(join(skill, 'stale.md')));
  assert.ok(existsSync(join(skill, 'SKILL.md')));
});

test('rejects unknown skill names, including path tricks', () => {
  const cwd = join(tmp, 'proj3');
  for (const name of ['nope', '../bin', 'tests']) {
    assert.throws(
      () => install(parseArgs(['install', name]), { root: ROOT, cwd, log: quiet }),
      /Unknown skill/,
    );
  }
  assert.ok(!existsSync(join(cwd, '.claude')));
});

test('dry run changes nothing', () => {
  const cwd = join(tmp, 'proj4');
  install(parseArgs(['install', '-n']), { root: ROOT, cwd, log: quiet });
  assert.ok(!existsSync(join(cwd, '.claude')));
});

test('the bin runs end to end', () => {
  const cwd = join(tmp, 'proj5');
  mkdirSync(cwd);
  const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'));
  assert.equal(execFileSync(process.execPath, [CLI, '--version']).toString().trim(), pkg.version);
  execFileSync(process.execPath, [CLI, 'install'], { cwd });
  assert.ok(existsSync(join(cwd, '.claude', 'skills', 'orchestrating-agent-lanes', 'SKILL.md')));
});
