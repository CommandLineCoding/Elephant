-- Text status that disappears after 24 hours. The author's phone encrypts the
-- status separately for each contact, so the server keeps one opaque copy per
-- recipient and never learns what it says.
CREATE TABLE IF NOT EXISTS statuses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS statuses_author ON statuses (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS statuses_expires ON statuses (expires_at);

CREATE TABLE IF NOT EXISTS status_copies (
    status_id UUID NOT NULL REFERENCES statuses(id) ON DELETE CASCADE,
    recipient_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    viewed_at TIMESTAMPTZ,
    PRIMARY KEY (status_id, recipient_id)
);
CREATE INDEX IF NOT EXISTS status_copies_recipient ON status_copies (recipient_id);
