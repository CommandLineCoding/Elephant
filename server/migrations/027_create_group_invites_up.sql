-- An invite link for a group: one code per group, which an admin can create,
-- reset (the old code stops working) and turn off. The code is long and
-- random: it is the only secret. With require_approval, someone who opens the
-- link asks to join and an admin lets them in.
CREATE TABLE IF NOT EXISTS group_invites (
    group_id UUID PRIMARY KEY REFERENCES groups(id) ON DELETE CASCADE,
    code TEXT NOT NULL UNIQUE,
    require_approval BOOLEAN NOT NULL DEFAULT FALSE,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS group_join_requests (
    group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (group_id, user_id)
);
