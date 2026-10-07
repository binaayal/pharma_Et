import '../core/payment_accounts.dart';

/// The user guide (FR-10, BR-10.1): what a pharmacy does in the app, step by step, in
/// Amharic and English.
///
/// Kept out of [Strings] on purpose. That map holds short UI labels; this is prose in
/// numbered steps, and flattening it into `help.topic3.step4` keys would make the two
/// languages impossible to read side by side. The same guarantee holds instead through
/// `help_content_test.dart`: every topic exists in both languages, with the same id, icon
/// and number of steps, so a step added in English and forgotten in Amharic fails CI.
///
/// Written for the person at the counter, not for us: it names the buttons as the app
/// labels them, and it never explains a design decision.
class HelpTopic {
  const HelpTopic({
    required this.id,
    required this.icon,
    required this.title,
    required this.summary,
    required this.steps,
    this.tip,
  });

  /// Stable across languages, so a screen can deep-link to a topic (`payment`).
  final String id;

  /// A Material icon code point name, resolved by the screen. A string rather than
  /// `IconData` so this file stays free of Flutter imports and testable on the plain VM.
  final String icon;
  final String title;
  final String summary;
  final List<String> steps;
  final String? tip;
}

class HelpGuide {
  const HelpGuide({
    required this.title,
    required this.intro,
    required this.searchHint,
    required this.noMatch,
    required this.contactTitle,
    required this.contactBody,
    required this.topics,
  });

  final String title;
  final String intro;
  final String searchHint;
  final String noMatch;
  final String contactTitle;
  final String contactBody;
  final List<HelpTopic> topics;

  static HelpGuide of(String locale) => locale == 'am' ? am : en;

  static final HelpGuide en = HelpGuide(
    title: 'Help & user guide',
    intro:
        'Everything you do in PharmaEt, step by step. Tap a topic to open it. '
        'You can read this guide before signing in, and without internet.',
    searchHint: 'Search the guide…',
    noMatch: 'Nothing in the guide matches that. Try another word.',
    contactTitle: 'Still stuck?',
    contactBody:
        'Call or message PharmaEt support on $supportPhone. Tell us your pharmacy code '
        'and what you see on the screen.',
    topics: [
      const HelpTopic(
        id: 'start',
        icon: 'rocket',
        title: 'Getting started',
        summary: 'Open your pharmacy\'s account and sign in the first time.',
        steps: [
          'On the sign-in screen, tap "Request an account" and fill in your pharmacy name, '
              'your full name, phone number, city and number of branches.',
          'We verify every pharmacy by phone. We call you, usually within a day, and give '
              'you your pharmacy code, your username and your first PIN.',
          'Connect to the internet and sign in with the pharmacy code, username and PIN. '
              'The first sign-in on each phone needs the internet once.',
          'If this is your first time, create your first branch — name the branch this '
              'phone is in. You can add more later.',
          'Choose which branch this phone belongs to. It is asked once, and every sale on '
              'this phone is recorded against that branch.',
        ],
        tip:
            'Keep your PIN private. Every sale, count and cash-up is recorded against the '
            'person who is signed in.',
      ),
      const HelpTopic(
        id: 'signin',
        icon: 'lock',
        title: 'Signing in',
        summary: 'PIN, password, offline sign-in and "Too many attempts".',
        steps: [
          'Type your PIN on the keypad and tap "Sign in". Owners and managers can tap '
              '"Use a password" to sign in with a password instead.',
          'After one online sign-in, this phone lets you sign in with your PIN even '
              'without internet, for up to 7 days.',
          'If someone else used this phone before you, tap "Not you?" and enter your own '
              'pharmacy code and username.',
          'After five wrong attempts, sign-in pauses for 15 minutes. A till that is '
              'already signed in keeps selling during that time.',
          'Forgot your PIN? Ask your owner or manager. They can add you again with a new '
              'starting PIN from More → Branches & staff.',
        ],
      ),
      const HelpTopic(
        id: 'sell',
        icon: 'cart',
        title: 'Opening the till and selling',
        summary:
            'Open a till, make a sale, give change, print or share the receipt.',
        steps: [
          'At the start of the day, tap "Open till" on Home and enter the cash already in '
              'the drawer (the opening float).',
          'Go to the Sell tab. Search for a product by name and tap it to add it. Use + and '
              '− to change the quantity.',
          'Tap "Charge". Choose Cash and type the cash received — the app shows the change '
              'to give. For Telebirr or bank transfers, choose Other.',
          'Tap "Complete sale". The receipt screen confirms it is saved on this phone.',
          'Tap "New sale" for the next customer.',
          'For a customer who will pay later, choose "On credit" instead of Cash, pick the '
              'customer (or add them), and enter anything they are paying today. When they '
              'come to pay, open More → "Customers & credit", choose them and tap "Take a '
              'payment".',
        ],
        tip:
            'You never need the internet to sell. Sales are saved on the phone first and '
            'upload by themselves when the connection returns.',
      ),
      const HelpTopic(
        id: 'receive',
        icon: 'inventory',
        title: 'Receiving stock',
        summary:
            'Record a delivery from a supplier, with lot numbers and expiry dates.',
        steps: [
          'Go to Stock → "Receive stock" (or "Receive" on Home).',
          'Enter the supplier\'s name.',
          'Tap "Add item". Choose the product, then enter the lot/batch number, the expiry '
              'date printed on the box, the quantity and the unit cost.',
          'Repeat for every product in the delivery, then tap "Confirm receipt".',
          'The stock is available to sell immediately, with or without internet.',
        ],
      ),
      const HelpTopic(
        id: 'count',
        icon: 'checklist',
        title: 'Counting and correcting stock',
        summary: 'Fix the numbers when the shelf and the app disagree.',
        steps: [
          'Go to Stock → "Count stock", or open a product and tap "Adjust stock".',
          'Count what is actually on the shelf and type that number.',
          'Choose a reason — recount, damaged, expired, theft or loss, receipt entered '
              'wrongly, or other — and add a note when asked.',
          'Tap "Record count". The change is saved with your name and the reason.',
        ],
        tip:
            'A product showing "negative" was sold beyond what the app knew about. Count '
            'it first — Home lists these under "Needs attention".',
      ),
      const HelpTopic(
        id: 'expiry',
        icon: 'event',
        title: 'Expiry dates',
        summary:
            'First-to-expire goes out first, and expired stock is guarded.',
        steps: [
          'The app always sells the batch that expires first (FEFO).',
          'Home shows batches expiring within 60 days, so you can reorder or discount them.',
          'If the only stock left has expired, the app warns you. Only an owner or manager '
              'can authorise dispensing it, and that decision is recorded with their name.',
        ],
      ),
      const HelpTopic(
        id: 'cashup',
        icon: 'payments',
        title: 'Cash-up: closing the till',
        summary: 'Count the drawer at the end of a shift.',
        steps: [
          'Go to More → "Cash up".',
          'Count the cash in the drawer and type the amount. Add a note if there is a '
              'difference you can explain.',
          'Tap "Record count & close shift". The app shows the expected amount and whether '
              'you are balanced, short or over.',
          'The owner sees every cash-up, with the difference, in Reports.',
        ],
      ),
      const HelpTopic(
        id: 'reports',
        icon: 'chart',
        title: 'Reports',
        summary: 'Sales, stock and cash-up for today, the week or the month.',
        steps: [
          'Open the Reports tab and choose Today, Week or Month.',
          'Sales summary shows sales by branch and by payment method.',
          'Stock & expiry lists expiring, low and oversold stock.',
          'Cash-up & variance shows each shift and any shortage.',
          '"Today\'s summary" puts the whole day on one screen: sales, whether each till '
              'balanced, what customers owe and what is running low. Tap "Share this '
              'summary" to send it to yourself.',
          '"Where the money is" works without internet: what to buy before it runs out, '
              'what earned most in 30 days, what has not sold in 60 days, and what is close '
              'to expiry and could go back to its supplier. Each list can be shared.',
          'Owners also have the "Activity log": who changed a price, wrote off stock or '
              'added staff. Nobody can edit or delete it.',
          'Reports need an internet connection. Figures include every phone that has '
              'synced.',
        ],
      ),
      const HelpTopic(
        id: 'staff',
        icon: 'people',
        title: 'Branches and staff',
        summary:
            'For owners and managers: add branches, add staff, remove access.',
        steps: [
          'Go to More → "Branches & staff".',
          'Tap "Add branch" to open another branch.',
          'Tap "Invite staff". Enter their full name, a username, their role (Owner, '
              'Manager or Cashier), their branch and a starting PIN of 4 to 8 digits. Tell '
              'them the PIN in person.',
          'To remove someone\'s access, open them and tap "Deactivate". Their past sales '
              'are kept.',
        ],
        tip:
            'Cashiers can sell, receive and count. Only owners and managers can change '
            'prices, manage staff and authorise expired stock.',
      ),
      const HelpTopic(
        id: 'products',
        icon: 'medication',
        title: 'Products and prices',
        summary: 'Add a product to your catalogue or change its price.',
        steps: [
          'In Stock, tap the add button to add a product: its name, unit (tablet, capsule, '
              'bottle…) and price.',
          'Start typing the name — "amox 500" — and the app suggests medicines from the '
              'Ethiopian Essential Medicines List. Tap one to fill in the name and unit, then '
              'type your price. Use "Add, then add another" to keep going. A product that is '
              'not on the list can still be typed in full.',
          'To change a price, open the product and tap the price. Enter the new price and '
              'tap "Save price".',
          'If you buy by the box and sell by the strip or the tablet, open the product and '
              'tap "Add a pack". Give each pack a name (strip, box), how many it holds, and '
              'its price. Stock is still counted in tablets.',
          'When selling, tap the pack under the product to sell a whole strip or box. When '
              'receiving, count the delivery in boxes and the app works out the tablets.',
          'To sell by scanning, link each product to its barcode once: open the product, tap '
              '"Scan a barcode to link" and point the camera at the box. After that, tap the '
              'scan button on the Sell screen and scan boxes one after another.',
          'If you also sell to clinics or organisations at a lower price, open the product, '
              'tap the price and fill in "Wholesale price". A pack can have its own wholesale '
              'price too. On the Sell screen a Retail / Wholesale switch then appears: tap '
              'Wholesale and the whole sale is priced from that list. Anything with no '
              'wholesale price is sold at the normal price. The switch returns to Retail '
              'after each sale.',
          'Every price change is recorded with the old and new figure and who made it.',
        ],
      ),
      const HelpTopic(
        id: 'sync',
        icon: 'sync',
        title: 'Working offline and syncing',
        summary:
            'What the sync chip means, and what to do when records need attention.',
        steps: [
          'The chip at the top shows the connection: "Synced", "Syncing…", a number '
              '"waiting", or "Offline".',
          'Offline is normal. Keep working — everything is saved on the phone and uploads '
              'by itself.',
          'Tap the chip, or More → "Sync now", to sync immediately.',
          'If Home shows records that "need attention", the server refused them. They are '
              'kept on the phone, not lost — contact support if it does not clear.',
          'If you have been offline for a long time, make a backup: More → "Backup & '
              'restore" → "Back up now". Choose a passphrase, write it down, and send the '
              'file to yourself (Telegram, email). If the phone is lost, sign in on another '
              'phone and restore the file there.',
        ],
      ),
      HelpTopic(
        id: 'payment',
        icon: 'wallet',
        title: 'Subscription and payment',
        summary: 'Pay the monthly subscription and send the proof.',
        steps: [
          'The subscription is ETB 1,000 per month for your pharmacy.',
          'Send the payment to one of these accounts, both in the name '
              '${paymentAccounts[PayChannel.cbe]!.holder}:\n'
              '• CBE: ${paymentAccounts[PayChannel.cbe]!.number}\n'
              '• Telebirr: ${paymentAccounts[PayChannel.telebirr]!.number}',
          'Take a screenshot of the completed transfer.',
          'In the app, go to More → Subscription → "Submit payment proof". Choose CBE or '
              'Telebirr, type the transaction reference, attach the screenshot and tap '
              '"Submit for review".',
          'We check it, usually within a few hours, and your subscription is extended.',
        ],
        tip:
            'If a subscription ends, your data is safe and the till keeps selling. Only '
            'changes to branches, staff, products and prices wait until payment is '
            'verified.',
      ),
      const HelpTopic(
        id: 'language',
        icon: 'translate',
        title: 'Changing the language',
        summary: 'Switch between Amharic and English.',
        steps: [
          'Go to More → "Language / ቋንቋ" and choose English or አማርኛ.',
          'Your choice is remembered on this phone, even after signing out.',
          'Dates are shown in the Ethiopian calendar in both languages.',
        ],
      ),
      const HelpTopic(
        id: 'trouble',
        icon: 'help',
        title: 'Troubleshooting',
        summary: 'Common messages and what to do.',
        steps: [
          '"Could not sign in": check the pharmacy code, username and PIN. The code and '
              'username are not case-sensitive.',
          '"No connection — the first sign-in needs the internet once": connect to Wi-Fi '
              'or mobile data and try again.',
          '"Offline too long": connect and sign in once to restore management actions. '
              'Selling and cash-up keep working.',
          '"Too many attempts": wait 15 minutes, then try again with the right PIN.',
          '"This terminal had to start a new local record": tell the owner and compare '
              'the last cash-up with the cash you actually have.',
        ],
      ),
    ],
  );

  static final HelpGuide am = HelpGuide(
    title: 'እገዛና የአጠቃቀም መመሪያ',
    intro: 'በፋርማኢት የሚሰሩትን ሁሉ ደረጃ በደረጃ። ርዕሱን ለመክፈት ይንኩ። '
        'ይህን መመሪያ ሳይገቡና ያለ ኢንተርኔት ማንበብ ይችላሉ።',
    searchHint: 'በመመሪያው ውስጥ ይፈልጉ…',
    noMatch: 'ከዚህ ጋር የሚመሳሰል ነገር አልተገኘም። ሌላ ቃል ይሞክሩ።',
    contactTitle: 'አሁንም ችግር አለ?',
    contactBody: 'የፋርማኢት ድጋፍን በ$supportPhone ይደውሉ ወይም መልዕክት ይላኩ። '
        'የፋርማሲዎን ኮድና በስክሪኑ ላይ የሚያዩትን ይንገሩን።',
    topics: [
      const HelpTopic(
        id: 'start',
        icon: 'rocket',
        title: 'መጀመሪያ',
        summary: 'የፋርማሲዎን መለያ ይክፈቱና ለመጀመሪያ ጊዜ ይግቡ።',
        steps: [
          'በመግቢያ ገጹ ላይ «መለያ ይጠይቁ» የሚለውን ይንኩና የፋርማሲውን ስም፣ ሙሉ ስምዎን፣ '
              'ስልክ ቁጥርዎን፣ ከተማውንና የቅርንጫፎችን ብዛት ይሙሉ።',
          'እያንዳንዱን ፋርማሲ በስልክ እናረጋግጣለን። ብዙውን ጊዜ በአንድ ቀን ውስጥ ደውለን '
              'የፋርማሲ ኮድ፣ የተጠቃሚ ስምና የመጀመሪያ ፒንዎን እንሰጥዎታለን።',
          'ከኢንተርኔት ጋር ይገናኙና በፋርማሲ ኮድ፣ በተጠቃሚ ስምና በፒን ይግቡ። በእያንዳንዱ ስልክ '
              'የመጀመሪያው መግቢያ አንድ ጊዜ ኢንተርኔት ይፈልጋል።',
          'የመጀመሪያ ጊዜዎ ከሆነ የመጀመሪያ ቅርንጫፍዎን ይፍጠሩ — ይህ ስልክ ያለበትን ቅርንጫፍ '
              'ይሰይሙ። በኋላ ተጨማሪ ማከል ይችላሉ።',
          'ይህ ስልክ የየትኛው ቅርንጫፍ እንደሆነ ይምረጡ። አንድ ጊዜ ብቻ ይጠየቃል፤ በዚህ ስልክ '
              'የሚደረግ እያንዳንዱ ሽያጭ በዚያ ቅርንጫፍ ይመዘገባል።',
        ],
        tip: 'ፒንዎን ለማንም አያጋሩ። እያንዳንዱ ሽያጭ፣ ቆጠራና የገንዘብ ቆጠራ በገባው ሰው ስም '
            'ይመዘገባል።',
      ),
      const HelpTopic(
        id: 'signin',
        icon: 'lock',
        title: 'መግባት',
        summary: 'ፒን፣ የይለፍ ቃል፣ ያለ ኢንተርኔት መግባትና «በጣም ብዙ ሙከራዎች»።',
        steps: [
          'ፒንዎን በቁልፍ ሰሌዳው ይጻፉና «ግባ» ይንኩ። ባለቤቶችና ሥራ አስኪያጆች «በይለፍ ቃል ይግቡ» '
              'የሚለውን ነክተው በይለፍ ቃል መግባት ይችላሉ።',
          'አንድ ጊዜ በኢንተርኔት ከገቡ በኋላ ይህ ስልክ እስከ 7 ቀን ድረስ ያለ ኢንተርኔት በፒን '
              'እንዲገቡ ይፈቅዳል።',
          'ከእርስዎ በፊት ሌላ ሰው ይህን ስልክ ከተጠቀመ «እርስዎ አይደሉም?» የሚለውን ይንኩና የራስዎን '
              'የፋርማሲ ኮድና የተጠቃሚ ስም ያስገቡ።',
          'ከአምስት የተሳሳቱ ሙከራዎች በኋላ መግባት ለ15 ደቂቃ ይቆማል። ቀድሞ የገባ ካሻ በዚያ ጊዜም '
              'መሸጡን ይቀጥላል።',
          'ፒንዎን ረሱ? ባለቤቱን ወይም ሥራ አስኪያጁን ይጠይቁ። ከተጨማሪ → ቅርንጫፎችና ሠራተኞች '
              'በአዲስ የመጀመሪያ ፒን እንደገና ሊያስገቡዎት ይችላሉ።',
        ],
      ),
      const HelpTopic(
        id: 'sell',
        icon: 'cart',
        title: 'ካሻ መክፈትና መሸጥ',
        summary: 'ካሻ ይክፈቱ፣ ይሽጡ፣ መልስ ይስጡ፣ ደረሰኝ ያትሙ ወይም ያጋሩ።',
        steps: [
          'በቀኑ መጀመሪያ በመነሻ ገጽ ላይ «ካሻ ክፈት» ይንኩና በሳጥኑ ውስጥ ያለውን ጥሬ ገንዘብ '
              '(የመክፈቻ ገንዘብ) ያስገቡ።',
          'ወደ «ሽያጭ» ትር ይሂዱ። ምርቱን በስሙ ፈልገው ለመጨመር ይንኩት። ብዛቱን ለመቀየር + እና − '
              'ይጠቀሙ።',
          '«ክፍያ» ይንኩ። ጥሬ ገንዘብን ይምረጡና የተቀበሉትን ገንዘብ ይጻፉ — መተግበሪያው የሚመለሰውን '
              'መልስ ያሳያል። ለቴሌብር ወይም ለባንክ ዝውውር «ሌላ» ይምረጡ።',
          '«ሽያጩን አጠናቅ» ይንኩ። የደረሰኝ ገጹ በዚህ ስልክ መቀመጡን ያረጋግጣል።',
          'ለሚቀጥለው ደንበኛ «አዲስ ሽያጭ» ይንኩ።',
          'በኋላ ለሚከፍል ደንበኛ ከጥሬ ገንዘብ ይልቅ «በዱቤ» ይምረጡ፤ ደንበኛውን ይምረጡ (ወይም ይጨምሩ)፤ ዛሬ '
              'የሚከፍሉት ካለ ያስገቡ። ለመክፈል ሲመጡ ተጨማሪ → «ደንበኞችና ዱቤ» ከፍተው ደንበኛውን መርጠው '
              '«ክፍያ ተቀበል» ይንኩ።',
        ],
        tip: 'ለመሸጥ ኢንተርኔት በጭራሽ አያስፈልግም። ሽያጮች መጀመሪያ በስልኩ ይቀመጣሉ፤ ግንኙነቱ '
            'ሲመለስ በራሳቸው ይላካሉ።',
      ),
      const HelpTopic(
        id: 'receive',
        icon: 'inventory',
        title: 'ዕቃ መረከብ',
        summary: 'ከአቅራቢ የመጣን ዕቃ በሎት ቁጥርና በማብቂያ ቀን ይመዝግቡ።',
        steps: [
          'ወደ ክምችት → «ዕቃ መረከብ» ይሂዱ (ወይም በመነሻ ገጽ «መረከብ»)።',
          'የአቅራቢውን ስም ያስገቡ።',
          '«ዕቃ ጨምር» ይንኩ። ምርቱን ይምረጡ፤ ከዚያ የሎት/ባች ቁጥሩን፣ በሳጥኑ ላይ የታተመውን '
              'የማብቂያ ቀን፣ ብዛቱንና የአንዱን ዋጋ ያስገቡ።',
          'ለእያንዳንዱ የመጣ ምርት ይድገሙ፤ ከዚያ «ርክክቡን አረጋግጥ» ይንኩ።',
          'ክምችቱ ኢንተርኔት ቢኖርም ባይኖርም ወዲያውኑ ለሽያጭ ዝግጁ ነው።',
        ],
      ),
      const HelpTopic(
        id: 'count',
        icon: 'checklist',
        title: 'ክምችት መቁጠርና ማስተካከል',
        summary: 'መደርደሪያውና መተግበሪያው ሳይስማሙ ቁጥሩን ያስተካክሉ።',
        steps: [
          'ወደ ክምችት → «ክምችት መቁጠር» ይሂዱ፣ ወይም ምርቱን ከፍተው «ክምችት አስተካክል» ይንኩ።',
          'በመደርደሪያው ላይ በትክክል ያለውን ቆጥረው ቁጥሩን ይጻፉ።',
          'ምክንያት ይምረጡ — እንደገና መቁጠር፣ የተበላሸ፣ ጊዜው ያለፈበት፣ ስርቆት ወይም መጥፋት፣ '
              'በስህተት የገባ ደረሰኝ ወይም ሌላ — ሲጠየቁም ማስታወሻ ይጨምሩ።',
          '«ቆጠራውን መዝግብ» ይንኩ። ለውጡ ከስምዎና ከምክንያቱ ጋር ይቀመጣል።',
        ],
        tip: '«ከዜሮ በታች» የሚያሳይ ምርት መተግበሪያው ከሚያውቀው በላይ ተሽጧል። መጀመሪያ ይቁጠሩት — '
            'መነሻ ገጹ «ትኩረት የሚሹ» በሚለው ስር ይዘረዝራቸዋል።',
      ),
      const HelpTopic(
        id: 'expiry',
        icon: 'event',
        title: 'የማብቂያ ቀኖች',
        summary: 'ቀድሞ የሚያበቃው ቀድሞ ይወጣል፤ ጊዜው ያለፈበት ክምችት ይጠበቃል።',
        steps: [
          'መተግበሪያው ሁልጊዜ ቀድሞ የሚያበቃውን ባች ይሸጣል (FEFO)።',
          'መነሻ ገጹ በ60 ቀናት ውስጥ የሚያበቁ ባቾችን ያሳያል፤ እንደገና ለማዘዝ ወይም ቅናሽ '
              'ለማድረግ ይረዳዎታል።',
          'የቀረው ክምችት ጊዜው ያለፈበት ብቻ ከሆነ መተግበሪያው ያስጠነቅቃል። እንዲሰጥ መፍቀድ '
              'የሚችሉት ባለቤት ወይም ሥራ አስኪያጅ ብቻ ናቸው፤ ውሳኔውም በስማቸው ይመዘገባል።',
        ],
      ),
      const HelpTopic(
        id: 'cashup',
        icon: 'payments',
        title: 'የገንዘብ ቆጠራ፦ ካሻን መዝጋት',
        summary: 'በፈረቃው መጨረሻ ሳጥኑን ይቁጠሩ።',
        steps: [
          'ወደ ተጨማሪ → «የገንዘብ ቆጠራ» ይሂዱ።',
          'በሳጥኑ ውስጥ ያለውን ጥሬ ገንዘብ ቆጥረው መጠኑን ይጻፉ። ሊያስረዱት የሚችሉት ልዩነት ካለ '
              'ማስታወሻ ይጨምሩ።',
          '«ቆጠራውን መዝግቦ ፈረቃውን ዝጋ» ይንኩ። መተግበሪያው የሚጠበቀውን መጠንና ሚዛናዊ፣ '
              'የጎደለ ወይም የተረፈ መሆኑን ያሳያል።',
          'ባለቤቱ እያንዳንዱን የገንዘብ ቆጠራ ከልዩነቱ ጋር በሪፖርቶች ውስጥ ያያል።',
        ],
      ),
      const HelpTopic(
        id: 'reports',
        icon: 'chart',
        title: 'ሪፖርቶች',
        summary: 'የዛሬ፣ የሳምንቱ ወይም የወሩ ሽያጭ፣ ክምችትና የገንዘብ ቆጠራ።',
        steps: [
          '«ሪፖርቶች» ትርን ከፍተው ዛሬ፣ ሳምንት ወይም ወር ይምረጡ።',
          'የሽያጭ ማጠቃለያ ሽያጭን በቅርንጫፍና በክፍያ ዘዴ ያሳያል።',
          'ክምችትና ማብቂያ የሚያበቁ፣ ያነሱና ከልክ በላይ የተሸጡ ክምችቶችን ይዘረዝራል።',
          'የገንዘብ ቆጠራና ልዩነት እያንዳንዱን ፈረቃና ማንኛውንም ጉድለት ያሳያል።',
          '«የዛሬ ማጠቃለያ» ሙሉውን ቀን በአንድ ገጽ ያሳያል፦ ሽያጭ፣ እያንዳንዱ ካሻ መመጣጠኑን፣ የደንበኞች '
              'ዕዳ እና እያለቀ ያለ ክምችት። ለራስዎ ለመላክ «ይህን ማጠቃለያ አጋራ» ይንኩ።',
          '«ገንዘቡ የት እንዳለ» ያለ ኢንተርኔት ይሠራል፦ ከማለቁ በፊት የሚገዛ፣ በ30 ቀናት ብዙ ያተረፈ፣ በ60 ቀናት '
              'ያልተሸጠ፣ እና ጊዜው ሊያልፍ የተቃረበና ለአቅራቢው ሊመለስ የሚችል። እያንዳንዱ ዝርዝር ሊጋራ ይችላል።',
          'ባለቤቶች «የእንቅስቃሴ መዝገብ»ም አላቸው፦ ዋጋ የቀየረ፣ ክምችት የሰረዘ ወይም ሠራተኛ የጨመረ ማን '
              'እንደሆነ። ማንም ሊያስተካክለው ወይም ሊሰርዘው አይችልም።',
          'ሪፖርቶች የኢንተርኔት ግንኙነት ይፈልጋሉ። አሃዞቹ ያመሳሰሉትን ስልኮች ሁሉ ያካትታሉ።',
        ],
      ),
      const HelpTopic(
        id: 'staff',
        icon: 'people',
        title: 'ቅርንጫፎችና ሰራተኞች',
        summary: 'ለባለቤቶችና ሥራ አስኪያጆች፦ ቅርንጫፍ ማከል፣ ሠራተኛ ማከል፣ መዳረሻ ማንሳት።',
        steps: [
          'ወደ ተጨማሪ → «ቅርንጫፎችና ሠራተኞች» ይሂዱ።',
          'ሌላ ቅርንጫፍ ለመክፈት «ቅርንጫፍ ጨምር» ይንኩ።',
          '«ሠራተኛ ጨምር» ይንኩ። ሙሉ ስማቸውን፣ የተጠቃሚ ስም፣ ሚናቸውን (ባለቤት፣ ሥራ አስኪያጅ ወይም '
              'ገንዘብ ተቀባይ)፣ ቅርንጫፋቸውንና ከ4 እስከ 8 አሃዝ ያለው የመጀመሪያ ፒን ያስገቡ። ፒኑን በአካል '
              'ይንገሯቸው።',
          'የአንድን ሰው መዳረሻ ለማንሳት ከፍተው «አቦዝን» ይንኩ። ያለፉ ሽያጮቻቸው ይቀመጣሉ።',
        ],
        tip:
            'ገንዘብ ተቀባዮች መሸጥ፣ መቀበልና መቁጠር ይችላሉ። ዋጋ መቀየር፣ ሠራተኛ ማስተዳደርና ጊዜው ያለፈበትን '
            'ክምችት መፍቀድ የሚችሉት ባለቤቶችና ሥራ አስኪያጆች ብቻ ናቸው።',
      ),
      const HelpTopic(
        id: 'products',
        icon: 'medication',
        title: 'ምርቶችና ዋጋዎች',
        summary: 'ምርት ወደ ካታሎግዎ ያክሉ ወይም ዋጋውን ይቀይሩ።',
        steps: [
          'በክምችት ውስጥ የመጨመሪያ ቁልፉን ነክተው ምርት ያክሉ፦ ስሙን፣ መለኪያውን (ኪኒን፣ ካፕሱል፣ '
              'ጠርሙስ…) እና ዋጋውን።',
          'ስሙን መጻፍ ይጀምሩ — «amox 500» — መተግበሪያው ከኢትዮጵያ መሠረታዊ መድኃኒቶች ዝርዝር '
              'መድኃኒቶችን ይጠቁማል። አንዱን ነክተው ስሙንና መለኪያውን ይሙሉ፤ ከዚያ ዋጋዎን ይጻፉ። '
              'ለመቀጠል «ጨምር፣ ከዚያ ሌላ ጨምር» ይጠቀሙ። በዝርዝሩ ውስጥ የሌለ ምርት አሁንም ሙሉ '
              'በሙሉ መጻፍ ይቻላል።',
          'ዋጋ ለመቀየር ምርቱን ከፍተው ዋጋውን ይንኩ። አዲሱን ዋጋ አስገብተው «ዋጋውን አስቀምጥ» '
              'ይንኩ።',
          'በካርቶን ገዝተው በስትሪፕ ወይም በክኒን የሚሸጡ ከሆነ ምርቱን ከፍተው «ፓኬት ጨምር» ይንኩ። '
              'ለእያንዳንዱ ፓኬት ስም (ስትሪፕ፣ ካርቶን)፣ የሚይዘውን ብዛትና ዋጋውን ይስጡ። ክምችቱ '
              'አሁንም በክኒን ይቆጠራል።',
          'ሲሸጡ ሙሉ ስትሪፕ ወይም ካርቶን ለመሸጥ ከምርቱ ስር ያለውን ፓኬት ይንኩ። ሲረከቡ የመጣውን '
              'በካርቶን ይቁጠሩ፤ መተግበሪያው ክኒኑን ያሰላል።',
          'በስካን ለመሸጥ እያንዳንዱን ምርት አንድ ጊዜ ከባርኮዱ ጋር ያያይዙ፦ ምርቱን ከፍተው «ለማያያዝ ባርኮድ '
              'ስካን አድርግ» ይንኩና ካሜራውን ወደ ሳጥኑ ያዙሩ። ከዚያ በኋላ በሽያጭ ገጹ ላይ የስካን ቁልፉን '
              'ነክተው ሳጥኖቹን አንድ በአንድ ስካን ያድርጉ።',
          'ለክሊኒኮች ወይም ለድርጅቶች በዝቅተኛ ዋጋ የሚሸጡ ከሆነ ምርቱን ከፍተው ዋጋውን ይንኩና «የጅምላ ዋጋ» '
              'ይሙሉ። ፓኬትም የራሱ የጅምላ ዋጋ ሊኖረው ይችላል። ከዚያ በሽያጭ ገጹ ላይ ችርቻሮ / ጅምላ መቀያየሪያ '
              'ይታያል፦ «ጅምላ»ን ሲነኩ ሙሉ ሽያጩ በጅምላ ዋጋ ይሰላል። የጅምላ ዋጋ የሌለው ምርት በመደበኛ ዋጋው '
              'ይሸጣል። ከእያንዳንዱ ሽያጭ በኋላ መቀያየሪያው ወደ ችርቻሮ ይመለሳል።',
          'እያንዳንዱ የዋጋ ለውጥ ከቀድሞውና ከአዲሱ ዋጋ እንዲሁም ከቀየረው ሰው ጋር ይመዘገባል።',
        ],
      ),
      const HelpTopic(
        id: 'sync',
        icon: 'sync',
        title: 'ያለ ኢንተርኔት መስራትና ማመሳሰል',
        summary: 'የማመሳሰያ ምልክቱ ትርጉምና መዝገቦች ትኩረት ሲሹ ምን ማድረግ እንዳለብዎ።',
        steps: [
          'ከላይ ያለው ምልክት ግንኙነቱን ያሳያል፦ «ተመሳስሏል»፣ «በማመሳሰል ላይ…»፣ «በመጠባበቅ ላይ» ያሉ '
              'መዝገቦች ብዛት ወይም «ከመስመር ውጭ»።',
          'ከመስመር ውጭ መሆን የተለመደ ነው። መስራትዎን ይቀጥሉ — ሁሉም ነገር በስልኩ ይቀመጣል፤ '
              'በራሱም ይላካል።',
          'ወዲያውኑ ለማመሳሰል ምልክቱን ወይም ተጨማሪ → «አሁን አመሳስል» ይንኩ።',
          'መነሻ ገጹ «ትኩረት የሚሹ» መዝገቦችን ካሳየ ሰርቨሩ አልተቀበላቸውም። በስልኩ ላይ '
              'ተቀምጠዋል እንጂ አልጠፉም — ካልጠፉ ድጋፍን ያነጋግሩ።',
          'ለረጅም ጊዜ ከመስመር ውጭ ከቆዩ ቅጂ ይያዙ፦ ተጨማሪ → «ቅጂ መያዝና መመለስ» → «አሁን ቅጂ ያዝ»። '
              'የይለፍ ሐረግ መርጠው ጽፈው ያስቀምጡ፤ ፋይሉንም ለራስዎ ይላኩ (ቴሌግራም፣ ኢሜይል)። ስልኩ '
              'ከጠፋ በሌላ ስልክ ገብተው ፋይሉን እዚያ ይመልሱ።',
        ],
      ),
      HelpTopic(
        id: 'payment',
        icon: 'wallet',
        title: 'ምዝገባና ክፍያ',
        summary: 'ወርሃዊ ክፍያውን ይክፈሉና ማስረጃውን ይላኩ።',
        steps: [
          'ምዝገባው ለፋርማሲዎ በወር 1,000 ብር ነው።',
          'ክፍያውን ከእነዚህ ሂሳቦች ወደ አንዱ ይላኩ፤ ሁለቱም በ'
              '${paymentAccounts[PayChannel.cbe]!.holder} ስም ናቸው፦\n'
              '• ሲቢኢ (የኢትዮጵያ ንግድ ባንክ)፦ ${paymentAccounts[PayChannel.cbe]!.number}\n'
              '• ቴሌብር፦ ${paymentAccounts[PayChannel.telebirr]!.number}',
          'የተጠናቀቀውን ዝውውር ቅጽበታዊ ገጽ እይታ (ስክሪንሾት) ያንሱ።',
          'በመተግበሪያው ውስጥ ወደ ተጨማሪ → ምዝገባ → «የክፍያ ማስረጃ ላክ» ይሂዱ። ሲቢኢ ወይም ቴሌብርን '
              'ይምረጡ፣ የግብይት መለያ ቁጥሩን ይጻፉ፣ ስክሪንሾቱን ያያይዙና «ለግምገማ ላክ» ይንኩ።',
          'ብዙውን ጊዜ በጥቂት ሰዓታት ውስጥ አረጋግጠን ምዝገባዎን እናራዝማለን።',
        ],
        tip: 'ምዝገባው ቢያበቃም መረጃዎ ደህና ነው፤ ካሻውም መሸጡን ይቀጥላል። ክፍያው እስኪረጋገጥ '
            'የሚቆዩት የቅርንጫፍ፣ የሠራተኛ፣ የምርትና የዋጋ ለውጦች ብቻ ናቸው።',
      ),
      const HelpTopic(
        id: 'language',
        icon: 'translate',
        title: 'ቋንቋ መቀየር',
        summary: 'በአማርኛና በእንግሊዝኛ መካከል ይቀያይሩ።',
        steps: [
          'ወደ ተጨማሪ → «Language / ቋንቋ» ይሂዱና English ወይም አማርኛ ይምረጡ።',
          'ምርጫዎ ከወጡ በኋላም ቢሆን በዚህ ስልክ ይታወሳል።',
          'ቀኖች በሁለቱም ቋንቋዎች በኢትዮጵያ ዘመን አቆጣጠር ይታያሉ።',
        ],
      ),
      const HelpTopic(
        id: 'trouble',
        icon: 'help',
        title: 'ችግሮችን መፍታት',
        summary: 'የተለመዱ መልዕክቶችና ምን ማድረግ እንዳለብዎ።',
        steps: [
          '«መግባት አልተቻለም»፦ የፋርማሲ ኮዱን፣ የተጠቃሚ ስሙንና ፒኑን ያረጋግጡ። ኮዱና የተጠቃሚ '
              'ስሙ ትልቅ ወይም ትንሽ ፊደል አይለዩም።',
          '«ግንኙነት የለም — የመጀመሪያው መግቢያ አንድ ጊዜ ኢንተርኔት ይፈልጋል»፦ ከዋይፋይ ወይም ከሞባይል '
              'ዳታ ጋር ተገናኝተው እንደገና ይሞክሩ።',
          '«ለረጅም ጊዜ ከመስመር ውጭ»፦ የአስተዳደር ተግባራትን ለመመለስ ተገናኝተው አንድ ጊዜ ይግቡ። '
              'ሽያጭና የገንዘብ ቆጠራ መስራታቸውን ይቀጥላሉ።',
          '«በጣም ብዙ ሙከራዎች»፦ 15 ደቂቃ ይጠብቁና በትክክለኛው ፒን እንደገና ይሞክሩ።',
          '«ይህ ተርሚናል አዲስ የአካባቢ መዝገብ መጀመር ነበረበት»፦ ለባለቤቱ ይንገሩና የመጨረሻውን '
              'የገንዘብ ቆጠራ በእጅዎ ካለው ገንዘብ ጋር ያወዳድሩ።',
        ],
      ),
    ],
  );
}
