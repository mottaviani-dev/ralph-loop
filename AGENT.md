# AGENT.md — Gap Resolution Worker

## Mission

Read documentation files in `../docs/`, understand the v1 business logic described there, then port ALL missing functionality to v2 in a single pass per doc file.

## Cycle Workflow

Each cycle targets ONE documentation file and resolves ALL its gaps:

1. **Pick a doc file** — check journal for already-processed files, pick the next unprocessed one from `../docs/concepts/`
2. **Read the doc thoroughly** — understand the full feature as documented (v1 behavior, API calls, data flow, edge cases)
3. **Read the v1 source code** referenced in the doc — understand HOW it actually works, not just what the doc says
4. **Read the corresponding v2 code** — understand what's already implemented and what's missing
5. **Implement ALL gaps for that feature in v2** — port the v1 logic following v2 patterns (standalone components, signals, inject(), OnPush)
6. **Run `cd .. && yarn ng build`** to verify everything compiles
7. **Update the doc file** — mark all resolved gaps as `:::tip Resolved`, track complex ones as `:::info Tracked`
8. **Record in journal** — which file, how many gaps resolved, how many tracked, files modified

## V2 Architecture Patterns

When porting from v1, follow these v2 patterns:

- **Services**: Use `inject()`, `signal()`, `computed()`. NOT constructor injection or BehaviorSubject.
- **Components**: `standalone: true`, `ChangeDetectionStrategy.OnPush`, `@if`/`@for` control flow. NOT NgModule, NOT *ngIf/*ngFor.
- **Forms**: ReactiveFormsModule with typed FormGroup. NOT template-driven.
- **HTTP**: Return Observable from service, subscribe in component, update signal with result.
- **Dialogs**: Use `MatDialog` / CDK Dialog. NOT a shared ModalService with Subjects.
- **State**: Signals for component state, services for shared state. NOT manual ChangeDetectorRef.markForCheck().

## Rules

- **ONE doc file per cycle, ALL gaps in that file** — don't cherry-pick individual gaps across files.
- **Read v1 code BEFORE implementing** — the doc describes behavior, but the v1 source has the actual implementation details, edge cases, and calculations you need.
- **You MAY edit `.md` files in `../docs/`** but ONLY to mark gaps as resolved/tracked. Do not rewrite documentation content.
- **DO NOT create new documentation files.**
- **Build MUST pass** — run `cd .. && yarn ng build` after all changes. If it fails, fix it before finishing the cycle.

## Marking Gaps in Docs

**Resolved** (you fixed it in code):
```markdown
:::tip Resolved
~~Original gap description here.~~
Fixed in cycle #N — brief description of what was implemented.
:::
```

**Tracked** (needs architecture decision, appended to pending-work.md):
```markdown
:::info Tracked
~~Original gap description here.~~
Requires architecture decision. See [pending-work.md](/reference/pending-work).
:::
```

## What to Fix vs Track

**Fix directly** (port from v1):
- Service methods that are stubs or empty
- Component logic that's missing (event handlers, data loading, calculations)
- Missing API calls that the doc describes
- Template features missing (conditional UI, role-based visibility)
- CSS/styling gaps
- Missing imports, routes, or wiring

**Track in pending-work.md** (don't fix):
- Features requiring entirely new components that don't exist yet
- Changes to the API backend
- Features requiring new packages/dependencies not yet installed
- Architectural redesigns (e.g., "v1 uses jQuery for this, v2 needs a completely different approach")

## pending-work.md Format

```markdown
### [Category] — [Brief description]

**Source**: docs/concepts/[filename].md
**V1 behavior**: [what v1 does]
**V2 status**: [current state]
**Effort**: Small / Medium / Large
**Needs**: [what's required]
```

## Source Code Locations

- V2 source: `../src/app/`
- V1 reference: `../../ng-sir/src/app/` (read-only)
- Build: `cd .. && yarn ng build`

## File Processing Order

Work through `../docs/concepts/` alphabetically. Skip files with no `:::warning` blocks. After all concepts, process `../docs/reference/` and `../docs/guides/`.

After completing all files, re-scan for newly created docs by the discovery loop: `git log --oneline -10 -- ../docs/`

**DO NOT** declare the task complete. This is a recurring loop.

## Current Status (cycle 26, 2026-04-04)

**Doc scanning complete**: All 66 `docs/concepts/` files processed. Zero `:::warning` blocks remain.

**Resolved in cycles 1-25**: 6 orphaned components wired, all `alert()` calls replaced, CSV export added to reports, commissions/orders-status/reports APIs wired, balance/bill-detail features completed, SEO metadata added, promo dismissal persistence, note form toggles, Phase 2 auth forms (register + reset password).

**Remaining actionable items** (priority order — updated after cycle 26 RESEARCH):
1. `openCustomerFormNew()` dialog — `all-customers.component.ts:117` — **EASIEST**: v2 `CustomerFormComponent` already exists at `shared/components/customer-form/`. Just wrap in `MatDialog.open()` passing `customer` and `mode:'new'` as data.
2. `previewLead()` dialog — `leads.component.ts:165` — **MEDIUM**: Create read-only lead preview component (customer details, shop details, shipping/payment method, order cart table with totals). Uses `CartService.getLead(email, id)` which already exists.
3. `addCustomer()` dialog — `my-customers.component.ts:186` — **LARGEST**: Create new `CustomerLeadFormComponent` with 3 sections (basic: 16 fields, commercial: 7 select dropdowns + shipping addresses, internal: 7 fields). All 5 API methods exist in v2 AccountService (`sendCustomerLead`, `getCustomerLeads`, `getCustomerLead`, `deleteCustomerLead`, `getCustomerLeadLabels`). V1 loads label options (activity_type, payment_type, bank_type, shipping_type, transportation_type, closure_type, ass_fcs_type, giro_type) on init and pre-selects first option.
4. Support table Material upgrade — sort, filter, pagination, expandable rows

**Architectural items** (tracked in pending-work.md, lower priority):
- Typed interfaces for Customer, Destination, User
- `signal<any>` cleanup in CartService/AccountService
- Dark mode, theming, config validation

<!-- Last updated: cycle 26, 2026-04-04 -->
