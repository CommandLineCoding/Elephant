-- A group's description, and whether only its admins may send messages (for
-- announcement groups). Members can still react and vote.
ALTER TABLE groups
    ADD COLUMN IF NOT EXISTS description TEXT NOT NULL DEFAULT '' CHECK (char_length(description) <= 500),
    ADD COLUMN IF NOT EXISTS admins_only BOOLEAN NOT NULL DEFAULT FALSE;
