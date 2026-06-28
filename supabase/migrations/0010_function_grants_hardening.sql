-- ============================================================================
-- Quantos — function grants & search_path hardening (advisor follow-up to 0007–0009)
--
-- The security advisor flagged the functions added in 0007–0009. Two real fixes:
--
--   1. touch_updated_at() and guard_item_quantity() were created without a pinned
--      search_path (mutable search_path is a privilege-escalation vector). Pin it.
--
--   2. Supabase's default privileges GRANT EXECUTE to anon + authenticated on every
--      new function, so the earlier `revoke ... from public` did not remove anon's
--      access. Revoke from anon explicitly. Trigger functions are never invoked as
--      RPCs (verified: a trigger fires regardless of the caller's EXECUTE privilege),
--      so they're revoked from every client role and disappear from the REST API.
--      The genuine RPCs stay callable by `authenticated` only.
-- ============================================================================

-- 1. Pin search_path on the two trigger functions that were missing it.
create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.guard_item_quantity()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.quantity is distinct from old.quantity
     and coalesce(current_setting('app.stock_adjust', true), '') <> '1' then
    raise exception 'Stock quantity can only be changed via adjust_item_stock, so every change is logged';
  end if;
  return new;
end;
$$;

-- 2. Trigger functions are never called as RPCs — revoke EXECUTE from all client roles.
revoke execute on function public.touch_updated_at()      from public, anon, authenticated;
revoke execute on function public.guard_item_quantity()   from public, anon, authenticated;
revoke execute on function public.enforce_account_limit() from public, anon, authenticated;

-- 3. The real RPCs are for signed-in users only — lock anon out explicitly,
--    keep authenticated.
revoke execute on function public.set_member_role(uuid, uuid, text)                               from public, anon;
revoke execute on function public.remove_member(uuid, uuid)                                       from public, anon;
revoke execute on function public.check_in_asset(uuid, text, text, text)                          from public, anon;
revoke execute on function public.report_loss(uuid, uuid, text, text, text, numeric, text, text)  from public, anon;
revoke execute on function public.adjust_item_stock(uuid, numeric, text, text, text)             from public, anon;

grant execute on function public.set_member_role(uuid, uuid, text)                               to authenticated;
grant execute on function public.remove_member(uuid, uuid)                                       to authenticated;
grant execute on function public.check_in_asset(uuid, text, text, text)                          to authenticated;
grant execute on function public.report_loss(uuid, uuid, text, text, text, numeric, text, text)  to authenticated;
grant execute on function public.adjust_item_stock(uuid, numeric, text, text, text)             to authenticated;
