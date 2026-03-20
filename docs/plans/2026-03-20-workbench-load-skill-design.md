# Workbench Load Skill — Design

**Date:** 2026-03-20
**Status:** Approved

## Problem

Claude sessions launched from `~` never load project-scoped CLAUDE.md files. ClaudeBoard's CLAUDE.md (build commands, architecture rules, Swift 6 safety patterns) goes unseen unless the user manually `cd`s first. The user works on multiple projects in a single session and needs on-demand context loading.

## Solution

A new plugin (`workbench@ciro`) with a single skill (`load`) that bootstraps project context mid-session. Invoked as `/load claudeboard` or `/load cb`.

## Registry

`references/projects.yaml` maps shortnames and aliases to project root paths:

```yaml
claudeboard:
  aliases: [cb]
  root: ~/Obsidian/MyVault/Playground/Development/claudeboard
```

Future projects are added as new entries. The skill derives all paths (CLAUDE.md, git) from the root.

## Skill Flow

1. **Resolve project** — match argument against name or alias in registry. Fail with available project list if not found.
2. **Read CLAUDE.md** — read `{root}/CLAUDE.md` and present as project instructions.
3. **Git orientation** — from project root, run `git log --oneline -10` and `git status`.
4. **Present summary** — project name, root path, current branch, dirty/clean state, recent commits. Confirm ready to work.

## What It Does NOT Do

- No file reading beyond CLAUDE.md
- No hooks or scheduled automation
- No subagents
- No memory saves
- No TDD (no application code)

## Plugin Structure

```
workbench/
├── plugin.json
├── .claude-plugin/
│   └── marketplace.json
├── skills/
│   └── load/
│       ├── SKILL.md
│       └── references/
│           └── projects.yaml
```

## Deploy

Add to ciro marketplace → `git push` → `claude plugin install workbench@ciro --scope user`.
