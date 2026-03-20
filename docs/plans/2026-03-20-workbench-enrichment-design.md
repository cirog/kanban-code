# Workbench Load Skill — Project Reference Enrichment

**Date:** 2026-03-20
**Status:** Approved

## Problem

The `/load cb` skill loads CLAUDE.md (rules) and git state, but a fresh session still wastes time exploring the codebase to find which files are involved in a given feature. Every session rediscovers the same file locations.

## Solution

Add a per-project reference file (`references/claudeboard.md`) containing a feature-oriented file map. The skill reads it alongside CLAUDE.md, giving the session instant navigation from user intent ("fix drag and drop") to exact file paths.

## Reference File Format

~100-120 lines grouped by feature. Each feature lists:
- Source files with one-line purpose
- Test files that cover the feature

No file contents, no architecture prose (CLAUDE.md handles that), no git state (Step 3 handles that).

## SKILL.md Change

Add Step 2b after reading CLAUDE.md: if `references/{project-key}.md` exists in the skill directory, read and present it as the project file map.

## projects.yaml Change

None — the reference file is discovered by convention (`references/{project-key}.md`), not configured.
