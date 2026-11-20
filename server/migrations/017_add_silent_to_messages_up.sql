-- A silent message is an action carried in a message (a reaction, a poll vote,
-- a pin...). It is kept in history so every phone sees it, but it is not the
-- chat's "last message", is not unread, and does not send a push ping. The
-- flag is set by the sender; the server never sees what the action is.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS silent BOOLEAN NOT NULL DEFAULT FALSE;
