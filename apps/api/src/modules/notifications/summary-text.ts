import type { DailySummary } from '../reporting/daily-summary.service';

export type SummaryLocale = 'en' | 'am';

/**
 * The end-of-day summary as a short message (FR-17, ADR-039).
 *
 * **The same lines, in the same order, as the phone's own "share" text**
 * (`DailySummary.toText` in `apps/mobile/lib/core/owner_reports.dart`). An owner who reads
 * the message at home and the screen in the shop must be reading one summary, so the
 * wording is copied, not paraphrased; a change to one is a change to both.
 *
 * Every line is a fact with its number. Nothing is rounded, and nothing is left out for
 * being zero where zero is the news.
 */
const TEXT: Record<SummaryLocale, Record<string, string>> = {
  en: {
    sales: 'Sales: {n} · {total}',
    split: 'Cash {cash} · Telebirr & other {other} · On credit {credit}',
    noTill: 'No till was opened.',
    short: 'Cash is short by {amount}.',
    balanced: 'Tills counted, none short: {n}.',
    over: 'Cash is over by {amount}.',
    open: 'Tills still open and not counted: {n}.',
    onShift: 'On shift: {names}',
    owed: 'Owed to you: {owed} (customers: {n}) · repaid {repaid}',
    payable: 'You owe suppliers: {owed} (suppliers: {n}) · paid {paid}',
    low: 'Running low: {n} — {names}',
    expiring: 'Batches expiring within 60 days: {n}',
    oversold: 'Batches sold below zero, needing a count: {n}',
    prices: 'Price changes: {n}',
    writeOffs: 'Stock write-offs: {n}',
    expired: 'Sales of expired stock: {n}',
    asOf: 'As of the last sync from the shop. A phone that is offline is not in these figures.',
  },
  am: {
    sales: 'ሽያጭ፦ {n} · {total}',
    split: 'ጥሬ ገንዘብ {cash} · ቴሌብርና ሌሎች {other} · በዱቤ {credit}',
    noTill: 'ካሻ አልተከፈተም።',
    short: 'ጥሬ ገንዘቡ በ{amount} ጎድሏል።',
    balanced: 'የተቆጠሩ ካሻዎች፣ የጎደለ የለም፦ {n}።',
    over: 'ጥሬ ገንዘቡ በ{amount} ተርፏል።',
    open: 'አሁንም ክፍት የሆኑና ያልተቆጠሩ ካሻዎች፦ {n}።',
    onShift: 'በሥራ ላይ የነበሩ፦ {names}',
    owed: 'የሚከፈልዎ፦ {owed} (ደንበኞች፦ {n}) · የተከፈለ {repaid}',
    payable: 'ለአቅራቢዎች ያለብዎት፦ {owed} (አቅራቢዎች፦ {n}) · የተከፈለ {paid}',
    low: 'እያለቁ ያሉ፦ {n} — {names}',
    expiring: 'በ60 ቀናት ውስጥ ጊዜያቸው የሚያልፍ ባቾች፦ {n}',
    oversold: 'ከዜሮ በታች የተሸጡ፣ ቆጠራ የሚያስፈልጋቸው ባቾች፦ {n}',
    prices: 'የዋጋ ለውጦች፦ {n}',
    writeOffs: 'የክምችት ስረዛዎች፦ {n}',
    expired: 'ጊዜው ያለፈ ክምችት ሽያጮች፦ {n}',
    asOf: 'ከሱቁ በመጨረሻ በተመሳሰለው መሠረት። ከመስመር ውጭ ያለ ስልክ በእነዚህ አኃዞች ውስጥ የለም።',
  },
};

const group = (n: number): string => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');

/** `9.00`, `18,740.00` — always with santim. Integer arithmetic only (G4). */
export function formatMoney(santim: number): string {
  const sign = santim < 0 ? '-' : '';
  const absolute = Math.abs(santim);
  const whole = Math.trunc(absolute / 100);
  return `${sign}${group(whole)}.${String(absolute % 100).padStart(2, '0')}`;
}

/** `ETB 18,740`, or `ETB 18,740.50` when there are santim — as the phone's headline does. */
export function formatEtbShort(santim: number): string {
  const sign = santim < 0 ? '-' : '';
  const absolute = Math.abs(santim);
  const whole = group(Math.trunc(absolute / 100));
  const cents = absolute % 100;
  return `ETB ${sign}${whole}${cents === 0 ? '' : `.${String(cents).padStart(2, '0')}`}`;
}

export function summaryText(
  summary: DailySummary,
  options: { shop: string; day: string; locale: SummaryLocale },
): string {
  const t = TEXT[options.locale] ?? TEXT.en;
  const f = (key: string, params: Record<string, string | number> = {}): string =>
    Object.entries(params).reduce(
      (text, [name, value]) => text.split(`{${name}}`).join(String(value)),
      t[key] ?? key,
    );

  const { sales, cash, credit, stock, attention } = summary;
  // Who had a till open, each name once, in the order they opened.
  const onShift = [...new Set(summary.shifts.map((s) => s.userName).filter(Boolean))];

  const lines: string[] = [
    `${options.shop} — ${options.day}`,
    f('sales', { n: sales.saleCount, total: formatEtbShort(sales.grossSantim) }),
    f('split', {
      cash: formatMoney(sales.cashSantim),
      other: formatMoney(sales.otherTenderSantim),
      credit: formatMoney(sales.creditSantim),
    }),
  ];

  if (cash.countedShifts === 0 && cash.openShifts === 0) lines.push(f('noTill'));
  else if (cash.shortageSantim > 0) {
    lines.push(f('short', { amount: formatMoney(cash.shortageSantim) }));
  } else if (cash.countedShifts > 0) lines.push(f('balanced', { n: cash.countedShifts }));
  // Never netted against a shortage: each is its own line (BR-17.2).
  if (cash.overageSantim > 0) lines.push(f('over', { amount: formatMoney(cash.overageSantim) }));
  if (cash.openShifts > 0) lines.push(f('open', { n: cash.openShifts }));
  if (onShift.length > 0) lines.push(f('onShift', { names: onShift.join(', ') }));

  lines.push(
    f('owed', {
      owed: formatMoney(credit.owedSantim),
      n: credit.customersOwing,
      repaid: formatMoney(credit.repaidSantim),
    }),
  );

  // Said only when there is something to say: most small shops pay on delivery.
  const payables = summary.payables;
  if (payables && (payables.owedSantim > 0 || payables.paidSantim > 0)) {
    lines.push(
      f('payable', {
        owed: formatMoney(payables.owedSantim),
        n: payables.suppliersOwed,
        paid: formatMoney(payables.paidSantim),
      }),
    );
  }

  if (stock.lowCount > 0) {
    lines.push(
      f('low', {
        n: stock.lowCount,
        names: stock.low
          .slice(0, 4)
          .map((r) => `${r.productName} (${r.onHand})`)
          .join(', '),
      }),
    );
  }
  if (stock.expiringBatches > 0) lines.push(f('expiring', { n: stock.expiringBatches }));
  if (stock.oversoldBatches > 0) lines.push(f('oversold', { n: stock.oversoldBatches }));
  if (attention.priceChanges > 0) lines.push(f('prices', { n: attention.priceChanges }));
  if (attention.stockWriteOffs > 0) lines.push(f('writeOffs', { n: attention.stockWriteOffs }));
  if (attention.expiredDispenses > 0) {
    lines.push(f('expired', { n: attention.expiredDispenses }));
  }

  // The one line the phone's screen says elsewhere (BR-8.1): a message read at home has no
  // screen around it to say how current it is.
  lines.push('', f('asOf'));
  return lines.join('\n');
}

/** The shop's own day: Ethiopia is UTC+3 all year, with no daylight saving. */
const ADDIS_OFFSET_MS = 3 * 60 * 60 * 1000;

/** The Addis Ababa calendar day containing [now], as a UTC window and a `YYYY-MM-DD` label. */
export function shopDay(now: Date): { from: Date; to: Date; day: string } {
  const local = new Date(now.getTime() + ADDIS_OFFSET_MS);
  const midnightLocal = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate());
  const from = new Date(midnightLocal - ADDIS_OFFSET_MS);
  return {
    from,
    to: new Date(from.getTime() + 86_400_000),
    day: new Date(midnightLocal).toISOString().slice(0, 10),
  };
}
