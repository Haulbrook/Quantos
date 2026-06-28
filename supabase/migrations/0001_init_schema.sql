-- ============================================================================
-- Quantos — Phase 0 schema
-- Asset inventory & checkout platform. Multi-tenant: every domain row is keyed
-- by account_id. RLS lives in 0002.
--
-- Three modules:
--   1. Inventory Tracker  -> locations, items, inventory_transactions
--   2. Asset Checkout     -> assets, checkouts, asset_requests, loss_events
--   3. Reports            -> derived from the above (+ convenience views)
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- TENANCY
-- ---------------------------------------------------------------------------
create table accounts (
  id                     uuid primary key default gen_random_uuid(),
  name                   text not null,
  plan                   text not null default 'starter'
                           check (plan in ('starter','pro','enterprise')),
  status                 text not null default 'trialing'
                           check (status in ('trialing','active','past_due','canceled')),
  -- Per-tier caps (enterprise uses a high sentinel; see packages/entitlements).
  item_limit             int  not null default 200,
  asset_limit            int  not null default 50,
  user_limit             int  not null default 5,
  stripe_customer_id     text unique,
  stripe_subscription_id text unique,
  trial_ends_at          timestamptz,
  created_at             timestamptz not null default now()
);

-- App users live in Supabase auth.users; we mirror membership + role here.
create table memberships (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('owner','manager','staff')),
  created_at timestamptz not null default now(),
  unique (account_id, user_id)
);
create index on memberships (user_id);
create index on memberships (account_id);

-- Stripe idempotency ledger (the webhook claims each event id before processing).
create table stripe_events (
  id          text primary key,
  type        text,
  received_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- LOCATIONS — shared by inventory items and checkout-able assets
-- ---------------------------------------------------------------------------
create table locations (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references accounts(id) on delete cascade,
  name        text not null,
  description text,
  created_at  timestamptz not null default now(),
  unique (account_id, name)
);
create index on locations (account_id);

-- ===========================================================================
-- MODULE 1 — INVENTORY TRACKER
-- ===========================================================================

-- Stock-keeping items with MIN/MAX auto-reorder levels.
create table items (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references accounts(id) on delete cascade,
  sku         text,                                  -- optional human code
  name        text not null,
  description text,
  category    text,
  tags        text[] not null default '{}',
  location_id uuid references locations(id) on delete set null,
  quantity    numeric not null default 0,
  min_level   numeric not null default 0 check (min_level >= 0),  -- reorder trigger
  max_level   numeric not null default 0 check (max_level >= 0),  -- reorder target
  unit_cost   numeric,
  photo_url   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (account_id, sku),                          -- nulls are distinct, so blank SKUs are fine
  check (max_level = 0 or max_level >= min_level)
);
create index on items (account_id);
create index on items (account_id, category);
create index on items (account_id, location_id);

-- Transaction audit log — EVERY quantity change is logged with a REQUIRED reason.
-- The reason can never be blank (enforced here AND in the UI). delta is the
-- signed change (+added / -removed); qty_after snapshots the resulting quantity.
create table inventory_transactions (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references accounts(id) on delete cascade,
  item_id     uuid not null references items(id) on delete cascade,
  user_id     uuid references auth.users(id),
  actor_name  text,                                  -- denormalized for the ledger
  delta       numeric not null,
  qty_after   numeric not null,
  reason      text not null check (length(btrim(reason)) > 0),  -- REQUIRED — never blank
  note        text,
  created_at  timestamptz not null default now()
);
create index on inventory_transactions (account_id);
create index on inventory_transactions (item_id);
create index on inventory_transactions (account_id, created_at);

-- ===========================================================================
-- MODULE 2 — ASSET CHECKOUT
-- ===========================================================================

-- Trackable assets (one physical thing, checked out to one person at a time).
create table assets (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references accounts(id) on delete cascade,
  asset_tag   text,                                  -- optional human tag
  name        text not null,
  description text,
  category    text,
  location_id uuid references locations(id) on delete set null,
  condition   text not null default 'good'
                check (condition in ('new','good','fair','poor','damaged','retired')),
  status      text not null default 'available'
                check (status in ('available','checked_out','lost','maintenance','retired')),
  value       numeric,
  photo_url   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (account_id, asset_tag)
);
create index on assets (account_id);
create index on assets (account_id, status);

-- Checkout ledger — open rows (status='out') ARE the live possession ledger;
-- the full table is the chain of custody (per asset AND per person).
create table checkouts (
  id                 uuid primary key default gen_random_uuid(),
  account_id         uuid not null references accounts(id) on delete cascade,
  asset_id           uuid not null references assets(id) on delete cascade,
  person_name        text not null,                  -- who has it
  person_email       text,
  location           text,                           -- where it's going
  checked_out_by     uuid references auth.users(id),
  checked_out_by_name text,
  checked_out_at     timestamptz not null default now(),
  expected_return_at date,                            -- overdue when past & not returned
  returned_at        timestamptz,
  return_condition   text check (return_condition in ('new','good','fair','poor','damaged','retired')),
  return_notes       text,
  return_photo_url   text,
  status             text not null default 'out' check (status in ('out','returned')),
  created_at         timestamptz not null default now()
);
create index on checkouts (account_id);
create index on checkouts (asset_id);
create index on checkouts (account_id, status);
create index on checkouts (account_id, person_name);

-- Request tickets — stack up when an asset is unavailable. Count = purchasing
-- signal; oldest open request is notified first when an asset frees up.
create table asset_requests (
  id                 uuid primary key default gen_random_uuid(),
  account_id         uuid not null references accounts(id) on delete cascade,
  asset_id           uuid references assets(id) on delete set null,  -- a specific asset, if known
  item_name          text not null,                  -- what they need (free text otherwise)
  requested_by_name  text not null,
  requested_by_email text,
  needed_by          date,
  urgency            text not null default 'normal'
                       check (urgency in ('low','normal','high','critical')),
  note               text,
  status             text not null default 'open'
                       check (status in ('open','fulfilled','cancelled')),
  fulfilled_at       timestamptz,
  created_at         timestamptz not null default now()
);
create index on asset_requests (account_id);
create index on asset_requests (account_id, status);

-- Loss / shrinkage events — category AND note are BOTH required (no blank loss
-- records), enforced here AND in the UI.
create table loss_events (
  id                uuid primary key default gen_random_uuid(),
  account_id        uuid not null references accounts(id) on delete cascade,
  asset_id          uuid references assets(id) on delete set null,
  item_id           uuid references items(id) on delete set null,
  subject_name      text not null,                   -- denormalized asset/item name for history
  category          text not null
                      check (category in ('lost','broken','misuse','stolen','wear_and_tear','other')),
  note              text not null check (length(btrim(note)) > 0),  -- REQUIRED — never blank
  cost_impact       numeric,
  person_responsible text,
  reported_by       uuid references auth.users(id),
  reported_by_name  text,
  created_at        timestamptz not null default now()
);
create index on loss_events (account_id);
create index on loss_events (account_id, created_at);

-- ---------------------------------------------------------------------------
-- CONVENIENCE VIEWS (security_invoker so the caller's RLS applies)
-- ---------------------------------------------------------------------------

-- Items at/below their reorder point, with how many to order to reach max.
create view item_reorder as
select
  i.*,
  l.name as location_name,
  greatest(i.max_level - i.quantity, 0) as reorder_qty
from items i
left join locations l on l.id = i.location_id
where i.quantity <= i.min_level;

-- Live possession ledger — who currently has what.
create view current_possession as
select
  c.id, c.account_id, c.asset_id, c.person_name, c.person_email, c.location,
  c.checked_out_at, c.expected_return_at, c.checked_out_by_name,
  a.name as asset_name, a.asset_tag, a.category as asset_category,
  (c.expected_return_at is not null and c.expected_return_at < current_date) as overdue
from checkouts c
join assets a on a.id = c.asset_id
where c.status = 'out';

alter view item_reorder        set (security_invoker = on);
alter view current_possession  set (security_invoker = on);
