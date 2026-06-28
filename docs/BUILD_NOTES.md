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

## Config the user must set
1. `apps/index.html` → `SUPABASE_URL` + `SUPABASE_ANON_KEY` constants.
2. Run the 4 migrations in the Supabase SQL editor (or `supabase db reset`).
3. (Optional) Stripe env vars to switch billing from stub → live.

## Deliberately out of scope
QR codes, barcodes, TV display mode (excluded per spec). Email invites, finer
per-role write restrictions, and offline mode are future work.

## Verification done
- `node --check` passes on all functions, lib, and entitlements.
- Inline SPA module (~64k chars) parses cleanly as ESM.
- All 87 `$('id')` references have matching `id="…"` definitions.
- Not pushed to GitHub (local `git init` only, per instructions).
