# ADR-033 — Backup and restore: an encrypted document of the phone's rows, restored by merging

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-15 (on-device backup and restore) — `07-v2-sellability-plan.md` §3.1
**Depends on:** ADR-002 (the outbox), ADR-006 (client-minted ids, idempotent writes),
ADR-018 (a corrupt local database), ADR-023 (offline sign-in)
**Not a controlled artifact:** nothing here changes the sync envelope, the server or a rule.
The file is a private format between one version of the app and another.

## Context

Everything that has synced is on the server. What exists **only on the phone** is the
outbox: the sales, receipts and cash-ups taken while the network was down — which this
product supports for days (NFR-1.1). A phone lost, stolen or broken in that state takes
them with it, and there is no other copy. That is the fear the backlog names: *"can I trust
my business to this?"*

The app deliberately switches off Android's own cloud backup (`allowBackup="false"`),
because a pharmacy's sales restored onto somebody else's phone is worse than no backup. So
if the owner is to have a copy, the app has to make it, and it has to be one they can read
on purpose and nobody can read by accident.

## Decision

### 1. A backup is a document of rows, not a copy of the database file

Every table this phone authored, plus the outbox, read as rows **inside one transaction**
and written as JSON. Not the SQLite file: a file copy is tied to the schema version and
journal state it was taken in, and the reliable way to snapshot one (`VACUUM INTO`) does not
exist on the SQLite that older Android versions ship. Rows restore into whatever version of
the app opens them; a column the restoring app does not have is dropped, one the file lacks
takes its default.

The catalogue and stock are copied too, for the owner's record of what the shelves held,
and are **never restored** (decision 3).

### 2. The file is encrypted with a passphrase the owner chooses

AES-256-GCM, key from PBKDF2-HMAC-SHA256 over the passphrase with a random salt and 150,000
rounds, run off the UI thread. The passphrase is at least eight characters and is typed
twice when a backup is made.

- The rounds are far more than the offline PIN's (ADR-023). That guess is rate-limited by
  the phone; a backup file is carried away and can be guessed at without limit.
- **A forgotten passphrase is an unopenable backup.** There is no recovery and no copy of
  the key anywhere, including with us. The screen says this before the first backup.
  Recovery would mean either holding the key (so the file is not private) or weakening it.
- A small header — pharmacy, branch, when, how many operations were unsynced — is readable
  without the passphrase, so the app can say whose backup it is before asking. It is bound
  to the encrypted part as associated data: edit it and the passphrase stops working.

A wrong passphrase and a tampered file produce the same message. Telling them apart would
tell an attacker which one they had.

### 3. A restore merges. It never replaces

The phone doing the restoring may have traded since the backup was made. Replacing its
database would destroy unsynced sales to recover unsynced sales. So a restore **adds**:

- each authored row the phone does not have (`INSERT OR IGNORE` by id);
- each queued operation it does not have, appended to its own queue **after** what is
  already there, in the order the file held them, numbered from this phone's sequence.

Nothing already on the phone is changed or removed, and reference data is not touched — an
old backup must not put last month's prices back.

This is safe to do, and to do twice, because of decisions already made:

- every operation carries the `opId` it was minted with; the queue will not hold one twice;
- if the lost phone did sync before it died, the server answers `duplicate` (ADR-006) and
  the sale is not counted again;
- the server orders by `terminalSeq` only *within* a pushed batch and has no uniqueness on
  it, so re-numbering restored operations on a different terminal cannot collide.

The restore is one local transaction: it happens entirely or not at all.

### 4. Only into the same pharmacy and the same branch

A queued operation is pushed under the branch the phone stands in. Restoring Bole's sales on
a phone in Piassa would book them to Piassa. A file from another branch or another pharmacy
is refused — before the passphrase is asked for — and the message names the branch it
belongs to.

### 5. The file leaves the phone through the share sheet

"Back up now" hands the file to the operating system's share sheet: the owner's own
Telegram, their email, a memory card. It is deliberately **not** saved to a folder on the
phone, because a backup on the phone it backs up is lost with it. Restore picks a file with
the system file picker. Neither needs a storage permission.

**Amended 2026-10-07, after a real phone.** The share sheet on the test handset offered
Telegram, Gmail, OneDrive, Bluetooth and nothing else — no memory card, no folder. "A memory
card" in the paragraph above was an assumption about what a share sheet contains, and it was
wrong. An owner without a chat app, or without a network that day, could not keep a backup
at all; and a backup could not be restored on the same handset to prove that restore works.

So "Back up now" now asks where the file should go: **send it** (the share sheet, as
before) or **save it as a file**, which opens the system's "save as" picker — a memory
card, a USB stick, a cloud drive that offers itself there, or a folder on the phone. The
original concern stands and is said on the screen: a backup saved only on the phone is lost
with it. The choice is the owner's; the warning is ours. Still no storage permission: the
picker grants access to the one file it creates.

### 6. Who, and when

The owner and a branch manager — the people who can already read the branch's sales. Decided
on the role alone, **not subject to the offline ceiling** (BR-2.3): a phone offline for
eight days is the phone whose queue most needs copying, and withdrawing the button then
would be taking the lifeboat away for being too far from shore.

Backups are made when a person taps the button. The screen leads with the number that says
whether it matters now — how many operations exist only on this phone.

## Consequences

- **This is a copy the owner must remember to make.** It protects against a lost phone only
  if a backup was made *after* the sales it should protect and sent somewhere else. An
  automatic backup would need somewhere to send it without a network, which is the problem.
  Settings shows the row in amber whenever something is unsynced.
- **A restored operation can still be rejected by the server** — a shift that was open on
  the lost phone, restored while the same person has one open on the new phone, for
  instance. It is then parked for attention like any rejected operation (ADR-012 §2), not
  lost.
- **A row the new phone cannot hold is skipped locally but its operation is still
  restored.** The server gets the transaction; only that phone's own history page lacks the
  line.
- A backup does not carry the sign-in. A replacement phone signs in online first (ADR-023),
  then restores.
- The app gains a file picker and an encryption library. No new permission.

## Alternatives rejected

- **Turn Android's cloud backup back on.** It is automatic, which is its appeal, and it is
  unencrypted from the app's point of view, restores onto any phone the Google account
  signs in to, and replaces rather than merges.
- **Copy the SQLite file.** See decision 1; and a restore could only replace.
- **Restore replaces the database, after a warning.** A warning is not a safeguard against
  losing the day's takings on the phone in the owner's hand.
- **An unencrypted file.** It is going to be sent through a chat app, and it is every sale
  the branch has made.
- **A recovery key held by the platform.** Then the platform can read every pharmacy's
  backups, which nobody asked for and nobody should want.
- **Back up to the server.** What needs backing up is, by definition, what could not reach
  the server.
