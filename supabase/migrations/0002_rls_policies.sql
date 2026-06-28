-- ============================================================================
-- Quantos — Phase 0 Row-Level Security
-- Tenant isolation: a row is visible/writable only to members of its account.
-- ============================================================================

-- Helper functions are SECURITY DEFINER so they read memberships without
-- tripping the policies that themselves call these helpers (no recursion).
create or replace function public.is_account_member(a uuid)
returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from memberships m
    where m.account_id = a and m.user_id = auth.uid()
  );
$$;

create or replace function public.has_account_role(a uuid, roles text[])
returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from memberships m
    where m.account_id = a and m.user_id = auth.uid() and m.role = any(roles)
  );
$$;

-- ---------------------------------------------------------------------------
-- Enable RLS everywhere
-- ---------------------------------------------------------------------------
alter table accounts               enable row level security;
alter table memberships            enable row level security;
alter table locations              enable row level security;
alter table items                  enable row level security;
alter table inventory_transactions enable row level security;
alter table assets                 enable row level security;
alter table checkouts              enable row level security;
alter table asset_requests         enable row level security;
alter table loss_events            enable row level security;

-- ---------------------------------------------------------------------------
-- accounts: members read; owners update. (Insert happens via the signup RPC.)
-- ---------------------------------------------------------------------------
create policy accounts_select on accounts
  for select using (is_account_member(id));
create policy accounts_update on accounts
  for update using (has_account_role(id, array['owner']))
  with check (has_account_role(id, array['owner']));

-- ---------------------------------------------------------------------------
-- memberships: members read the roster; owner/manager manage it.
-- ---------------------------------------------------------------------------
create policy memberships_select on memberships
  for select using (is_account_member(account_id));
create policy memberships_write on memberships
  for all using (has_account_role(account_id, array['owner','manager']))
  with check (has_account_role(account_id, array['owner','manager']));

-- ---------------------------------------------------------------------------
-- Domain tables: any account member may read & write within their own account.
-- (Loss/transaction NOT-NULL + non-blank checks live on the tables themselves,
--  so the "no blank record" rule holds for every writer regardless of role.)
-- ---------------------------------------------------------------------------
create policy locations_all on locations
  for all using (is_account_member(account_id)) with check (is_account_member(account_id));

create policy items_all on items
  for all using (is_account_member(account_id)) with check (is_account_member(account_id));

create policy inventory_transactions_all on inventory_transactions
  for all using (is_account_member(account_id)) with check (is_account_member(account_id));

create policy assets_all on assets
  for all using (is_account_member(account_id)) with check (is_account_member(account_id));

create policy checkouts_all on checkouts
  for all using (is_account_member(account_id)) with check (is_account_member(account_id));

create policy asset_requests_all on asset_requests
  for all using (is_account_member(account_id)) with check (is_account_member(account_id));

create policy loss_events_all on loss_events
  for all using (is_account_member(account_id)) with check (is_account_member(account_id));
