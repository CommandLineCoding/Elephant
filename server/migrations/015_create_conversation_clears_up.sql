-- "Delete for me": the time a user cleared a conversation. Their history,
-- conversation list and unread counts skip messages from before it. Each row
-- is either a direct chat (peer_id) or a group (group_id), never both.
CREATE TABLE IF NOT EXISTS conversation_clears (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    peer_id UUID REFERENCES users(id) ON DELETE CASCADE,
    group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
    cleared_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK ((peer_id IS NULL) <> (group_id IS NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_clears_peer
    ON conversation_clears(user_id, peer_id) WHERE peer_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_clears_group
    ON conversation_clears(user_id, group_id) WHERE group_id IS NOT NULL;
