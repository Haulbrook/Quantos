-- ============================================================================
-- Quantos — atomic multi-table operations (run after 0007)
--
-- Check-in and loss-report each mutate two or three tables. The frontend did
-- them as separate REST calls and only checked the FIRST, so a partial failure
-- could leave an asset stuck 'checked_out' with its checkout already 'returned',
-- or marked 'lost' while the possession ledger still showed it out to a person.
-- A plpgsql function body runs as ONE transaction (one PostgREST call = one txn),
-- so wrapping each flow here makes all of its writes commit or roll back together
-- — the same guarantee adjust_item_stock (0005) already gives the +/- path.
--
-- Both are SECURITY INVOKER: RLS still scopes every statement to the caller's
-- own account, so no extra privilege is granted.
-- ============================================================================

-- Return an asset: close the open checkout AND flip the asset back to available,
-- atomically. Returns the name of the next person waiting on this asset (oldest
-- open request), or null — so the caller gets the "next in line" hint in one trip.
create or replace function public.check_in_asset(
  p_checkout_id uuid,
  p_condition   text,
  p_notes       text default null,
  p_photo_url   text default null
) returns text
language plpgsql security invoker set search_path = public, auth
as $$
declare v_asset uuid; v_next text;
begin
  if p_condition is not null
     and p_condition not in ('new','good','fair','poor','damaged') then
    raise exception 'Invalid return condition';
  end if;

  update checkouts
     set status = 'returned', returned_at = now(), return_condition = p_condition,
         return_notes = p_notes, return_photo_url = p_photo_url
   where id = p_checkout_id and status = 'out'
   returning asset_id into v_asset;

  if v_asset is null then
    raise exception 'This checkout is already closed or could not be found';
  end if;

  update assets
     set status = 'available', condition = coalesce(p_condition, condition), updated_at = now()
   where id = v_asset;

  select requested_by_name into v_next
    from asset_requests
   where asset_id = v_asset and status = 'open'
   order by created_at asc
   limit 1;

  return v_next;
end;
$$;
revoke execute on function public.check_in_asset(uuid, text, text, text) from public;  -- not anon
grant  execute on function public.check_in_asset(uuid, text, text, text) to authenticated;

-- Record a loss/shrinkage event and, for a real loss of a tracked asset (any
-- category except wear_and_tear), mark the asset 'lost' and auto-close any open
-- checkout — all atomically, so the loss ledger and the possession ledger can
-- never disagree. The owning account is derived from the subject row (never
-- trusted from the client); RLS makes a non-member's subject invisible -> "not
-- found". reported_by is the JWT user.
create or replace function public.report_loss(
  p_asset_id     uuid,
  p_item_id      uuid,
  p_subject_name text,
  p_category     text,
  p_note         text,
  p_cost         numeric default null,
  p_person       text default null,
  p_reporter_name text default null
) returns void
language plpgsql security invoker set search_path = public, auth
as $$
declare v_acct uuid;
begin
  if p_category not in ('lost','broken','misuse','stolen','wear_and_tear','other') then
    raise exception 'Invalid loss category';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'A note is required — no blank loss records';
  end if;

  if    p_asset_id is not null then select account_id into v_acct from assets where id = p_asset_id;
  elsif p_item_id  is not null then select account_id into v_acct from items  where id = p_item_id;
  end if;
  if v_acct is null then raise exception 'Loss subject not found'; end if;

  insert into loss_events
    (account_id, asset_id, item_id, subject_name, category, note,
     cost_impact, person_responsible, reported_by, reported_by_name)
  values
    (v_acct, p_asset_id, p_item_id, p_subject_name, p_category, btrim(p_note),
     p_cost, p_person, auth.uid(), p_reporter_name);

  if p_asset_id is not null and p_category <> 'wear_and_tear' then
    update assets set status = 'lost', updated_at = now() where id = p_asset_id;
    update checkouts
       set status = 'returned', returned_at = now(),
           return_notes = 'Auto-closed — asset reported ' || p_category
     where asset_id = p_asset_id and status = 'out';
  end if;
end;
$$;
revoke execute on function public.report_loss(uuid, uuid, text, text, text, numeric, text, text) from public;  -- not anon
grant  execute on function public.report_loss(uuid, uuid, text, text, text, numeric, text, text) to authenticated;
