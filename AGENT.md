# AGENT.md — Gap Resolution Worker

## Mission

Read the VitePress documentation files in `../docs/` and resolve the gaps documented there. Another agent is continuously writing these docs — your job is to act on them.

## How It Works

1. Scan all `.md` files in `../docs/concepts/`, `../docs/guides/`, `../docs/reference/`
2. Find sections marked with `:::warning` or containing "Gap", "Missing", "TODO", "Not implemented", "Stub", "v2 does not"
3. For each gap, decide:
   - **Trivial fix** (missing import, stub method, wrong path, simple logic port) → fix it directly in `../src/app/`
   - **Architecture decision needed** → append to `../docs/reference/pending-work.md` and leave the gap section unresolved

## Rules

- **DO NOT modify any `.md` files in `../docs/`** — the discovery loop owns those. Only modify source code in `../src/app/` and the `pending-work.md` file.
- **DO NOT create new documentation files** — only the discovery loop does that.
- **One gap per cycle** — pick the highest-impact trivial gap and fix it.
- **Test after fixing** — run `yarn ng build` from `..` to verify the fix compiles.
- **Evidence in journal** — record which doc, which gap, what you fixed, and the build result.

## What Counts as Trivial

Fix these directly:
- A v2 service method is a stub that should call an API endpoint (the doc tells you which one)
- A v2 component is missing a feature that the doc describes and the v1 code shows how to implement
- A CSS/SCSS issue where the doc describes the expected styling
- A missing route that the doc says should exist
- A config field that needs updating
- A component not importing a required module

## What Counts as Architecture Decision

Append to `pending-work.md` instead:
- "v2 needs a completely different component structure for this"
- "The v1 approach won't work in v2 because of [signals/standalone/etc]"
- "This feature requires a new service that doesn't exist yet"
- "The API response format needs to change"
- "This involves multiple components coordinating in a way that needs design"

## pending-work.md Format

When appending, use this format:
```markdown
### [Category] — [Brief description]

**Source**: docs/concepts/[filename].md — [section name]
**V1 behavior**: [what v1 does]
**V2 status**: [what v2 currently does/doesn't do]
**Effort**: Small / Medium / Large
**Needs**: [what decision or work is required]
```

## Source Code Locations

- V2 app code: `../src/app/`
- V2 services: `../src/app/core/`
- V2 components: `../src/app/shared/components/` and `../src/app/features/`
- V2 styles: `../src/styles/`
- V1 reference: `../../ng-sir/src/app/` (read-only, for comparison)
- Build command: `cd .. && yarn ng build`

## Cycle Priority

1. Read `pending-work.md` to avoid duplicating entries you've already logged
2. Read your journal to know which doc files you've already scanned
3. Pick the NEXT unscanned doc file — work through them systematically:
   - `../docs/concepts/*.md` (most gaps here)
   - `../docs/reference/*.md`
   - `../docs/guides/*.md`
4. Within that file, find ALL :::warning blocks, "Gap", "Missing", "Not implemented", "Stub" mentions
5. For each gap: fix if trivial, or append to pending-work.md if complex
6. Record which file you scanned in your journal so you don't repeat it

**IMPORTANT**: New docs are being written by a parallel discovery loop. Even after you've scanned all files once, re-scan files that have been updated (check file modification dates or git status). This task is NEVER truly done — keep scanning for new gaps.

**DO NOT** declare the task complete. It is a recurring scan loop. If you run out of files, wait for the discovery loop to produce more — check `git log --oneline -5 -- ../docs/` to see recent doc updates.
