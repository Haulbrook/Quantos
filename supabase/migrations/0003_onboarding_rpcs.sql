-- ============================================================================
-- Quantos — onboarding RPCs. Intentionally SECURITY DEFINER and callable by
-- `authenticated` (the linter will flag this — by design): a brand-new user has
-- no membership yet, so RLS can't let them bootstrap their own account. Each
-- function internally scopes to auth.uid(), so a caller can only act on
-- themselves / their own account.
-- ============================================================================

-- Self-serve signup: create an account + owner membership + a default location.
create or replace function public.create_account_for_current_user(p_name text)
returns uuid
language plpgsql security definer set search_path = public, auth
as $$
declare v_account uuid; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if exists (select 1 from memberships where user_id = v_uid) then
    raise exception 'This user already belongs to an organization';
  end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'Organization name is required'; end if;

  -- New orgs start on the Starter tier in a 14-day trial.
  insert into accounts (name, plan, status, item_limit, asset_limit, user_limit, trial_ends_at)
  values (btrim(p_name), 'starter', 'trialing', 200, 50, 5, now() + interval '14 days')
  returning id into v_account;

  insert into memberships (account_id, user_id, role) values (v_account, v_uid, 'owner');

  insert into locations (account_id, name, description)
  values (v_account, 'Main Storage', 'Default location');

  return v_account;
end;
$$;
grant execute on function public.create_account_for_current_user(text) to authenticated;

-- List members (with email) of the caller's account — auth.users isn't exposed
-- to the client, so the Team screen needs this.
create or replace function public.list_account_members()
returns table(user_id uuid, email text, role text, created_at timestamptz)
language sql security definer set search_path = public, auth
as $$
  select m.user_id, u.email::text, m.role, m.created_at
  from memberships m
  join auth.users u on u.id = m.user_id
  where m.account_id in (select account_id from memberships where user_id = auth.uid())
  order by m.created_at;
$$;
grant execute on function public.list_account_members() to authenticated;
