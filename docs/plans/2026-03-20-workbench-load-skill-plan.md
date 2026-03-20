# Workbench Load Skill — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a new `workbench` plugin with a `load` skill that bootstraps project context mid-session from `~`.

**Architecture:** Single skill reads a YAML registry to resolve project shortnames to root paths, then reads CLAUDE.md and runs git commands from that root. No application code — just skill instructions and a config file.

**Tech Stack:** Claude Code plugin (SKILL.md + YAML registry)

---

### Task 1: Create Plugin Scaffold

**Files:**
- Create: `~/Obsidian/MyVault/Playground/Development/workbench/.claude-plugin/plugin.json`

**Step 1: Create plugin.json**

```json
{
  "name": "workbench",
  "version": "0.1.0",
  "description": "On-demand project context loader for mid-session use",
  "author": {
    "name": "Ciro"
  },
  "keywords": [
    "project",
    "context",
    "loader",
    "session",
    "bootstrap"
  ]
}
```

**Step 2: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development
git add workbench/.claude-plugin/plugin.json
git commit -m "feat(workbench): plugin scaffold"
```

---

### Task 2: Create Project Registry

**Files:**
- Create: `~/Obsidian/MyVault/Playground/Development/workbench/skills/load/references/projects.yaml`

**Step 1: Create projects.yaml**

```yaml
claudeboard:
  aliases: [cb]
  root: ~/Obsidian/MyVault/Playground/Development/claudeboard
```

**Step 2: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development
git add workbench/skills/load/references/projects.yaml
git commit -m "feat(workbench): project registry with claudeboard entry"
```

---

### Task 3: Write the SKILL.md

**Files:**
- Create: `~/Obsidian/MyVault/Playground/Development/workbench/skills/load/SKILL.md`

**Step 1: Write SKILL.md**

The skill needs frontmatter with trigger description, then instructions for the 4-step flow: resolve → read CLAUDE.md → git orientation → present summary.

```markdown
---
name: load
description: >-
  On-demand project context loader. Use when the user says "/load <project>",
  "load claudeboard", "load cb", or wants to bootstrap a project's context
  mid-session without cd-ing into the project directory. Reads the project's
  CLAUDE.md and git state into the current conversation.
trigger:
  - load
  - workbench:load
---

# Load Project Context

Bootstraps a project's development context into the current session. Reads the
project's CLAUDE.md (build commands, architecture, safety rules) and git state
so the session is oriented without needing to cd into the project directory.

## Arguments

**Required:** project name or alias (e.g., `claudeboard`, `cb`).

If no argument is provided, or the argument doesn't match any project, list all
available projects from the registry and ask the user which one they want.

## Step 1: Resolve Project

Read `references/projects.yaml` to find the project entry.

Match the user's argument against:
1. The project key (e.g., `claudeboard`)
2. Any value in the `aliases` list (e.g., `cb`)

If no match, print all available projects as a table:

| Shortname | Aliases | Root |
|-----------|---------|------|
| claudeboard | cb | ~/Obsidian/.../claudeboard |

Then ask: "Which project do you want to load?"

## Step 2: Read CLAUDE.md

Read `{root}/CLAUDE.md` where `root` is the resolved project's root path.

If the file doesn't exist, warn: "No CLAUDE.md found at {root}. Continuing with git state only."

Present the CLAUDE.md content clearly — this is the core value of the skill. The
session now has the project's build commands, architecture rules, and safety
patterns loaded.

## Step 3: Git Orientation

Run from the project root (use absolute paths, do not cd):

1. `git -C {root} log --oneline -10` — recent commits
2. `git -C {root} status` — current branch, uncommitted work

## Step 4: Present Summary

Output a structured summary:

```
## ✅ Loaded: {project name}

**Root:** {root}
**Branch:** {current branch}
**State:** {clean / N uncommitted changes}

### Recent Activity
{last 10 commits as a list}

Ready to work on {project name}. What are we doing?
```

## Rules

- Do NOT read any files beyond CLAUDE.md. The user will direct you to specific files.
- Do NOT spawn subagents.
- Do NOT save to memory or Graphiti — this produces no durable knowledge.
- Expand `~` in the root path before using it in commands.
```

**Step 2: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development
git add workbench/skills/load/SKILL.md
git commit -m "feat(workbench): load skill — on-demand project context loader"
```

---

### Task 4: Register in Marketplace

**Files:**
- Modify: `~/Obsidian/MyVault/Playground/Development/.claude-plugin/marketplace.json`

**Step 1: Add workbench entry to the plugins array**

Add this entry to the `plugins` array in marketplace.json:

```json
{
  "name": "workbench",
  "version": "0.1.0",
  "description": "On-demand project context loader for mid-session use",
  "source": "./workbench"
}
```

**Step 2: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development
git add .claude-plugin/marketplace.json
git commit -m "feat(workbench): register in ciro marketplace"
```

---

### Task 5: Push and Install

**Step 1: Push to GitHub**

```bash
cd ~/Obsidian/MyVault/Playground/Development
git push
```

**Step 2: Install the plugin**

```bash
claude plugin install workbench@ciro --scope user
```

**Step 3: Verify**

Start a new session or invoke `/load cb` to verify the skill triggers correctly, reads the ClaudeBoard CLAUDE.md, and shows git state.

---
