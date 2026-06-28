-- ============================================================================
-- Quantos — make the schema's promises REAL (run after 0008)
--
-- Built for scale: invariants the app advertised (plan caps, "every quantity
-- change is logged", an append-only audit trail, no negative stock) were
-- enforced only in the browser. Anyone with the anon key and a membership could
-- bypass them through PostgREST. This migration moves enforcement into the
-- database so the guarantees hold for every writer, no matter the client.
--
--   1. quantity >= 0                       — hard floor, not just a UI check
--   2. updated_at auto-touch               — authoritative on items + assets
--   3. plan caps (items/assets/users)      — enforced on INSERT from the account
--   4. append-only inventory ledger        — history can't be edited or deleted
--   5. quantity only via adjust_item_stock — so every change is truly logged
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. No negative stock at the storage layer.
-- ---------------------------------------------------------------------------
alter table public.items add constraint items_quantity_nonneg check (quantity >= 0);

-- ---------------------------------------------------------------------------
-- 2. updated_at is set by the database, not trusted from the client.
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger items_touch_updated_at  before update on public.items  for each row execute function public.touch_updated_at();
create trigger assets_touch_updated_at before update on public.assets for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Plan caps enforced server-side. The accounts.{item,asset,user}_limit
--    columns (kept in sync with the plan by the Stripe webhook) are now the
--    authority; the browser check is just a friendly pre-flight. Enterprise's
--    1,000,000 sentinel makes the check a no-op for "unlimited".
-- ---------------------------------------------------------------------------
create or replace function public.enforce_account_limit()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_count bigint;
  v_limit int;
  v_col   text := tg_argv[0];
begin
  execute format('select count(*) from %I where account_id = $1', tg_table_name)
    into v_count using new.account_id;
  execute format('select %I from accounts where id = $1', v_col)
    into v_limit using new.account_id;

  if v_limit is not null and v_count >= v_limit then
    raise exception 'Plan limit reached (% of % allowed). Upgrade to add more.', v_count, v_limit
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger items_account_limit       before insert on public.items       for each row execute function public.enforce_account_limit('item_limit');
create trigger assets_account_limit       before insert on public.assets      for each row execute function public.enforce_account_limit('asset_limit');
create trigger memberships_account_limit  before insert on public.memberships for each row execute function public.enforce_account_limit('user_limit');

-- ---------------------------------------------------------------------------
-- 4. The inventory ledger is append-only. Members may add rows (the opening
--    balance and adjust_item_stock both insert) and read them, but the audit
--    history can never be rewritten or deleted — the chain-of-custody guarantee
--    the product sells.
-- ---------------------------------------------------------------------------
drop policy if exists inventory_transactions_all on public.inventory_transactions;

create policy inventory_transactions_select on public.inventory_transactions
  for select using (is_account_member(account_id));
create policy inventory_transactions_insert on public.inventory_transactions
  for insert with check (is_account_member(account_id));
-- (No UPDATE or DELETE policy: with RLS on, those operations are denied.)

-- ---------------------------------------------------------------------------
-- 5. Stock quantity can ONLY move through adjust_item_stock, which writes the
--    audit row in the same transaction. A direct `UPDATE items SET quantity=…`
--    (skipping the log) is now rejected. adjust_item_stock signals the guard
--    with a transaction-local GUC the trigger checks; PostgREST writes never
--    set it. (Item creation still seeds an opening balance — that's the INSERT
--    path, which this BEFORE UPDATE trigger does not touch.)
-- ---------------------------------------------------------------------------
create or replace function public.adjust_item_stock(
  p_item_id uuid,
  p_delta   numeric,
  p_reason  text,
  p_note    text default null,
  p_actor   text default null
) returns numeric
language plpgsql security invoker set search_path = public
as $$
declare v_after numeric; v_acct uuid;
begin
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reason is required for every stock change';
  end if;

  -- Authorize this transaction to move quantity (the guard trigger checks this).
  perform set_config('app.stock_adjust', '1', true);

  -- RLS still applies (security invoker): the UPDATE only touches a row in an
  -- account the caller is a member of; otherwise 0 rows -> v_acct stays null.
  update items
     set quantity = quantity + p_delta, updated_at = now()
   where id = p_item_id
   returning quantity, account_id into v_after, v_acct;

  if v_acct is null then raise exception 'Item not found'; end if;
  if v_after < 0 then raise exception 'Insufficient stock for this change'; end if;

  insert into inventory_transactions
    (account_id, item_id, user_id, actor_name, delta, qty_after, reason, note)
  values
    (v_acct, p_item_id, auth.uid(), p_actor, p_delta, v_after, btrim(p_reason), p_note);

  return v_after;
end;
$$;
revoke execute on function public.adjust_item_stock(uuid, numeric, text, text, text) from public;  -- not anon
grant  execute on function public.adjust_item_stock(uuid, numeric, text, text, text) to authenticated;

create or replace function public.guard_item_quantity()
returns trigger language plpgsql as $$
begin
  if new.quantity is distinct from old.quantity
     and coalesce(current_setting('app.stock_adjust', true), '') <> '1' then
    raise exception 'Stock quantity can only be changed via adjust_item_stock, so every change is logged';
  end if;
  return new;
end;
$$;
create trigger items_guard_quantity before update on public.items for each row execute function public.guard_item_quantity();
