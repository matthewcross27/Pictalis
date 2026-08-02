-- cleanup_expired_sessions() (see 20260517000004_storage_hardening.sql) runs
-- every hour via pg_cron and, until now, had no index support for either
-- predicate it filters on:
--
-- 1. Both its storage.objects DELETE (via the EXISTS join) and its final
--    `DELETE FROM sessions WHERE expires_at < NOW()` scan sessions filtered
--    on expires_at - previously a full sequential scan of the whole table on
--    every run, growing with total session volume rather than just the
--    (usually much smaller) expired subset.
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON public.sessions(expires_at);

-- 2. The storage.objects DELETE joins photos to storage.objects on
--    storage_path - previously unindexed, forcing a full sequential scan of
--    photos on every run. Partial (storage_path IS NOT NULL) because
--    pre-registered photos have a NULL storage_path until upload completes
--    (see 20260620000002_nullable_storage_path.sql) and can never match this
--    join.
CREATE INDEX IF NOT EXISTS idx_photos_storage_path ON public.photos(storage_path)
  WHERE storage_path IS NOT NULL;
