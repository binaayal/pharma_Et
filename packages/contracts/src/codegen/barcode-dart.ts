import { BARCODE_VECTORS } from '../entities.js';

/**
 * Emits the barcode canonicalisation vectors as Dart (FR-13, ADR-031).
 *
 * The same arrangement as the Ethiopian calendar (ADR-014): `canonicalBarcode` is written
 * twice, because the till has to match a scan with no network, and this table is what proves
 * the two agree. If they did not, a product linked on one side would not be found by a scan
 * on the other — and nothing would fail, the counter would simply say "unknown barcode".
 */
export function emitBarcodeVectorsDart(contractVersion: string): string {
  const rows = BARCODE_VECTORS.map(
    ([input, canonical]) => `  (${JSON.stringify(input)}, ${JSON.stringify(canonical)}),`,
  ).join('\n');

  return `// GENERATED FILE — DO NOT EDIT.
//
// Barcode canonicalisation vectors, generated from packages/contracts/src/entities.ts by
// \`pnpm gen:contracts\`. \`canonicalBarcode\` is implemented separately in each language;
// this table is what proves the two agree.
//
// Contract version: ${contractVersion}

/// (as scanned, as stored and compared)
const List<(String, String)> kBarcodeVectors = [
${rows}
];
`;
}
