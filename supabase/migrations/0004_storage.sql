-- ============================================================================
-- Quantos — photo storage
-- A single bucket holds item + asset + return photos, namespaced per tenant by
-- the upload path: <account_id>/<folder>/<file>.
--
-- The bucket is PUBLIC for read so photo_url (a getPublicUrl link) renders in a
-- plain <img src>. The account_id path prefix is a high-entropy UUID, so a photo
-- is only reachable by someone who already holds its URL — acceptable for this
-- product. To make photos fully private instead, set public => false below and
-- gate the read policy with is_account_member(...) like the write policies, then
-- serve images via createSignedUrl() in the frontend.
--
-- Writes (insert/update/delete) ARE tenant-scoped at the server: a user can only
-- touch objects under their own account's folder. This stops the cross-tenant
-- overwrite/delete that bucket_id-only policies would allow.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('quantos-photos', 'quantos-photos', true)
on conflict (id) do nothing;

-- First path segment is the owning account id; (storage.foldername(name))[1].
-- A non-uuid/empty prefix fails the ::uuid cast and the write is denied (fail closed).

-- Anyone may read (public bucket → renderable <img src>).
create policy "quantos photos public read"
  on storage.objects for select
  using (bucket_id = 'quantos-photos');

-- Uploads/replacements/removals are scoped to the caller's own account folder.
create policy "quantos photos auth insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'quantos-photos'
    and public.is_account_member(((storage.foldername(name))[1])::uuid));

create policy "quantos photos auth update"
  on storage.objects for update to authenticated
  using (bucket_id = 'quantos-photos'
    and public.is_account_member(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'quantos-photos'
    and public.is_account_member(((storage.foldername(name))[1])::uuid));

create policy "quantos photos auth delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'quantos-photos'
    and public.is_account_member(((storage.foldername(name))[1])::uuid));
