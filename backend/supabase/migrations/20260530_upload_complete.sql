ALTER TABLE sessions
    ADD COLUMN upload_complete boolean NOT NULL DEFAULT false;
