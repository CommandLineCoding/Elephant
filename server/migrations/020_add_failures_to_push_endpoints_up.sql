-- How many pings in a row to this endpoint failed. A success resets it. The
-- cleanup job removes endpoints that keep failing, so a distributor that is
-- gone for good stops costing a request on every message.
ALTER TABLE push_endpoints ADD COLUMN IF NOT EXISTS failures INT NOT NULL DEFAULT 0;
