# ADR-018 — A corrupt local database quarantines and continues

**Status:** Accepted · 2026-09-23
**Constrained by:** NFR-1.2 (*"the app never hard-blocks a core sale"*), NFR-1.3 (local
durability), BR-4.1, `05-qa-and-test-strategy.md` §7 (*"corrupt-then-restart; assert
durability and idempotent recovery"*)
**Relates to:** ADR-002 (offline-first), ADR-006 (client-generated ids)

---

## Context

The terminal's SQLite file is the source of truth for the counter. Every core-loop write
lands there first and is durable before any network attempt.

The target market runs cheap Android hardware on unreliable mains power. A write interrupted
at the wrong moment produces a file SQLite refuses to open — `SQLITE_NOTADB` (26) or
`SQLITE_CORRUPT` (11). This is not an exotic scenario; it is Tuesday.

Until now `LocalDb.open` propagated that error. The app could not start. **A pharmacy whose
till will not open has no workaround at all** — no paper fallback is configured, no second
terminal is assumed, and the customer is standing there. `docs/05` §7 asked for this case to
be tested and it never was, so the behaviour was never anybody's decision; it was the default
that fell out of not catching an exception.

## The decision

**On a corruption error, rename the unreadable file aside, create a fresh database, and open.
Tell the user, loudly, once.**

Three parts, each load-bearing:

1. **Continue.** The terminal opens and trades. This is the product's standing tie-breaker:
   a pharmacy that cannot sell is the worst outcome this system can produce, and it is worse
   than the loss being contained here.

2. **Quarantine, never delete.** The file is renamed to `pharmaet.db.corrupt-<utc-timestamp>`
   and kept, along with any `-journal`, `-wal` and `-shm` siblings. It holds whatever had not
   yet synced, and it may be partially salvageable by a later version or by hand. Deleting it
   would turn a recoverable incident into a certain one. The timestamp means a second
   corruption cannot overwrite the evidence of the first — which matters most precisely when
   repeated failures reveal the storage itself is dying.

3. **Say so, and keep saying it.** The quarantine is recorded in the *replacement* database
   and surfaced as an interrupting screen that must be acknowledged. Recorded rather than
   held in memory, because otherwise force-closing the app would dismiss the warning
   permanently — and force-closing is an entirely ordinary response to a till that has just
   behaved strangely. The person most likely to restart their way past it is the one who most
   needs to see it. Passive would not do: from the moment it recovers the terminal works
   perfectly, and a fresh database looks exactly like a quiet day rather than like missing
   records. The notice names the quarantined path in full, so it can be read down a phone to
   whoever is helping, and it tells the cashier to check the last cash-up against the takings
   actually in the drawer.

### What this costs, stated plainly

**Unsynced sales on that device are lost to the running system.** They exist only inside the
quarantined file. A pharmacy that synced this morning loses at most this morning's takings;
one that has been offline for three days loses three days.

That is a real loss and it is the wrong trade in most software. It is the right trade here
only because the alternative is a till that will not open, and because the loss is bounded by
how recently the terminal synced — a quantity the pharmacy controls and the sync chip already
shows them.

## Alternatives rejected

**Propagate the error (the previous behaviour).** The pharmacy cannot trade, and no amount of
preserved data is worth that. It also preserves nothing in practice: nobody recovers a file
they cannot reach through an app that will not start.

**Attempt automatic repair (`PRAGMA integrity_check`, dump-and-reload).** Slow, unreliable on
a header-corrupted file, and it runs at the worst possible moment — app launch, with a queue
at the counter. Worse, a partial recovery yields a database that *looks* complete. A silently
half-recovered ledger is more dangerous than an obviously missing one. Salvage belongs in a
tool run deliberately, against the quarantined file, not on the startup path.

**Keep a rolling local backup and restore from it.** Genuinely better, and not free: it needs
a backup schedule, space on a device chosen for being cheap, and its own corruption story.
Worth revisiting; it does not change this decision, because a restore path still needs
somewhere to stand when the backup is also unreadable.

## Consequences

- `LocalDb.open` always returns a database or throws something that is *not* corruption.
  Disk-full and permission errors still propagate deliberately — quarantining on those would
  rename away a perfectly good database and **cause** the loss this exists to contain. The
  match is therefore narrow, on SQLite's own wording, and a guardian test asserts a
  non-corruption failure does not trigger it.
- Corruption detection matches on message text rather than error code, because the code is
  not exposed uniformly across the sqflite implementations in use (the device plugin and the
  FFI factory the tests run on). A check that worked in one and not the other would make the
  suite assert something the handset does not do.
- `apps/mobile/test/guardian/g7_chaos_test.dart` covers `docs/05` §7's corrupt-then-restart
  case, which had no coverage before this ADR.
- Quarantined files are never cleaned up automatically. On a device failing repeatedly they
  accumulate, which is the correct bias: the alternative is deleting evidence of a fault. A
  future version may offer removal from a settings screen, after they have been recovered.
