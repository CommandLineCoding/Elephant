-- Two-step sign-in with an authenticator app (TOTP). The secret is stored
-- encrypted. A secret exists from the moment someone starts setting it up, and
-- only counts once they have entered a code (enabled).
CREATE TABLE IF NOT EXISTS user_two_factor (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    secret_enc BYTEA NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    -- The 30 second step of the last code that was accepted, so the same code
    -- can't be used twice.
    last_used_step BIGINT NOT NULL DEFAULT 0,
    failed_attempts INT NOT NULL DEFAULT 0,
    locked_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One-time recovery codes, kept as hashes: the codes themselves are shown once.
CREATE TABLE IF NOT EXISTS two_factor_recovery_codes (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash TEXT NOT NULL,
    used_at TIMESTAMPTZ,
    PRIMARY KEY (user_id, code_hash)
);
