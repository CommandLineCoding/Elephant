-- A first message from someone the recipient has never chatted with (and who
-- shares no group with them) is a message request until the recipient accepts
-- it or answers. A row exists only while the request is pending, so every
-- conversation that exists when this ships stays as it is.
CREATE TABLE IF NOT EXISTS message_requests (
    recipient_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sender_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (recipient_id, sender_id)
);
