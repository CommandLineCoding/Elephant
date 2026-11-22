# End-to-end encrypted groups with sender keys

Status: **proposal**, for discussion on #191 before any code (#192, #193). Part of the group E2EE epic, #190.

Today a group message is a plaintext envelope (`{"type": 0, ...}`): TLS protects it on the way, but the server can read it. Direct messages are already end-to-end encrypted with the Signal Protocol. This note says how groups get the same, using Signal's **sender keys** (`GroupSessionBuilder` and `GroupCipher` in `libsignal_protocol_dart`, with the `SenderKeyStore` the app already has).

## How it works, in short

Each member has **one sender key per group**: a chain of message keys only that member can advance, and a signing key. A member encrypts every group message once with their own chain, so the server relays one ciphertext to everyone. Everyone else needs a copy of that member's key to read it. That copy, the `SenderKeyDistributionMessage` (SKDM), is sent privately to each member over the existing one-to-one Signal sessions.

## Envelope types

The envelope is `{"type": <int>, "ciphertext": "<base64>"}`. Types are libsignal's:

| type | meaning | where it travels |
|---|---|---|
| `0` | plaintext (today's groups) | group frames |
| `2`, `3` | Signal message, prekey message | direct frames |
| **`4`** | **sender-key message** (`SenderKeyMessage`) | **group frames** (new) |

An SKDM (libsignal type 5) is never sent on its own. It goes **inside a normal Signal-encrypted direct message** as a structured payload (see *Structured messages* in the API docs):

```
kind: "group_key"   fields: { "group": "<group id>", "skdm": "<base64>" }
```

It is sent with `silent: true`, like reactions and poll votes, so it is not unread, not a notification, not a push ping, and not the chat's last message. A second kind, **`group_key_request`** `{ "group": "<id>" }`, asks the receiver to send their current SKDM again.

So the server needs **no new frame type for key distribution**: it is an ordinary silent direct message, stored and delivered like any other, including to a member who is offline. (They are stored, so they take a row each; they carry `expires_in` of 28 days so they don't pile up, and a member who needs a key later asks for it.)

## Distribution

- **A new group.** The creator makes their sender key and sends the SKDM to each initial member. Each member does the same on first opening the group (or on receiving the first key), so keys cross in both directions without the server doing anything.
- **Someone joins.** The new member makes their key and sends it to everyone. Every existing member sends **their current SKDM** to the new member. An SKDM carries the chain **at that moment**, not from the start, so the new member can read what is sent from then on, **and cannot read anything earlier**. Existing members learn of the join from `group_updated` (below), refetch the member list, and see who is new.
- **Someone's phone has no key for a message** (an SKDM hasn't arrived yet, or the phone was restored from a backup): the message is kept as "Waiting for the encryption key", the phone sends `group_key_request` to the sender, and decrypts when the SKDM arrives. Libsignal tolerates messages arriving out of order, up to 2000 ahead of the chain.

## Rotation

When someone **leaves or is removed**, **every remaining member throws away their own sender key for the group, makes a new one (a new key id and chain), and sends the new SKDM to the remaining members only**. Receivers delete the departed member's key state. The person who left still has the old keys, but not the new ones, so cannot read what is sent next. (The server stops relaying to them at once; rotation is what protects against a server that doesn't.)

A member must not send a message with a key made before the membership last changed. Each phone tracks the member set its key was distributed to, and before sending, if the set has changed, it **rotates first**. Joins need no rotation: the new member is simply sent the current key.

## What the server does

- **Relays and stores group frames as they are.** Nothing needs to parse a type-4 `content`. For a group marked encrypted (below) the server only checks that the envelope's `type` is `4`, and refuses type `0`, so a member's old app can't silently post plaintext into an encrypted group.
- **`group_updated`** already goes to a group's live members when an admin changes it. It also goes when **membership changes**, with a `members_changed` flag. Clients refetch members and rotate or distribute as above.
- **Admins-only groups need a change.** The server enforces "only admins post, apart from actions" by reading the hidden action line in plaintext. It can't in an encrypted group. Instead it accepts **`silent` frames** from members and still refuses their non-silent frames. The **clients** then drop anything a non-admin sent that isn't a valid action (a reaction, vote or pin). A member could therefore send junk flagged silent; it is dropped by every honest app, and costs only storage.
- **Quoted previews.** The server builds `quoted_message` for replies by reading the stored original. For an encrypted group it returns only `reply_to_message_id`, and the app shows the quote from its own copy.
- **History for new members.** Today a new member can fetch a group's whole history. For an encrypted group the server should return only messages from `joined_at` on: they couldn't read the rest, and it saves them downloading it.

## Turning it on, and older apps

A group has an **`encrypted`** flag, **off for every group that exists**. It is turned on once, by an admin, and **never off again** (turning it off would be a downgrade a server could force).

- **Who can be in an encrypted group.** The app says what it supports when it uploads its prekeys (a `features` list, with `group_e2ee`), and the server keeps it. The group info shows each member's support. An admin sees **Turn on end-to-end encryption** only when **every member supports it**; until then the group shows how many members need to update.
- **New groups** are created encrypted if the creator and everyone added support it, and otherwise not, with the same notice.
- **Adding someone** to an encrypted group is refused (`409`) if their app doesn't support it.
- **Old apps keep working in unencrypted groups.** Nothing changes for them until an admin turns it on, which they block until they update.

## What the app shows

- The notice "Group messages are not end-to-end encrypted yet" changes by group: **unencrypted** (with the count of members who need to update) or **end-to-end encrypted**, like a direct chat's.
- At the point you joined an encrypted group the chat shows "Messages before you joined can't be read" (a divider, not an error on each message).
- A message that can't be read yet shows "Waiting for the encryption key", and then the message, or "Can't be read" if the key never comes (for example it was sent before you joined).
- Mentions, polls, reactions and pins keep working: they are inside the ciphertext, as for direct chats.

## What the server can still see

Who is in a group, who sends, when, and how big a message is. The group's name and description, who is an admin, whether a frame is `silent`, and a message's expiry (`expires_in`). A reply's target id. It cannot see what a message says, what a reaction or vote was, who is mentioned, or a poll's options. The member list is what the server says it is: a malicious server could add itself, and members' phones would then send it keys. Phones show "X was added" in the chat so this can be noticed, and signed membership (as Signal's newer groups have) is a later step.

## Other things this touches

- **Chat backup** doesn't include sender keys (nor Signal sessions). After a restore, a phone sends `group_key_request` to each group's members and rotates its own key.
- **Multi-device (v1.0.0)** will need one sender key per device. Nothing here makes that harder: the key is named by the sender's address (`SenderKeyName(groupId, address)`), and a device is part of the address.
- **Disappearing messages** work as for direct chats: `expires_in` is outside the ciphertext, and the timer setting is itself a message.
- **Safety numbers** don't change: SKDMs ride sessions that are verified one to one, so a changed identity key stops them like any other message.

## Plan

1. **#192 (server):** the `encrypted` flag and its rule (type `4` only), `features` on prekey upload and in the member list, `silent` for members in admins-only groups, `members_changed` on `group_updated`, no quote previews and joined-at history for encrypted groups, `409` for adding an unsupporting member. Migration; docs.
2. **#193 (app):** distribution, `group_key_request`, rotation, the "waiting for the key" state, the notices and the turn-on action. Round-trip, rotation, new-member and out-of-order tests, with two phones' worth of stores in one test.
3. **Roll out:** ship the server first (nothing changes for anyone), then the app. Turn on for the project's own groups first.
