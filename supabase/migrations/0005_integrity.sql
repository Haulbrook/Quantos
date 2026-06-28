-- ============================================================================
-- Quantos — integrity hardening
--   1. adjust_item_stock(): make a stock change and its audit-log row ATOMIC.
--      A plpgsql function body is one transaction, so if the transaction insert
--      fails (e.g. blank reason), the quantity change rolls back too. This makes
--      the "every quantity change is logged with a reason" invariant real, not
--      just UI-enforced, for the +/- adjust path.
--   2. One open checkout per asset — a partial unique index that backstops the
--      app-layer availability check against races / stale modals.
-- ============================================================================

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
grant execute on function public.adjust_item_stock(uuid, numeric, text, text, text) to authenticated;

-- An asset can have at most one OPEN checkout at a time. A second concurrent
-- "out" insert fails hard instead of silently double-booking the asset.
create unique index if not exists checkouts_one_open_per_asset
  on checkouts (asset_id) where status = 'out';
