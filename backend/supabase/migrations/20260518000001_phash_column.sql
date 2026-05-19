-- phash stores the 16-char hex difference hash computed at register-photo time.
-- NULL until hashing completes (or if hashing fails — graceful degradation).
-- cluster_id (TEXT, nullable) already exists — no changes needed.
ALTER TABLE photos ADD COLUMN IF NOT EXISTS phash TEXT;

-- Enables fast fetch of all hashes for a session in one query.
CREATE INDEX IF NOT EXISTS idx_photos_session_phash ON photos(session_id, phash)
  WHERE phash IS NOT NULL;
