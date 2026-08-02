-- Abuse protection: (1) hard cap on photos-per-session, (2) request throttling.
-- See backend-readiness audit report (2026-07-30), "Blocking/risky" item 2.

-- ---------------------------------------------------------------------------
-- 1. Photo count cap
--
-- batch-pre-register is the only path that inserts rows into `photos`
-- (register-photo only UPDATEs a row already inserted here). Enforcing the
-- cap here as a single atomic function closes the gap: nothing stops a caller
-- from calling batch-pre-register repeatedly with fresh UUIDs to accumulate
-- unbounded rows for one session otherwise.
--
-- The insert happens first, then the post-insert total is checked against
-- the session's declared photo_count; if it's over, the RAISE EXCEPTION
-- rolls back the whole function call (including the insert) since it all
-- runs in the transaction the RPC call opened. `FOR UPDATE` on the session
-- row serializes concurrent calls for the same session so two racing calls
-- can't both slip past the check before either commits.
CREATE OR REPLACE FUNCTION public.pre_register_photos_atomic(
  p_session_id uuid,
  p_photo_ids  uuid[]
) RETURNS int LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE
  v_cap      int;
  v_inserted int;
  v_total    int;
BEGIN
  SELECT photo_count INTO v_cap
  FROM public.sessions
  WHERE id = p_session_id
  FOR UPDATE;

  IF v_cap IS NULL THEN
    RAISE EXCEPTION 'session_not_found'
      USING ERRCODE = 'UE003', HINT = 'session does not exist or is not owned by caller';
  END IF;

  -- ON CONFLICT DO NOTHING keeps this idempotent: a network retry that
  -- resends already-registered ids doesn't count against the cap twice.
  INSERT INTO public.photos (id, session_id, upload_status)
  SELECT id, p_session_id, 'pending'
  FROM unnest(p_photo_ids) AS id
  ON CONFLICT (id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  SELECT COUNT(*) INTO v_total FROM public.photos WHERE session_id = p_session_id;

  IF v_total > v_cap THEN
    RAISE EXCEPTION 'photo_count_exceeded'
      USING ERRCODE = 'UE002',
            HINT = format('session photo_count is %s, this call would total %s', v_cap, v_total);
  END IF;

  RETURN v_inserted;
END;
$$;

-- SECURITY INVOKER: the INSERT above still runs under the caller's role, so
-- the existing "Users own photos in their sessions" RLS policy (WITH CHECK)
-- still applies and a caller can't register photos into someone else's
-- session, same as before this function existed.
REVOKE ALL ON FUNCTION public.pre_register_photos_atomic(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pre_register_photos_atomic(uuid, uuid[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Request throttling (Postgres-backed token bucket)
--
-- Supabase Edge Functions are stateless and horizontally scaled (per
-- CLAUDE.md), so an in-memory limiter wouldn't be shared across instances.
-- Supabase's built-in `[auth.rate_limit]` config only covers Auth operations
-- (sign-in/sign-up/token refresh/anonymous sign-in) and does not cover these
-- business endpoints at all. A small Postgres table + atomic
-- refill-and-consume function gives every function instance a shared,
-- consistent view of each caller's remaining budget without adding
-- infrastructure (no Redis/proxy needed).
--
-- One row per (endpoint, caller) bucket. `tokens` is refilled continuously
-- based on elapsed time since `updated_at`, capped at `capacity`, then the
-- request's cost is deducted. See _shared/rate-limit.ts for the TypeScript
-- side (bucket keying, per-endpoint capacity/refill config).
CREATE TABLE IF NOT EXISTS public.rate_limit_buckets (
  key        TEXT PRIMARY KEY,
  tokens     DOUBLE PRECISION NOT NULL,
  updated_at TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);

-- No RLS policies are defined: direct table access is fully blocked for
-- anon/authenticated (RLS with zero policies denies all rows), and the only
-- way in is the SECURITY DEFINER function below.
ALTER TABLE public.rate_limit_buckets ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.check_rate_limit(
  p_key                text,
  p_capacity           int,
  p_refill_per_second  float8,
  p_cost               int DEFAULT 1
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tokens     float8;
  v_updated_at timestamptz;
  v_elapsed    float8;
BEGIN
  INSERT INTO public.rate_limit_buckets (key, tokens, updated_at)
  VALUES (p_key, p_capacity - p_cost, NOW())
  ON CONFLICT (key) DO NOTHING;

  IF FOUND THEN
    RETURN true;
  END IF;

  SELECT tokens, updated_at INTO v_tokens, v_updated_at
  FROM public.rate_limit_buckets
  WHERE key = p_key
  FOR UPDATE;

  v_elapsed := GREATEST(0, EXTRACT(EPOCH FROM (NOW() - v_updated_at)));
  v_tokens := LEAST(p_capacity, v_tokens + v_elapsed * p_refill_per_second);

  IF v_tokens < p_cost THEN
    UPDATE public.rate_limit_buckets SET tokens = v_tokens, updated_at = NOW()
    WHERE key = p_key;
    RETURN false;
  END IF;

  UPDATE public.rate_limit_buckets SET tokens = v_tokens - p_cost, updated_at = NOW()
  WHERE key = p_key;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.check_rate_limit(text, int, float8, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_rate_limit(text, int, float8, int) TO anon, authenticated;

-- Housekeeping: buckets for callers who haven't been seen in a while are
-- dead weight. Purge hourly alongside the existing session cleanup job.
CREATE OR REPLACE FUNCTION public.cleanup_stale_rate_limit_buckets()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.rate_limit_buckets WHERE updated_at < NOW() - INTERVAL '1 day';
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_stale_rate_limit_buckets() FROM PUBLIC;

DO $$
BEGIN
  PERFORM cron.unschedule('cleanup-stale-rate-limit-buckets');
EXCEPTION WHEN others THEN NULL;
END;
$$;

SELECT cron.schedule(
  'cleanup-stale-rate-limit-buckets',
  '0 * * * *',
  'SELECT public.cleanup_stale_rate_limit_buckets()'
);
