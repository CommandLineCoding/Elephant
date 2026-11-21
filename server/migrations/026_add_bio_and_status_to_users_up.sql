-- A short "about" text and a custom status (an emoji and a few words, with an
-- optional end time) on a profile. Both are visible to anyone who can look the
-- person up. An expired status is simply not shown.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS bio TEXT NOT NULL DEFAULT '' CHECK (char_length(bio) <= 140),
    ADD COLUMN IF NOT EXISTS status_emoji TEXT NOT NULL DEFAULT '' CHECK (char_length(status_emoji) <= 16),
    ADD COLUMN IF NOT EXISTS status_text TEXT NOT NULL DEFAULT '' CHECK (char_length(status_text) <= 60),
    ADD COLUMN IF NOT EXISTS status_expires_at TIMESTAMPTZ;
