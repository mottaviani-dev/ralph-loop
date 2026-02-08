# Documentation Style Guide

This guide defines tone, structure, length, and linking conventions for all documentation produced by discovery agents. Every doc written to `docs/<service>/` or `docs/_cross-service/` must follow these rules.

---

## Agent Digest Block

Every documentation file (except README.md and _gaps.md) must begin with an **AGENT_DIGEST** HTML comment block. This block is invisible on the documentation website but provides structured metadata for AI agents working in the codebase.

### Format

```markdown
<!-- AGENT_DIGEST
purpose: One-sentence description of what this feature/system does
services: comma-separated list of services involved
key_files: 3-5 most important file paths (relative from project root)
depends_on: slugs of docs this feature depends on (without path or extension)
related:
  - relative path to related doc 1
  - relative path to related doc 2
-->
```

### Rules

- **Placement**: First thing in the file, before the H1 title. No blank lines before it.
- **Target size**: ~50 tokens (5-7 lines). Keep it scannable, not exhaustive.
- **`purpose`**: One sentence, present tense, business-context first. Example: "Manages the checkout pipeline with validation and processing steps for point-based purchases."
- **`services`**: The service(s) this doc covers. Use slug names matching the module registry.
- **`key_files`**: 3-5 paths relative from the service's project root. Use directory paths with trailing `/` for directories. Omit if the doc is purely conceptual.
- **`depends_on`**: Slug names (filename without extension) of other docs that must be understood first. Omit if none.
- **`related`**: 2-5 relative markdown links to related docs. Use `../` notation relative to the current file's location.

### Example

```markdown
<!-- AGENT_DIGEST
purpose: Orchestrates the checkout pipeline with validation steps and payment processing for point-based purchases
services: api-service
key_files: src/Shop/Checkout/Steps/, src/Shop/Checkout/CheckoutService.php, src/Shop/Checkout/OrderReference.php
depends_on: point-bank-strategy, order-lifecycle
related:
  - ../core/accounting-strategy.md
  - ./sales-management.md
  - ../../_cross-service/features/orders/order-lifecycle.md
-->

# Checkout Flow
```

---

## Audience & Tone

- **Primary audience**: developers browsing a documentation website, not reading raw source files.
- Open with what a feature does for the business (1–2 sentences) before diving into implementation.
- Active voice, present tense: "The checkout pipeline validates..." not "Validation is performed by..."
- Technical but approachable — avoid academic phrasing and encyclopedic exhaustiveness.

---

## Document Structure Template

```markdown
# Feature Name

## Overview
2–4 sentences: what it does, why it matters, who uses it.

## How It Works
Flow, sequence, key decisions — the core content.
ASCII diagrams encouraged for multi-step processes (keep under 20 lines).

## Key Components
Brief table: class/file → responsibility (3–5 rows, not exhaustive).

## Configuration
Env vars, DB flags, feature toggles (if applicable).

## Related Docs
- [Companion Feature](../category/companion-feature.md)
- [Cross-Service Flow](../../_cross-service/category/flow.md)

## Known Gaps
Narrative list of unknowns. No GAP-XXX-N enumeration.
```

Not every section is required — omit Configuration or Known Gaps if they don't apply. But Overview, How It Works, Key Components, and Related Docs are mandatory.

---

## Target Length

- **Service-specific docs**: 150–300 lines
- **Cross-service summaries**: 100–150 lines

If a doc exceeds these limits, it's trying to cover too much. Split it.

---

## File Path References

- Use **relative paths from the project root**: `app/Http/Controllers/OrderController.php`
- **Never** use absolute paths (`/Users/...`)
- Focus on the 3–5 key files — don't catalog every file touched.
- Inline paths in explanatory text, not in separate "File Reference Index" tables.

---

## Code Examples

- Short (5–15 lines), showing only the interesting part (strategy selection, event dispatch, calculation).
- Omit boilerplate (use statements, constructor injection, docblocks).
- Use the language's native syntax highlighting in fenced code blocks.

---

## Cross-References & Linking

- Link to related docs using **relative markdown paths**: `[Checkout Flow](../features/orders/checkout-flow.md)`
- For cross-service docs: `[Order Lifecycle](../../_cross-service/features/orders/order-lifecycle.md)`
- Always include a **Related Docs** section with 2–5 links.
- The site build resolves all links — don't worry about exact path resolution.

---

## What NOT to Include

- No YAML frontmatter (the site build injects it).
- No absolute filesystem paths.
- No exhaustive file-to-line-number reference tables.
- No "GAP-XXX-N" enumeration codes.
- No "File Reference Index" sections listing every file with line numbers.
