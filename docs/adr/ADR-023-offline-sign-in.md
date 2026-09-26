# ADR-023 — Offline sign-in with a cached PIN

**Status:** Accepted · **Date:** 2026-09-26
**Implements:** AC-2.2, BR-2.3, SRS §FR-2 preconditions ("for offline login, a prior
successful online login on that terminal")
**Constrained by:** NFR-4.2, ADR-017, ADR-019

## Context

AC-2.2 — *an offline terminal within the supported window, a cashier logs in with cached
PIN, login succeeds and POS is usable* — was marked covered by the session surviving a
restart. It was not: once someone signed out, signing back in needed the server. In a
pharmacy where two cashiers share a phone and the power is out, the second shift could not
open the till at all. The storage seam for a "PIN verifier" had been reserved since Phase 0
and never filled.

## Decision

1. **Each successful online sign-in caches, for that user on that device only,** a salted
   PBKDF2-HMAC-SHA256 digest of the secret (20,000 rounds, 16-byte random salt) and the
   session the server issued. The secret itself is never stored. Everything is in platform
   secure storage (Android Keystore, iOS Keychain).

2. **Offline sign-in restores the server's own grant, never a new one.** The same PIN
   reproduces the digest; the cached session comes back as it was issued, including its
   refresh token, and the next sync refreshes or refuses it exactly as for any session
   (ADR-019). A deactivated user is refused at that refresh.

3. **BR-2.3 bounds it.** Past the cached `offlineValidUntil` the sign-in is refused with a
   message that says to connect once. A session renewed while online rewrites the cache, so
   the window moves with real use.

4. **Five wrong PINs lock offline sign-in on the device for fifteen minutes.** The server's
   throttle (ADR-017) cannot see a phone with no network, and a four-digit PIN is ten
   thousand guesses. A signed-in till keeps selling throughout; only new sign-ins wait.

5. **Only a genuine transport failure falls back.** A 401 or 429 from a reachable server is
   the server's answer and is shown as such; the cache is never a way around a refusal.

## Consequences

- Someone holding an unlocked, rooted phone could attack the cached digest offline. PBKDF2
  makes each guess cost time, the digest never leaves secure storage on an intact device,
  and the window bounds how long it stays useful. Accepted for V1; a hardware-backed key
  per user is the upgrade path.
- Tests: `apps/mobile/test/unit/offline_credentials_test.dart` (right PIN, wrong PIN,
  unknown user, window expiry, lockout and recovery, the PIN never at rest, an RFC PBKDF2
  vector) and `apps/mobile/test/widget/login_screen_test.dart` (the no-network path end to
  end).
