-- When a direct message reached the recipient's phone. The recipient's app
-- reports it, and the sender sees a second tick. A message that has been read
-- has been delivered too.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ;
