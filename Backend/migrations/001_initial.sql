CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    apple_subject TEXT UNIQUE,
    apple_refresh_token_encrypted TEXT,
    email TEXT,
    display_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_refresh_token_encrypted TEXT;

CREATE TABLE IF NOT EXISTS credit_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    delta INTEGER NOT NULL CHECK (delta <> 0),
    reason TEXT NOT NULL,
    reference TEXT NOT NULL UNIQUE,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS credit_ledger_user_created_idx
    ON credit_ledger(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS purchase_transactions (
    transaction_id TEXT PRIMARY KEY,
    original_transaction_id TEXT,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL,
    environment TEXT NOT NULL,
    purchased_at TIMESTAMPTZ,
    raw_payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS analysis_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source_hash TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('queued', 'processing', 'complete', 'failed')),
    input JSONB NOT NULL,
    result JSONB,
    error TEXT,
    credit_cost INTEGER NOT NULL DEFAULT 1 CHECK (credit_cost > 0),
    model_version TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS analysis_jobs_queue_idx
    ON analysis_jobs(status, created_at);

CREATE INDEX IF NOT EXISTS analysis_jobs_user_source_idx
    ON analysis_jobs(user_id, source_hash, created_at DESC);

CREATE TABLE IF NOT EXISTS answer_scores (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    question_hash TEXT NOT NULL,
    score INTEGER NOT NULL CHECK (score BETWEEN 0 AND 100),
    model_version TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
