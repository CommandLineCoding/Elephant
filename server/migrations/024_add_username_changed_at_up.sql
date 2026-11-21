-- When a person last changed their username. A username can be changed once
-- every 30 days; NULL means never.
ALTER TABLE users ADD COLUMN IF NOT EXISTS username_changed_at TIMESTAMPTZ;
