# Quantos

**Asset inventory & checkout platform.** Know what you have, know who has it.

Three modules in one fast, mobile-friendly single-page app:

1. **Inventory Tracker** — search/filter/paginate items, min/max auto-reorder
   alerts, a transaction audit log with a **required reason on every change**,
   photos, and CSV/PDF export.
2. **Asset Checkout** — check assets out to people, a live possession ledger,
   overdue alerts, full chain of custody, bulk checkout, **request tickets** (a
   purchasing signal), and **loss tracking** where a category *and* a note are
   required (no blank loss records — enforced in the UI *and* the database).
3. **Reports** — most checked-out, most-requested (with avg wait), loss &
   shrinkage with monthly trend, inventory health, checkout activity, an
   auto-generated monthly report, and CSV/PDF export.

No QR codes. No barcodes. No TV display mode.

## Stack

| Layer     | Tech                                            |
|-----------|-------------------------------------------------|
| Frontend  | Vanilla HTML/CSS/JS — one `apps/index.html` SPA |
| Backend   | Netlify Functions (serverless, CommonJS)        |
| Database  | Supabase (PostgreSQL + Row-Level Security)      |
| Auth      | Supabase Auth                                   |
| Billing   | Stripe (stubbed until price IDs are configured) |

## Layout

```
quantos/
├── apps/                  # publish dir (static)
│   ├── index.html         # the SPA: auth + Inventory + Checkout + Reports + Settings
│   ├── landing.html       # marketing page (served at /)
│   ├── llms.txt
│   └── assets/favicon.svg
├── netlify/functions/     # serverless (Stripe billing) + lib/ helpers
├── packages/entitlements/ # plan definitions (single source of truth)
├── supabase/migrations/   # schema, RLS, onboarding RPCs, storage
├── netlify.toml           # routing (/ → landing, /app → SPA) + security headers
└── .env.example
```

## Setup

### 1. Supabase
1. Create a project at [supabase.com](https://supabase.com).
2. Run the SQL in `supabase/migrations/` in order (`0001` → `0004`) via the
   SQL editor, or `supabase db reset` with the CLI.
3. In **apps/index.html**, set the `SUPABASE_URL` and `SUPABASE_ANON_KEY`
   constants near the top of the `<script type="module">` block.

### 2. Run locally
```bash
npm install
npm run dev        # netlify dev → http://localhost:8888
```
Open `http://localhost:8888`, click **Sign in → Create org**, and you're in.
(Disable email confirmation in Supabase Auth settings for the smoothest local
signup, or confirm the address before signing in.)

### 3. Billing (optional — stubbed by default)
Billing returns a friendly "not configured yet" notice until you:
1. Create Starter/Pro/Enterprise products + prices in Stripe.
2. Set the `STRIPE_*` and `SUPABASE_SERVICE_ROLE_KEY` env vars (see
   `.env.example`) in Netlify / your `.env`.
3. Point a Stripe webhook at `/.netlify/functions/stripe-webhook`.

## Pricing tiers (stub)

| Plan       | Price    | Items     | Assets    | Users     |
|------------|----------|-----------|-----------|-----------|
| Starter    | $49/mo   | 200       | 50        | 5         |
| Pro        | $99/mo   | 1,000     | 250       | 25        |
| Enterprise | $199/mo  | Unlimited | Unlimited | Unlimited |

All three modules ship on every plan; tiers only raise the caps.

## Data model & tenancy

Every domain row is keyed by `account_id` and isolated by RLS — a row is
visible/writable only to members of its account. New users bootstrap an account
through the `create_account_for_current_user()` RPC (owner role + a default
location). The two "no blank record" rules are enforced by **database CHECK
constraints**, not just the UI:

- `inventory_transactions.reason` — `NOT NULL` and non-blank.
- `loss_events.category` + `loss_events.note` — `NOT NULL`, note non-blank.

## Design

Dark theme · accent `#9a88f0` · background `#0f1117` · card `#1a1d27`.
Single-page app with view switching; responsive down to phone widths.
