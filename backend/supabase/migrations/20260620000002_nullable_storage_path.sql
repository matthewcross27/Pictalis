-- Pre-registration inserts photo identity rows before bytes are uploaded,
-- so storage_path is unknown at row creation time. The upload pipeline sets
-- it via register-photo (UPDATE) once bytes land in storage.
ALTER TABLE public.photos
  ALTER COLUMN storage_path DROP NOT NULL;
