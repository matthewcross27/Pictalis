-- cleanup_expired_sessions() has been failing on every hourly run since it
-- started deleting storage.objects directly: the platform-level
-- protect_delete() trigger on storage.objects rejects raw SQL DELETEs
-- (deletes must go through the Storage API, which also removes the
-- underlying stored object, not just the Postgres metadata row). Because
-- that statement raised, the function aborted before ever reaching
-- `DELETE FROM public.sessions`, so expired sessions/photos/comparisons and
-- their storage objects have never actually been purged.
--
-- Fix: move storage-object deletion (and, since it must happen first and be
-- confirmed before sessions are deleted, the sessions delete too) into a new
-- `cleanup-expired-sessions` Edge Function that uses the Storage API. This
-- SQL function keeps only the abandoned-pending-comparisons purge, which
-- never touched storage and was working correctly.
CREATE OR REPLACE FUNCTION public.cleanup_expired_sessions()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Delete pending comparisons abandoned for more than 24 hours
  DELETE FROM public.comparisons
  WHERE completed_at IS NULL
    AND created_at < NOW() - INTERVAL '24 hours';
END;
$$;

-- Required for the cron job below to call the Edge Function over HTTP.
CREATE EXTENSION IF NOT EXISTS pg_net;

-- The Edge Function call needs the project URL and a service-role-privileged
-- key (see backend/supabase/functions/cleanup-expired-sessions/index.ts,
-- which rejects any caller not presenting the exact service-role key). Both
-- must be created as Supabase Vault secrets by hand before this cron job can
-- succeed - see AGENTS.md for the exact commands. No value is set here.
DO $$
BEGIN
  PERFORM cron.unschedule('cleanup-expired-session-storage');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

SELECT cron.schedule(
  'cleanup-expired-session-storage',
  '5 * * * *',
  $$
  SELECT net.http_post(
    url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'project_url')
      || '/functions/v1/cleanup-expired-sessions',
    headers := jsonb_build_object(
      'Content-type', 'application/json',
      'apikey', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key'),
      'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key')
    ),
    timeout_milliseconds := 30000
  ) AS request_id;
  $$
);
