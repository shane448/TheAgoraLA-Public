ALTER TABLE analysis_jobs
    ADD COLUMN IF NOT EXISTS provider_credential_encrypted TEXT;

ALTER TABLE analysis_jobs DROP CONSTRAINT IF EXISTS analysis_jobs_credit_cost_check;
ALTER TABLE analysis_jobs
    ADD CONSTRAINT analysis_jobs_credit_cost_check CHECK (credit_cost >= 0);

UPDATE analysis_jobs
SET status = 'failed', error = 'This legacy job must be submitted again.', completed_at = NOW(), updated_at = NOW()
WHERE status IN ('queued', 'processing') AND provider_credential_encrypted IS NULL;
