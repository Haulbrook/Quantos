-- ============================================================================
-- Quantos — photo storage
-- A single public bucket holds item + asset + return photos. Public read keeps
-- photo_url values simple; writes are restricted to authenticated users.
-- (Tenant isolation for objects is by upload path convention: <account_id>/...)
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('quantos-photos', 'quantos-photos', true)
on conflict (id) do nothing;

-- Anyone may read (public bucket → renderable <img src>).
create policy "quantos photos public read"
  on storage.objects for select
  using (bucket_id = 'quantos-photos');

-- Only signed-in users may upload / replace / remove.
create policy "quantos photos auth insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'quantos-photos');

create policy "quantos photos auth update"
  on storage.objects for update to authenticated
  using (bucket_id = 'quantos-photos');

create policy "quantos photos auth delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'quantos-photos');
