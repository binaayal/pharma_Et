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
export const CONTRACT_VERSION = '1.7.0' as const;

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
 * 1.5.0 — adds `packSize`/`packName` to sale and receipt lines, `packs` to a pulled
 *         product (FR-11, ADR-030)
 * 1.6.0 — adds `barcodes` to a pulled product (FR-13, ADR-031)
 * 1.7.0 — adds customer and credit_payment operations, the `credit` payment method and
 *         `customerId` on a sale, `customers` on a pull (FR-16, ADR-034)
 */
export const SUPPORTED_CONTRACT_VERSIONS = [
  '1.0.0',
  '1.1.0',
  '1.2.0',
  '1.3.0',
  '1.4.0',
  '1.5.0',
  '1.6.0',
  '1.7.0',
] as const;

/** Sent by clients as `X-Contract-Version`; the server rejects anything unsupported. */
export const CONTRACT_VERSION_HEADER = 'x-contract-version';
