ALTER TABLE public.sessions
    ADD COLUMN IF NOT EXISTS upload_complete boolean NOT NULL DEFAULT false;
