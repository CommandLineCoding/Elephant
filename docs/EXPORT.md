# Exporting your data

[`GET /api/users/me/export`](API_CONTRACTS.md#13-export-your-data) returns what the server keeps about the signed in account as one JSON document, for the person to save, for example as `elephant-account-<date>.json`.

## The account file

The file is not encrypted: anyone who gets it can read the profile, settings, sessions, groups and the rest. It can't be restored either; it is a copy to read, not a backup.

Secrets are left out (the password hash, token hashes, the two step secret and recovery codes, push endpoint URLs and group invite codes), since each would let whoever holds the file sign in as the person, push to their phone or join their groups. So is data about other people, such as who blocked the person or who reported them. The [API contract](API_CONTRACTS.md#13-export-your-data) lists every section and everything left out.

Direct messages and statuses are end to end encrypted, so in this file they are the ciphertext the phones uploaded, which the server can't turn back into text. Group messages are readable, since groups are not end to end encrypted yet.

- Every list is `[]` when there is nothing in it, and fields that may be empty in the database are `null`.
- Times are RFC 3339.

`format` goes up if a field changes meaning. New fields can appear without it.
