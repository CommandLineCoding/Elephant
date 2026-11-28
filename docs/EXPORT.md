# Exporting your data

[`GET /api/users/me/export`](API_CONTRACTS.md#13-export-your-data) returns what the server keeps about the signed in account as one JSON document, for the person to save, for example as `elephant-account-<date>.json`.

## The account file

The file is not encrypted: anyone who gets it can read the profile, settings, sessions, groups and the rest. It can't be restored either; it is a copy to read, not a backup.

Secrets are left out (the password hash, token hashes, the two step secret and recovery codes, push endpoint URLs and group invite codes), since each would let whoever holds the file sign in as the person, push to their phone or join their groups. So is data about other people, such as who blocked the person or who reported them. The [API contract](API_CONTRACTS.md#13-export-your-data) lists every section and everything left out.

Direct messages and statuses are end to end encrypted, so in this file they are the ciphertext the phones uploaded, which the server can't turn back into text. Not even the sender can read a direct message they sent, since it is encrypted for the recipient. So the file has only the group messages the person sent, which are readable because groups are not end to end encrypted yet. Asking with `include=direct_messages` adds the direct message ciphertext.

## Messages come in pages

An account can have any number of messages, so the file has the first page of them (1000 unless `limit` asks for up to 2000). When there are more, `messages_truncated` is `true` and `messages_next` is a cursor: [`GET /api/users/me/export/messages`](API_CONTRACTS.md#more-pages-of-messages) with `after` set to it gives the next page and its own `next`, until `next` is `null`. Each request reads at most one page, so a big account can't take up the server's memory.

- Every list is `[]` when there is nothing in it, and fields that may be empty in the database are `null`.
- Times are RFC 3339.

`format` goes up if a field changes meaning. New fields can appear without it.
