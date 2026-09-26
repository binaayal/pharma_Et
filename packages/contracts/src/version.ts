/**
 * The sync contract version.
 *
 * Versioned INDEPENDENTLY of the apps (ADR-009, docs/06-delivery-plan.md §10). An offline
 * terminal may reconnect days later still speaking an older contract, so the server must
 * serve the current version AND at least the previous one (N-1) for a window greater than
 * the offline ceiling plus margin.
 *
 * Bump MINOR for additive, backward-compatible changes. Bump MAJOR only with an ADR, dual
 * support in the server, and an N-1 compatibility test — see docs/06-delivery-plan.md §7.
 */
export const CONTRACT_VERSION = '1.4.0' as const;

/**
 * Contract versions the server must still accept. **Never shrink this without an ADR.**
 *
 * A terminal offline for the supported window reconnects speaking whatever it shipped with,
 * and dropping its version from this list means its queued transactions have nowhere to go.
 * Entries leave only when every client that could be running them is provably gone — which
 * is a decision about real pharmacies, not about tidiness.
 *
 * 1.0.0 — sale, goods_receipt
 * 1.1.0 — adds shift, cash_up (ADR-012 §4)
 * 1.2.0 — adds stock_adjustment (ADR-012 §4)
 * 1.3.0 — adds sale line `expiryOverrideBy` (E-4.2, ADR-020)
 * 1.4.0 — adds controlled_dispense, controlled_adjustment (FR-4 §4a, FR-6; ADR-024)
 */
export const SUPPORTED_CONTRACT_VERSIONS = ['1.0.0', '1.1.0', '1.2.0', '1.3.0', '1.4.0'] as const;

/** Sent by clients as `X-Contract-Version`; the server rejects anything unsupported. */
export const CONTRACT_VERSION_HEADER = 'x-contract-version';
