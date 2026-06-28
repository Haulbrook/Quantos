# Quantos — Build Notes

Fresh standalone build. Architecture patterns (proxy/serverless billing, Supabase
auth, multi-tenant RLS, plan tiers, single-page app) are modeled on the Mechantix
project; **no code was copied** — Quantos is written from scratch.

## What's built (v0.1.0)

### Frontend — `apps/index.html` (single-page app, view switching)
- **Auth**: Supabase email/password, sign in + create-org, `onAuthStateChange`.
- **Inventory**: search/category/location filters + "reorder only", reorder
  banner, paginated table (20/page), add/edit item (+photo upload), +/- adjust
  with **required reason** → writes `inventory_transactions`, transaction log
  viewer, CSV + PDF(print) export.
- **Checkout**: 4 sub-tabs.
  - *Possession ledger* — live who-has-what, overdue alert, check-in (condition,
    notes, return photo) that notifies the first-in-line requester.
  - *Assets* — add/edit asset (+photo), check out (single **and bulk**), per-asset
    history (chain of custody), per-asset loss.
  - *Requests* — submit request ticket (urgency), ranked "purchasing signal" +
    oldest-first open list with wait time, fulfill/cancel.
  - *Loss & shrinkage* — report loss with **required category + note** (blocked in
    UI and DB), totals + cost impact.
- **Reports**: date range + 30/90d presets + monthly generator. Inventory health,
  most checked-out, most-requested (avg wait), loss & shrinkage (by category +
  monthly trend), checkout activity (busiest day, top users). CSV + PDF export.
- **Settings**: locations CRUD, plan & billing (Stripe stub), team roster + roles.

### Backend — `netlify/functions/`
- `create-checkout-session`, `create-portal-session`, `stripe-webhook` (CJS),
  lazy-init after a config guard so an unconfigured deploy returns a clean 503.
- `lib/auth.js` (CORS/getUser/hasAccountRole), `lib/plans.js` (caps + price env).

### Database — `supabase/migrations/`
- `0001` schema: accounts, memberships, stripe_events, locations, items,
  inventory_transactions, assets, checkouts, asset_requests, loss_events + two
  `security_invoker` views (`item_reorder`, `current_possession`).
- `0002` RLS: `is_account_member`/`has_account_role` helpers + per-table policies.
- `0003` onboarding RPCs: `create_account_for_current_user`, `list_account_members`.
- `0004` storage: public `quantos-photos` bucket + object policies.
- **Hard constraints**: `inventory_transactions.reason` non-blank;
  `loss_events.category` + `note` non-blank.

## Live deployment (done)
- Pushed to GitHub: **https://github.com/Haulbrook/Quantos** (public).
- Frontend wired to Supabase project `egcdmmtqcrrpqszpiwgf` (URL + publishable
  anon key set in `apps/index.html`; anon key is browser-safe under RLS).
- All **6 migrations applied** to the live project (`0001`→`0006`); 10 tables,
  RLS on all tenant tables, helper fns, onboarding + stock RPCs, storage bucket.
- Security advisor: clean. `stripe_events` is RLS-enabled with no policies
  (service-role-only by design → INFO, not a finding); bucket-listing resolved
  (`0006`). Remaining warnings are `SECURITY DEFINER` RPCs that self-scope to
  `auth.uid()` and reveal nothing the caller doesn't already know — left as-is
  on purpose (touching their grants would break RLS for no security gain).
- Smoke-tested live: anon REST reads return `[]` (RLS denies), onboarding RPC
  rejects unauthenticated calls.

### Remaining manual step
- **Auth email confirmation:** Supabase confirms emails on signup by default. The
  app handles that flow (it tells the user to confirm, then sign in). For
  frictionless testing, toggle **Authentication → Sign In / Providers → Email →
  Confirm email** off in the dashboard. (No API tool was available to change this
  for you.)
- **Stripe (optional):** add the `STRIPE_*` env vars to flip billing from stub →
  live; until then checkout shows a friendly "not configured" notice.

## Deliberately out of scope
QR codes, barcodes, TV display mode (excluded per spec). Email invites, finer
per-role write restrictions, and offline mode are future work.

## Hardening pass (post-build adversarial review)

A 7-dimension multi-agent review (each finding re-verified by an independent
skeptic) surfaced 15 confirmed issues; all were fixed:

**High**
- *Storage cross-tenant writes* — `0004_storage.sql` insert/update/delete policies
  now require `is_account_member((storage.foldername(name))[1]::uuid)`, so a user
  can only touch photos under their own account folder (was bucket_id-only).
- *Audit-log bypass on item edit* — the On-hand field is now read-only when
  editing; quantity is only written on create (with an "Opening balance" ledger
  row). All later changes go through the `+/−` path.
- *Non-atomic stock adjust* — replaced the two client writes with an atomic
  `adjust_item_stock()` RPC (`0005_integrity.sql`); a failed audit insert now
  rolls back the quantity change.

**Medium**
- *Checkout race / double-book* — checkout now claims assets with a
  status-guarded update and only writes ledger rows for assets actually won
  (rolls back on failure); backstopped by a partial unique index
  `checkouts_one_open_per_asset`.
- *Dangling open checkout on loss* — reporting a checked-out asset lost now also
  closes its open checkout row.
- *Bulk-checkout error swallowing* — the asset-update error is captured and
  surfaced (folded into the claim-then-insert flow above).

**Low**
- Overdue check uses local date (was UTC, off-by-one near midnight).
- One `isLow()` predicate shared by badge / filter / banner / SQL view; banner &
  badge no longer say "order 0".
- Purchasing-signal grouping keys on `asset_id` when linked, else a trimmed name.
- `list_account_members(p_account_id)` is scoped to one validated account (was
  all of the caller's accounts) — prevents a merged roster / inflated seat count.
- Inventory filter listener registered once (was 4×), and on `change` too.

Public photo *read* is intentionally left open (bucket is public; UUID-prefixed
paths) — documented in `0004_storage.sql` with the private-bucket + signed-URL
alternative if stricter confidentiality is wanted.

## Verification done
- `node --check` passes on all functions, lib, and entitlements.
- Inline SPA module parses cleanly as ESM after all edits.
- Every `$('id')` reference still resolves to a matching `id="…"`.
- App + landing re-rendered in preview with zero console errors.
- Not pushed to GitHub (local `git init` only, per instructions).
