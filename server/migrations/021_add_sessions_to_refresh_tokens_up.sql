-- A refresh token is one signed-in device. These columns let a person see
-- their devices and sign one out. session_id stays the same when the token is
-- rotated; existing rows each get their own.
ALTER TABLE refresh_tokens
    ADD COLUMN IF NOT EXISTS session_id UUID NOT NULL DEFAULT gen_random_uuid(),
    ADD COLUMN IF NOT EXISTS device_name TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_refresh_tokens_session ON refresh_tokens(session_id);
