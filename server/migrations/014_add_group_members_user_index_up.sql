-- Finding the people someone shares a group with starts from their own
-- memberships. The primary key is (group_id, user_id), which can't answer
-- "which groups is this user in" without scanning.
CREATE INDEX IF NOT EXISTS idx_group_members_user ON group_members(user_id);
