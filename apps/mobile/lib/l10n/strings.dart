import '../core/ethiopian_date.dart';

/// Amharic and English UI strings (FR-10, BR-10.1, AC-10.1).
///
/// A plain map rather than ARB files and code generation. At this size that is less
/// machinery for the same result, and it keeps the two languages **side by side in one
/// file** — which is what actually stops a string being added in English and forgotten in
/// Amharic. A missing key is a compile error, not a screen that silently falls back.
///
/// Amharic is not a translation of English here: the counter vocabulary was chosen for what
/// a pharmacist would say, not for what a dictionary returns. Where a term is genuinely used
/// in English in Ethiopian pharmacies, it stays English rather than being rendered into
/// something nobody says out loud.
class Strings {
  const Strings._(this.locale, this._values);

  final String locale;
  final Map<String, String> _values;

  static const supportedLocales = ['en', 'am'];

  static const Strings en = Strings._('en', _en);
  static const Strings am = Strings._('am', _am);

  /// Falls back to English for an unknown locale rather than throwing: a cached locale from
  /// an older build must not stop the till from opening.
  static Strings of(String locale) => locale == 'am' ? am : en;

  String get(String key) => _values[key] ?? _en[key] ?? key;

  bool get isAmharic => locale == 'am';

  /// Renders a stored UTC instant in the Ethiopian calendar (BR-10.2).
  ///
  /// Presentation only — storage stays UTC ISO-8601 (AC-10.2), and no calendar logic ever
  /// reaches the domain or the database.
  String date(DateTime instant) =>
      formatEthiopian(instantToEthiopian(instant), locale: locale);

  /// `13:45` in both languages. Ethiopian clock time, which starts the day at dawn, is a
  /// genuine difference in how people speak — but tills and receipts in Ethiopian pharmacies
  /// use the 24-hour clock, so this follows practice rather than tradition.
  String time(DateTime instant) {
    final local = instant.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

const Map<String, String> _en = {
  'app.name': 'PharmaEt',
  'app.tagline': 'Sign in once online. The till keeps working after that.',
  'login.pharmacyCode': 'Pharmacy code',
  'login.username': 'Username',
  'login.pin': 'PIN',
  'login.signIn': 'Sign in',
  'login.signingIn': 'Signing in…',
  'login.failed': 'Could not sign in. Check the details and try again.',
  'pos.title': 'Sell',
  'pos.total': 'Total',
  'pos.takeCash': 'Take cash & commit',
  'pos.perUnit': 'per',
  'pos.controlled': 'Controlled · ledger-dispensed',
  'pos.controlledLater':
      'Controlled dispensing arrives with the compliance phase.',
  'pos.noCatalog': 'No catalog yet',
  'pos.noCatalogHint':
      'Tap the sync chip to pull products and stock from the server.',
  'pos.offlineBanner':
      'Offline — sales are saved here and will sync. Keep selling.',
  'pos.saleCommitted': 'Sale committed',
  'pos.savedLocally': 'saved on this device',
  'shift.noTill': 'No till open — sales will not be attributed to a shift',
  'shift.openTill': 'OPEN TILL',
  'shift.openTitle': 'Open till',
  'shift.openingFloat': 'Opening float (ETB)',
  'shift.openingFloatHint':
      'How much cash is in the drawer before trading? It is counted as part of the '
          'expected total at close.',
  'shift.cancel': 'Cancel',
  'shift.open': 'Open',
  'cashup.title': 'Cash up',
  'cashup.thisShift': 'This shift',
  'cashup.opened': 'Opened',
  'cashup.sales': 'Sales',
  'cashup.float': 'Opening float',
  'cashup.countDrawer': 'Count the drawer',
  'cashup.countHint':
      'Enter what is actually there. The expected figure appears once you have counted.',
  'cashup.counted': 'Counted cash (ETB)',
  'cashup.note': 'Note (optional)',
  'cashup.noteHint': 'Anything that explains a difference',
  'cashup.record': 'Record count & close shift',
  'cashup.recording': 'Recording…',
  'cashup.expected': 'Expected',
  'cashup.difference': 'Difference',
  'cashup.balanced': 'Balanced',
  'cashup.short': 'Short',
  'cashup.over': 'Over',
  'cashup.closedOk': 'Recorded and queued. The shift is closed.',
  'cashup.closedVariance':
      'Recorded against you and this shift, and queued for the office. Nothing is '
          'blocked — the difference is what matters, not hiding it.',
  'cashup.unsyncedWarning':
      'sale(s) have not synced yet. Counting now is fine — the '
          'office will see both figures.',
  'sync.synced': 'Synced',
  'sync.syncing': 'Syncing…',
  'sync.upToDate': 'Up to date',
  'sync.waiting': 'waiting',
  'sync.queued': 'queued',
  'sync.needsAttention': 'need attention',
  'settings.language': 'Language',
  'settings.signOut': 'Sign out',
};

const Map<String, String> _am = {
  'app.name': 'ፋርማኢት',
  'app.tagline': 'አንድ ጊዜ በኢንተርኔት ይግቡ። ከዚያ በኋላ ካሻ መስራቱን ይቀጥላል።',
  'login.pharmacyCode': 'የፋርማሲ ኮድ',
  'login.username': 'የተጠቃሚ ስም',
  'login.pin': 'የይለፍ ቁጥር',
  'login.signIn': 'ግባ',
  'login.signingIn': 'በመግባት ላይ…',
  'login.failed': 'መግባት አልተቻለም። መረጃውን አረጋግጠው እንደገና ይሞክሩ።',
  'pos.title': 'ሽያጭ',
  'pos.total': 'ጠቅላላ',
  'pos.takeCash': 'ገንዘብ ተቀብሎ መዝግብ',
  'pos.perUnit': 'በ',
  'pos.controlled': 'ቁጥጥር የሚደረግበት · በሌጀር የሚሰጥ',
  'pos.controlledLater': 'ቁጥጥር የሚደረግባቸው መድኃኒቶች በተገዢነት ምዕራፍ ይጀምራሉ።',
  'pos.noCatalog': 'እስካሁን ካታሎግ የለም',
  'pos.noCatalogHint': 'ምርቶችንና ክምችትን ለማምጣት የማመሳሰያ ምልክቱን ይንኩ።',
  'pos.offlineBanner': 'ከመስመር ውጭ — ሽያጮች እዚህ ተቀምጠዋል፤ ይመሳሰላሉ። መሸጥዎን ይቀጥሉ።',
  'pos.saleCommitted': 'ሽያጩ ተመዝግቧል',
  'pos.savedLocally': 'በዚህ መሣሪያ ተቀምጧል',
  'shift.noTill': 'ካሻ አልተከፈተም — ሽያጮች ከፈረቃ ጋር አይያያዙም',
  'shift.openTill': 'ካሻ ክፈት',
  'shift.openTitle': 'ካሻ መክፈት',
  'shift.openingFloat': 'የመነሻ ገንዘብ (ብር)',
  'shift.openingFloatHint':
      'ከመሸጥ በፊት በሳጥኑ ውስጥ ምን ያህል ገንዘብ አለ? በመዝጊያ ሰዓት ከሚጠበቀው ጠቅላላ ጋር ይቆጠራል።',
  'shift.cancel': 'ሰርዝ',
  'shift.open': 'ክፈት',
  'cashup.title': 'የገንዘብ ቆጠራ',
  'cashup.thisShift': 'ይህ ፈረቃ',
  'cashup.opened': 'የተከፈተበት',
  'cashup.sales': 'ሽያጮች',
  'cashup.float': 'የመነሻ ገንዘብ',
  'cashup.countDrawer': 'ሳጥኑን ይቁጠሩ',
  'cashup.countHint': 'በእውነት ያለውን ያስገቡ። የሚጠበቀው መጠን ከቆጠሩ በኋላ ይታያል።',
  'cashup.counted': 'የተቆጠረ ገንዘብ (ብር)',
  'cashup.note': 'ማስታወሻ (አማራጭ)',
  'cashup.noteHint': 'ልዩነቱን የሚያብራራ ማንኛውም ነገር',
  'cashup.record': 'ቆጠራውን መዝግቦ ፈረቃውን ዝጋ',
  'cashup.recording': 'በመመዝገብ ላይ…',
  'cashup.expected': 'የሚጠበቅ',
  'cashup.difference': 'ልዩነት',
  'cashup.balanced': 'ተመጣጥኗል',
  'cashup.short': 'ጎድሏል',
  'cashup.over': 'ተርፏል',
  'cashup.closedOk': 'ተመዝግቦ ወረፋ ላይ ነው። ፈረቃው ተዘግቷል።',
  'cashup.closedVariance':
      'በእርስዎና በዚህ ፈረቃ ስም ተመዝግቦ ወደ ቢሮ ወረፋ ገብቷል። ምንም አልታገደም — ልዩነቱ መደበቅ ሳይሆን '
          'መታወቅ ነው ያለበት።',
  'cashup.unsyncedWarning':
      'ሽያጭ(ዎች) እስካሁን አልተመሳሰሉም። አሁን መቁጠር ችግር የለውም — ቢሮው ሁለቱንም '
          'አኃዞች ያያል።',
  'sync.synced': 'ተመሳስሏል',
  'sync.syncing': 'በማመሳሰል ላይ…',
  'sync.upToDate': 'ወቅታዊ ነው',
  'sync.waiting': 'በመጠባበቅ ላይ',
  'sync.queued': 'በወረፋ',
  'sync.needsAttention': 'ትኩረት ይሻሉ',
  'settings.language': 'ቋንቋ',
  'settings.signOut': 'ውጣ',
};
