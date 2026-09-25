ALTER TABLE analysis_jobs
    ADD COLUMN IF NOT EXISTS claim_token UUID;

UPDATE analysis_jobs
SET status = 'queued', claim_token = NULL, updated_at = NOW()
WHERE status = 'processing';
