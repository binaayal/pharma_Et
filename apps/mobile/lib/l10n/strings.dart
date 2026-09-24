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

  /// A string with `{name}` placeholders filled in — `f('count.fewer', {'n': 2})`.
  ///
  /// Placeholders rather than concatenation, because word order is not shared: Amharic puts
  /// the number in the middle of "{n} fewer than the system thought", not at the front.
  String f(String key, Map<String, Object> params) => params.entries
      .fold(get(key), (text, p) => text.replaceAll('{${p.key}}', '${p.value}'));

  bool get isAmharic => locale == 'am';

  /// Renders a stored UTC instant in the Ethiopian calendar (BR-10.2).
  ///
  /// Presentation only — storage stays UTC ISO-8601 (AC-10.2), and no calendar logic ever
  /// reaches the domain or the database.
  String date(DateTime instant) =>
      formatEthiopian(instantToEthiopian(instant), locale: locale);

  /// Renders a **calendar date** — `2027-09-30`, an expiry printed on a box — in the
  /// Ethiopian calendar.
  ///
  /// Not [date]. That one takes an instant and reads it in UTC, which is right for a
  /// timestamp and wrong for a date: `DateTime.parse('2027-09-30')` is local midnight, and in
  /// Addis Ababa (UTC+3) local midnight is 21:00 UTC the day before. Every expiry on a real
  /// phone showed one day early; CI runs in UTC, where the two agree, so no test saw it.
  String calendarDate(String isoDate) {
    final parts = isoDate.substring(0, 10).split('-').map(int.parse).toList();
    return formatEthiopian(toEthiopian(parts[0], parts[1], parts[2]),
        locale: locale);
  }

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
  'login.password': 'Password',
  'login.usePassword': 'Use a password',
  'login.usePin': 'Use a PIN',
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
  'branch.title': 'Which branch is this?',
  'branch.hint':
      'Sales on this device are recorded against the branch you choose. It is asked once, and kept after sign-out.',
  'branch.none':
      'This pharmacy has no branch yet. Create one in the owner console, then sign in again.',
  'branch.unreachable':
      'Could not load this pharmacy\'s branches. Connect to the internet once to choose this device\'s branch.',
  'branch.retry': 'Try again',
  'common.cancel': 'Cancel',
  'common.continue': 'Continue',
  'stock.menu': 'Stock',
  'stock.receive': 'Receive stock',
  'stock.count': 'Count stock',
  'stock.lotExpires': 'Lot {lot} · expires {date}',
  'receive.supplier': 'Supplier',
  'receive.supplierHint': 'Free text in this version',
  'receive.lines': 'Lines',
  'receive.add': 'Add',
  'receive.noProducts':
      'No products yet — sync to pull the catalog before receiving stock.',
  'receive.lineCost': '{qty} × {cost} cost',
  'receive.totalCost': 'Total cost',
  'receive.saving': 'Saving…',
  'receive.record': 'Record receipt',
  'receive.savedHint':
      'Saved on this device and queued. Stock is available to sell immediately, whether or not there is a network.',
  'receive.done': 'Received {count} line(s) · saved on this device',
  'receive.addLineTitle': 'Add a line',
  'receive.product': 'Product',
  'receive.lotNo': 'Lot / batch number',
  'receive.expiry': 'Expiry date (as printed on the box)',
  'receive.qty': 'Quantity',
  'receive.unitCost': 'Unit cost (ETB)',
  'receive.addLine': 'Add line',
  'count.oversold':
      '{n} batch(es) show less than zero. The shelf and the system disagree — count them first.',
  'count.empty': 'No stock on this device yet. Sync, or receive a delivery.',
  'count.systemSays': 'Lot {lot} · system says {qty}',
  'count.howMany': 'How many are actually there?',
  'count.howManyHint': 'Count the shelf. What you find is what is recorded.',
  'count.fewer': '{n} fewer than the system thought',
  'count.more': '{n} more than the system thought',
  'count.reason': 'Reason',
  'count.noteRequired': 'Note (required)',
  'count.noteOptional': 'Note (optional)',
  'count.noteNeeded': 'This reason needs an explanation',
  'count.noteHint': 'Anything worth recording',
  'count.record': 'Record count',
  'reason.recount': 'Recount',
  'reason.damage': 'Damaged',
  'reason.expiryWriteoff': 'Expired — written off',
  'reason.theftOrLoss': 'Theft or loss',
  'reason.receiptCorrection': 'Receipt entered wrongly',
  'reason.other': 'Other',
  'expired.title': 'This stock has expired',
  'expired.body':
      'The only {product} on this shelf is lot {lot}, which expired on {date}.',
  'expired.mayOverride': 'Dispensing it is recorded against your name.',
  'expired.cannotOverride':
      'You cannot authorise dispensing expired stock. Ask the manager or owner. You can still complete the sale — it will not be recorded against this lot.',
  'expired.doNot': 'Do not dispense it',
  'expired.authorise': 'Authorise — dispense it',
  'sync.signInAgain': 'Sign in again',
  'sync.status': 'Sync status',
  'recovery.title': 'This terminal had to start a new local record',
  'recovery.body':
      'The data stored on this device could not be read — usually after a power cut or a storage fault. Anything that had already reached the server is safe and will come back when you sync.',
  'recovery.lost':
      'Sales taken on this device that had NOT yet synced are not in the new record. Tell the owner, and check the last cash-up against the takings you actually have.',
  'recovery.kept': 'The old record has been kept, not deleted:',
  'recovery.ack': 'I understand — continue selling',
};

const Map<String, String> _am = {
  'app.name': 'ፋርማኢት',
  'app.tagline': 'አንድ ጊዜ በኢንተርኔት ይግቡ። ከዚያ በኋላ ካሻ መስራቱን ይቀጥላል።',
  'login.pharmacyCode': 'የፋርማሲ ኮድ',
  'login.username': 'የተጠቃሚ ስም',
  'login.pin': 'የይለፍ ቁጥር',
  'login.password': 'የይለፍ ቃል',
  'login.usePassword': 'በይለፍ ቃል ይግቡ',
  'login.usePin': 'በፒን ይግቡ',
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
  'branch.title': 'ይህ የትኛው ቅርንጫፍ ነው?',
  'branch.hint':
      'በዚህ መሣሪያ የሚደረጉ ሽያጮች በሚመርጡት ቅርንጫፍ ይመዘገባሉ። አንድ ጊዜ ብቻ ይጠየቃል፤ ከወጡም በኋላ ይቆያል።',
  'branch.none':
      'ይህ ፋርማሲ እስካሁን ቅርንጫፍ የለውም። በባለቤት መቆጣጠሪያው ቅርንጫፍ ይፍጠሩ፤ ከዚያ እንደገና ይግቡ።',
  'branch.unreachable':
      'የዚህን ፋርማሲ ቅርንጫፎች መጫን አልተቻለም። የዚህን መሣሪያ ቅርንጫፍ ለመምረጥ አንድ ጊዜ ከኢንተርኔት ጋር ይገናኙ።',
  'branch.retry': 'እንደገና ይሞክሩ',
  'common.cancel': 'ሰርዝ',
  'common.continue': 'ቀጥል',
  'stock.menu': 'ክምችት',
  'stock.receive': 'ዕቃ መረከብ',
  'stock.count': 'ክምችት መቁጠር',
  'stock.lotExpires': 'ሎት {lot} · የሚያበቃው {date}',
  'receive.supplier': 'አቅራቢ',
  'receive.supplierHint': 'በዚህ ስሪት ነጻ ጽሑፍ',
  'receive.lines': 'መስመሮች',
  'receive.add': 'ጨምር',
  'receive.noProducts': 'እስካሁን ምርቶች የሉም — ዕቃ ከመረከብዎ በፊት ካታሎጉን ለማምጣት ያመሳስሉ።',
  'receive.lineCost': '{qty} × {cost} ወጪ',
  'receive.totalCost': 'ጠቅላላ ወጪ',
  'receive.saving': 'በማስቀመጥ ላይ…',
  'receive.record': 'ርክክቡን መዝግብ',
  'receive.savedHint':
      'በዚህ መሣሪያ ተቀምጦ ወረፋ ገብቷል። ኔትወርክ ቢኖርም ባይኖርም ዕቃው ወዲያውኑ ለሽያጭ ዝግጁ ነው።',
  'receive.done': '{count} መስመር(ዎች) ተረክበዋል · በዚህ መሣሪያ ተቀምጧል',
  'receive.addLineTitle': 'መስመር ጨምር',
  'receive.product': 'ምርት',
  'receive.lotNo': 'የሎት / ባች ቁጥር',
  'receive.expiry': 'የሚያበቃበት ቀን (በሳጥኑ ላይ እንደታተመው)',
  'receive.qty': 'ብዛት',
  'receive.unitCost': 'የአንዱ ዋጋ (ብር)',
  'receive.addLine': 'መስመሩን ጨምር',
  'count.oversold':
      '{n} ባች(ዎች) ከዜሮ በታች ያሳያሉ። መደርደሪያውና ሲስተሙ አይስማሙም — መጀመሪያ እነሱን ይቁጠሩ።',
  'count.empty': 'በዚህ መሣሪያ ላይ እስካሁን ክምችት የለም። ያመሳስሉ ወይም ዕቃ ይረከቡ።',
  'count.systemSays': 'ሎት {lot} · ሲስተሙ {qty} ይላል',
  'count.howMany': 'በእውነት ስንት አሉ?',
  'count.howManyHint': 'መደርደሪያውን ይቁጠሩ። ያገኙት ነው የሚመዘገበው።',
  'count.fewer': 'ሲስተሙ ካሰበው {n} ያንሳል',
  'count.more': 'ሲስተሙ ካሰበው {n} ይበልጣል',
  'count.reason': 'ምክንያት',
  'count.noteRequired': 'ማስታወሻ (ግዴታ)',
  'count.noteOptional': 'ማስታወሻ (አማራጭ)',
  'count.noteNeeded': 'ይህ ምክንያት ማብራሪያ ያስፈልገዋል',
  'count.noteHint': 'መመዝገብ ያለበት ማንኛውም ነገር',
  'count.record': 'ቆጠራውን መዝግብ',
  'reason.recount': 'እንደገና መቁጠር',
  'reason.damage': 'ተበላሽቷል',
  'reason.expiryWriteoff': 'ጊዜው አልፏል — ተሰርዟል',
  'reason.theftOrLoss': 'ስርቆት ወይም መጥፋት',
  'reason.receiptCorrection': 'ርክክቡ በስህተት ገብቷል',
  'reason.other': 'ሌላ',
  'expired.title': 'ይህ ክምችት ጊዜው አልፎበታል',
  'expired.body':
      'በዚህ መደርደሪያ ያለው ብቸኛው {product} ሎት {lot} ሲሆን ጊዜው ያለፈው {date} ነው።',
  'expired.mayOverride': 'መስጠቱ በእርስዎ ስም ይመዘገባል።',
  'expired.cannotOverride':
      'ጊዜው ያለፈበትን ክምችት እንዲሰጥ መፍቀድ አይችሉም። ሥራ አስኪያጁን ወይም ባለቤቱን ይጠይቁ። ሽያጩን አሁንም መጨረስ ይችላሉ — ከዚህ ሎት ጋር አይመዘገብም።',
  'expired.doNot': 'አይሰጥ',
  'expired.authorise': 'ፍቀድ — ይሰጥ',
  'sync.signInAgain': 'እንደገና ይግቡ',
  'sync.status': 'የማመሳሰል ሁኔታ',
  'recovery.title': 'ይህ ተርሚናል አዲስ የአካባቢ መዝገብ መጀመር ነበረበት',
  'recovery.body':
      'በዚህ መሣሪያ የተቀመጠው መረጃ ሊነበብ አልቻለም — ብዙውን ጊዜ ከመብራት መቋረጥ ወይም ከማከማቻ ብልሽት በኋላ። ቀድሞ ሰርቨሩ የደረሰ ማንኛውም ነገር ደህና ነው፤ ሲያመሳስሉ ይመለሳል።',
  'recovery.lost':
      'በዚህ መሣሪያ የተወሰዱና ገና ያልተመሳሰሉ ሽያጮች በአዲሱ መዝገብ ውስጥ የሉም። ለባለቤቱ ይንገሩ፤ የመጨረሻውን የገንዘብ ቆጠራ በእጅዎ ካለው ገቢ ጋር ያመሳክሩ።',
  'recovery.kept': 'የድሮው መዝገብ ተጠብቋል እንጂ አልተሰረዘም፦',
  'recovery.ack': 'ተረድቻለሁ — መሸጥ ቀጥል',
};
