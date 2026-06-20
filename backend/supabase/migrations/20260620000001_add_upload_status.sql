-- Photos start with upload_status='pending' (identity pre-registered, bytes not yet
-- in storage). The upload worker sets 'uploaded' after bytes land in Supabase Storage.
-- Ranking queries filter on upload_status='uploaded' so rows with no bytes in storage
-- never appear in the comparison pool.
ALTER TABLE public.photos
  ADD COLUMN IF NOT EXISTS upload_status TEXT NOT NULL DEFAULT 'pending'
  CHECK (upload_status IN ('pending', 'uploaded'));
