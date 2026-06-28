-- ============================================================================
-- Quantos — security advisor follow-ups (run after 0001–0005)
--
--   1. Enable RLS on stripe_events. It is written ONLY by the service role (the
--      Stripe webhook), which BYPASSES RLS — so enabling RLS with no policies
--      correctly denies all anon/authenticated access while the webhook keeps
--      working. Closes the "anyone with the anon key can read/modify the Stripe
--      idempotency ledger" exposure flagged as critical by the linter.
--
--   2. Drop the broad public-read policy on the photos bucket. The bucket is
--      public, so getPublicUrl() / <img src> still resolve objects without it;
--      removing it stops clients from LISTING every file in the bucket.
-- ============================================================================

alter table public.stripe_events enable row level security;

drop policy if exists "quantos photos public read" on storage.objects;
