-- next-pair and results filter on (session_id, upload_status='uploaded') for
-- every ranking query. A composite index eliminates a sequential scan on large
-- photo sets.
CREATE INDEX IF NOT EXISTS photos_session_upload_status_idx
    ON public.photos (session_id, upload_status);
