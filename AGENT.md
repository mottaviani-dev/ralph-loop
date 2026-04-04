# AGENT.md — Gap Resolution Worker

## Mission

Read documentation alphabetically files in `../docs/`, understand the v1 business logic described there, review implementation in v1 ng-sir, then port ALL missing functionality to v2 in a single pass per doc file according to the new architecture.

## Cycle Workflow

Each cycle targets ONE documentation file and resolves ALL its gaps:

1. **Pick a doc file alphabetically** — check journal for already-processed files, pick the next unprocessed one from `../docs/concepts/`
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

Work through `../docs/**/*.md` alphabetically. Look for gaps and incomplete features in it. After all concepts, process `../docs/reference/` and `../docs/guides/`.

**DO NOT** declare the task complete. This is a recurring loop.

## Current Status (cycle 29, 2026-04-04)

**Doc scanning complete**: All 66 `docs/concepts/` files processed. Zero `:::warning` blocks remain.

**Resolved in cycles 1-28**: 6 orphaned components wired, all `alert()` calls replaced, CSV export added to reports, commissions/orders-status/reports APIs wired, balance/bill-detail features completed, SEO metadata added, promo dismissal persistence, note form toggles, Phase 2 auth forms (register + reset password), customer form dialog (new/update/notify via MatDialog), lead preview dialog.

**Remaining actionable items** (priority order):
1. ~~`openCustomerFormNew()` dialog~~ — **Resolved** (cycle #27).
2. ~~`previewLead()` dialog~~ — **Resolved** (cycle #28).
3. `addCustomer()` dialog — `my-customers.component.ts:186` — **RESEARCHED** (cycle #29). Ready for implementation next cycle.
4. Support table Material upgrade — sort, filter, pagination, expandable rows

### addCustomer() Implementation Plan (from cycle 29 research)

**New file**: `src/app/features/account/my-customers/customer-lead-form.component.ts`
**Opens via**: `MatDialog` from `my-customers.component.ts:addCustomer()`

**Data structure** (3 sections, matches v1 API shape):
- `basic`: name, address, birth, zip, city, province, fiscal_id, vat, rea, phone, mobile, sdi, zone (select if multi-zone), agent (auto-filled), email, web, password (16 fields)
- `business`: activity_type, payment, bank, bank_city, iban, shipping, transportation, closure (7 selects from `getCustomerLeadLabels()` + 2 text fields), shipping_address[] (name, address, city, zip, province)
- `internal`: ass_fcs (select), giro (select), v, f, r, date, note (7 fields — 2 selects, 5 text)

**Label API** (`getCustomerLeadLabels()`): Returns 8 arrays — `activity_type`, `payment_type`, `bank_type`, `shipping_type`, `transportation_type`, `closure_type`, `ass_fcs_type`, `giro_type`. Each item has `{id, name}`. V1 pre-selects `[0].id` from each on load.

**API methods** (all exist in v2 AccountService):
- `sendCustomerLead(lead)` — create/update
- `getCustomerLeads()` — list existing leads
- `getCustomerLead(id)` — load for edit
- `deleteCustomerLead(id)` — delete with confirm
- `getCustomerLeadLabels()` — dropdown options

**V2 patterns**: standalone, ReactiveFormsModule, signals, inject(), OnPush, MatDialog, `@if`/`@for`.

**Existing leads list**: V1 shows previously submitted leads at top with edit/delete buttons. Include in dialog.

**Architectural items** (tracked in pending-work.md, lower priority):
- Typed interfaces for Customer, Destination, User
- `signal<any>` cleanup in CartService/AccountService
- Dark mode, theming, config validation

<!-- Last updated: cycle 29, 2026-04-04 -->
