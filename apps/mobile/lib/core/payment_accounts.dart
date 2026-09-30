/// Where a pharmacy sends its subscription payment (Vision §4).
///
/// There is no gateway in V1: the owner transfers the money themselves, then uploads the
/// screenshot for a person to verify. That only works if the app says *where* to send it,
/// so the accounts are shown on the payment screen itself, not in a message or a PDF the
/// owner has to go and find.
///
/// Compiled in rather than fetched. The payment screen is reached when a subscription has
/// lapsed, which is exactly when the device may be offline, and an account number that
/// needs a network round-trip to appear is one the owner cannot copy. Changing an account
/// is a release, which is the right amount of friction for where people send money.
enum PayChannel { telebirr, cbe }

class PaymentAccount {
  const PaymentAccount({
    required this.channel,
    required this.label,
    required this.number,
    required this.holder,
  });

  final PayChannel channel;

  /// The name printed on the transfer screen of the owner's own app.
  final String label;
  final String number;
  final String holder;
}

const paymentAccounts = <PayChannel, PaymentAccount>{
  PayChannel.cbe: PaymentAccount(
    channel: PayChannel.cbe,
    label: 'CBE',
    number: '1000473026922',
    holder: 'Binyam Ayalneh Zerihun',
  ),
  PayChannel.telebirr: PaymentAccount(
    channel: PayChannel.telebirr,
    label: 'Telebirr',
    number: '0902432346',
    holder: 'Binyam Ayalneh Zerihun',
  ),
};

/// Where a pharmacy reaches us when the user guide does not answer the question. Shown in
/// the guide's closing card, so it is on every phone before anyone has signed in.
const supportPhone = '0902432346';
