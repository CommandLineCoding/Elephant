-- UnifiedPush endpoints: where the server sends a "you have new messages" ping
-- for a user who has no live WebSocket. The endpoint URL is effectively a
-- secret (anyone who has it can push to that device), so it is never logged.
CREATE TABLE IF NOT EXISTS push_endpoints (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    endpoint TEXT NOT NULL CHECK (length(endpoint) <= 2048),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, endpoint)
);
