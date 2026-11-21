-- What a person lets others see and do. The server enforces these, so a
-- changed or modified app can't get around them. A person with no row has the
-- defaults below, which are how the server behaved before there were settings.
CREATE TABLE IF NOT EXISTS user_settings (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- Who can see that the person is online: everyone, contacts (people who
    -- share a chat or a group with them) or nobody.
    online_status TEXT NOT NULL DEFAULT 'contacts'
        CHECK (online_status IN ('everyone', 'contacts', 'nobody')),
    -- Whether others see that their messages were read, and whether the person
    -- sends read receipts at all.
    read_receipts BOOLEAN NOT NULL DEFAULT TRUE,
    -- Who can add the person to a group.
    group_adds TEXT NOT NULL DEFAULT 'everyone'
        CHECK (group_adds IN ('everyone', 'contacts', 'nobody')),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
