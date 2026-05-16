-- Sessions: one per user ranking batch
CREATE TABLE sessions (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '72 hours',
  status       TEXT        NOT NULL DEFAULT 'uploading'
                           CHECK (status IN ('uploading', 'processing', 'ranking', 'complete')),
  photo_count  INT         NOT NULL DEFAULT 0,
  user_id      UUID
);

-- Photos: one row per uploaded working copy
CREATE TABLE photos (
  id               UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id       UUID            NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  storage_path     TEXT            NOT NULL,
  thumbnail_path   TEXT,
  elo_rating       DOUBLE PRECISION NOT NULL DEFAULT 1500,
  uncertainty      DOUBLE PRECISION NOT NULL DEFAULT 350,
  comparison_count INT             NOT NULL DEFAULT 0,
  is_suppressed    BOOLEAN         NOT NULL DEFAULT FALSE,
  cluster_id       TEXT,
  quality_flags    JSONB           NOT NULL DEFAULT '{}',
  created_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Comparisons: each pairwise choice the user makes
CREATE TABLE comparisons (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id   UUID        NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_a_id   UUID        NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  photo_b_id   UUID        NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  winner_id    UUID        REFERENCES photos(id),
  completed_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT winner_set_when_complete CHECK (
    (completed_at IS NULL AND winner_id IS NULL) OR
    (completed_at IS NOT NULL AND winner_id IS NOT NULL)
  )
);

-- Indexes for common query patterns
CREATE INDEX idx_photos_session_elo          ON photos(session_id, elo_rating DESC);
CREATE INDEX idx_comparisons_session         ON comparisons(session_id);
CREATE INDEX idx_comparisons_winner          ON comparisons(winner_id);
CREATE INDEX idx_comparisons_session_pending ON comparisons(session_id) WHERE completed_at IS NULL;

-- Enable Row Level Security on all tables
ALTER TABLE sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE photos      ENABLE ROW LEVEL SECURITY;
ALTER TABLE comparisons ENABLE ROW LEVEL SECURITY;
