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

## Current Status (cycle 30, 2026-04-04)

**Doc scanning complete**: All 66 `docs/concepts/` files processed. Zero `:::warning` blocks remain.

**Resolved in cycles 1-30**: 6 orphaned components wired, all `alert()` calls replaced, CSV export added to reports, commissions/orders-status/reports APIs wired, balance/bill-detail features completed, SEO metadata added, promo dismissal persistence, note form toggles, Phase 2 auth forms (register + reset password), customer form dialog (new/update/notify via MatDialog), lead preview dialog, customer lead form dialog.

**All TODO stubs resolved.** Zero `/* TODO */` method stubs remain in the codebase.

**Remaining actionable items** (priority order):
1. ~~`openCustomerFormNew()` dialog~~ — **Resolved** (cycle #27).
2. ~~`previewLead()` dialog~~ — **Resolved** (cycle #28).
3. ~~`addCustomer()` dialog~~ — **Resolved** (cycle #30). CustomerLeadFormComponent with 3-section reactive form, existing leads list, 8 label dropdowns.
4. **Support table Material upgrade** — NEXT (researched cycle #34, implement cycle #35)

### Support Table Implementation Plan (cycle #34 research)

**File**: `src/app/features/account/support-requests/support-requests.component.ts`

**Current state**: Simple `@for` loop with `div.support-item`, 3 fields only. Material modules imported but unused.

**Target**: Match v1's `SupportTableComponent` using v2 patterns.

**Changes needed**:
1. Replace `@for` loops with `mat-table` + `MatTableDataSource` (one per tab)
2. Add `viewChild` signals for `MatSort` and `MatPaginator` (one set per tab, or switch datasource on tab change)
3. **Columns**: expand toggle, `support_type`, `ref_num`, `date`, `product_name`, `credit_memo`, `bill`
4. **Support type labels**: map 0-5 → Italian strings via translate pipe (Assistenza - Da inviare/Inviata/Rientrato, Sostituzione, Mancante, Nota Credito)
5. **Text filter**: `mat-form-field` input → `dataSource.filter`
6. **Expandable rows**: `@detailExpand` animation, load detail via `AccountService.getSupportDetail(customer, refNum.substring(0, 5))`
7. **Default sort**: date desc, custom `sortingDataAccessor` for `dd/mm/yy` → Date
8. **Bill link**: navigate to bill detail or open in new tab
9. **Detail grid**: two-column key-value layout from indexed array (positions 0-39)
10. **Paginator**: `[25, 50, 100]` page size options

**V2 patterns to follow**: `viewChild.required()` for sort/paginator, `signal()` for expanded element, `@if`/`@for` control flow (already used), `inject()` (already used).

**API methods available**: `getSupports()`, `getSupportsCompleted()`, `getSupportDetail()` — all exist in AccountService.

**Architectural items** (tracked in pending-work.md, lower priority):
- Typed interfaces for Customer, Destination, User
- `signal<any>` cleanup in CartService/AccountService
- Dark mode, theming, config validation

<!-- Last updated: cycle 34, 2026-04-04 -->
