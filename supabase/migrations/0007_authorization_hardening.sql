-- ============================================================================
-- Quantos — authorization hardening (run after 0001–0006)
--
-- Closes two privilege-escalation holes that were reachable directly through
-- PostgREST with the anon key (RLS alone could not contain them):
--
--   1. accounts: an owner could rewrite their OWN billing state
--      (UPDATE accounts SET plan='enterprise', item_limit=1000000, status='active')
--      and unlock every entitlement for free, bypassing Stripe. Postgres RLS
--      cannot restrict WHICH columns a policy lets you write, so we drop to the
--      privilege layer: revoke UPDATE on the table and re-grant only `name`.
--      Billing columns are now writable solely by the service role (the Stripe
--      webhook), which bypasses both grants and RLS.
--
--   2. memberships: the `memberships_write` FOR ALL policy validated only the
--      CALLER's role, never the TARGET row — so a manager could promote itself
--      to owner, mint new owners, or delete the owner. We remove direct write
--      access entirely and route every membership mutation through two
--      SECURITY DEFINER RPCs that enforce the role hierarchy, block
--      self-elevation, and protect the last owner.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. accounts — owners may rename; nobody but the service role may write billing
-- ---------------------------------------------------------------------------
-- Strip the blanket UPDATE the Supabase default grants hand to anon/authenticated…
revoke update on public.accounts from authenticated, anon;
-- …and re-grant only the safe column. The accounts_update RLS policy (owner-only)
-- still gates WHO and WHICH ROW; this gates WHICH COLUMNS.
grant update (name) on public.accounts to authenticated;

-- ---------------------------------------------------------------------------
-- 2. memberships — drop direct writes; mutate only through guarded RPCs
-- ---------------------------------------------------------------------------
-- memberships_select (read the roster) stays. With no write policy and RLS on,
-- direct INSERT/UPDATE/DELETE from the client are denied; the SECURITY DEFINER
-- RPCs below (and the onboarding RPC in 0003) bypass RLS to do the real work.
drop policy if exists memberships_write on memberships;

-- Change a member's role. Owners may set any role; managers may only assign
-- 'manager'/'staff', may not touch an owner, and may not grant 'owner'.
-- The last owner can never be demoted.
create or replace function public.set_member_role(p_account_id uuid, p_user_id uuid, p_role text)
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller       uuid := auth.uid();
  v_caller_role  text;
  v_target_role  text;
  v_owner_count  int;
begin
  if v_caller is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('owner','manager','staff') then raise exception 'Invalid role'; end if;

  select role into v_caller_role from memberships where account_id = p_account_id and user_id = v_caller;
  if v_caller_role is null then raise exception 'Not a member of this organization'; end if;
  if v_caller_role not in ('owner','manager') then raise exception 'Only owners and managers can change roles'; end if;

  select role into v_target_role from memberships where account_id = p_account_id and user_id = p_user_id;
  if v_target_role is null then raise exception 'That member is not part of this organization'; end if;

  if v_caller_role = 'manager' then
    if v_target_role = 'owner' then raise exception 'Only an owner can change an owner''s role'; end if;
    if p_role = 'owner'        then raise exception 'Only an owner can grant the owner role'; end if;
  end if;

  -- Never strand an account with zero owners.
  if v_target_role = 'owner' and p_role <> 'owner' then
    select count(*) into v_owner_count from memberships where account_id = p_account_id and role = 'owner';
    if v_owner_count <= 1 then raise exception 'Cannot demote the last owner — assign another owner first'; end if;
  end if;

  update memberships set role = p_role where account_id = p_account_id and user_id = p_user_id;
end;
$$;
revoke execute on function public.set_member_role(uuid, uuid, text) from public;  -- not anon
grant  execute on function public.set_member_role(uuid, uuid, text) to authenticated;

-- Remove a member. Managers may not remove an owner; the last owner and the
-- caller themselves can never be removed here.
create or replace function public.remove_member(p_account_id uuid, p_user_id uuid)
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller       uuid := auth.uid();
  v_caller_role  text;
  v_target_role  text;
  v_owner_count  int;
begin
  if v_caller is null then raise exception 'Not authenticated'; end if;

  select role into v_caller_role from memberships where account_id = p_account_id and user_id = v_caller;
  if v_caller_role is null then raise exception 'Not a member of this organization'; end if;
  if v_caller_role not in ('owner','manager') then raise exception 'Only owners and managers can remove members'; end if;
  if p_user_id = v_caller then raise exception 'You cannot remove yourself'; end if;

  select role into v_target_role from memberships where account_id = p_account_id and user_id = p_user_id;
  if v_target_role is null then raise exception 'That member is not part of this organization'; end if;
  if v_caller_role = 'manager' and v_target_role = 'owner' then raise exception 'Only an owner can remove an owner'; end if;

  if v_target_role = 'owner' then
    select count(*) into v_owner_count from memberships where account_id = p_account_id and role = 'owner';
    if v_owner_count <= 1 then raise exception 'Cannot remove the last owner'; end if;
  end if;

  delete from memberships where account_id = p_account_id and user_id = p_user_id;
end;
$$;
revoke execute on function public.remove_member(uuid, uuid) from public;  -- not anon
grant  execute on function public.remove_member(uuid, uuid) to authenticated;
