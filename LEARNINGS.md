# Learnings

Accumulated patterns, gotchas, and conventions discovered by the ralph-loop agent.
This file is read at the start of every cycle so future iterations benefit from past discoveries.

Content is managed by the agent during work cycles. Manual edits are preserved.

---

## V2 Component Wiring Pattern
- Orphaned standalone components (AssistanceComponent, ProductNoteComponent, MapPreferencesComponent, ScannerComponent) just need importing into a parent template — no route or module registration needed.
- For modal-style v1 features, v2 uses inline expansion (signal toggle + `@if`) instead of ModalService.

## V2 API Data Wiring Pattern
- Zone-aware components follow a dual path: single-zone agents auto-load on init, multi-zone agents load per-zone on accordion expand.
- Admin role gets a single non-zoned view.
- API calls return keyed objects; last element is often a totals row (pop it off before rendering).

## Italian Number Formatting
- V1 API returns Italian-format currency: dot as thousands separator, comma as decimal (e.g., `1.234,56`).
- Parse with: `str.replace(/\./g, '').replace(',', '.')` then `parseFloat()`.
- CSV export uses semicolon separator and BOM prefix (`\uFEFF`) for European Excel compatibility.

## Build Verification
- `yarn ng build` is the single source of truth. CommonJS warnings are normal and expected.
- Build takes ~6s. Always run after changes.

