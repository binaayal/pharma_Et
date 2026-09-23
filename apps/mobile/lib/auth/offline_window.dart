import '../contracts/permissions.dart';

/// The offline authority ceiling (BR-2.3, NFR-4.2).
///
/// A terminal signs in online once and then carries a cached snapshot of its user's scope.
/// That snapshot is the terminal's authority, and authority kept in a drawer goes stale: a
/// cashier dismissed on Tuesday still holds Monday's session, and nothing on the device can
/// learn otherwise until it reaches the server.
///
/// So the window closes. What it must not close is the shop. BR-2.3 states the exemption
/// exactly — past the ceiling, "re-auth online is required for privileged actions but **not**
/// to complete an in-progress sale" — and NFR-1.2 says the same thing from the other side.
/// A pharmacy whose till stopped because a token aged would be a pharmacy that uninstalled
/// this app, and the dismissed-cashier risk it was protecting against is smaller than that.
///
/// The set below is therefore deliberately short, and each entry earns its place by the same
/// test: **would refusing this leave the pharmacy unable to trade, or leave money
/// unaccounted for?**
const Set<String> kCapabilitiesSurvivingOfflineExpiry = {
  // BR-2.3's named exemption. Stale authority cannot cost a pharmacy a sale.
  Capability.saleCreate,

  // Not named by BR-2.3, and included on the same reasoning. A shift opened before the
  // window closed has cash in a drawer; refusing the cash-up would leave that drawer
  // unreconciled overnight, which is the exact loss FR-8 exists to prevent. Closing a till
  // is the end of a sale, not a privilege.
  Capability.cashupPerform,
};

/// Whether a capability is still exercisable on a terminal whose window has closed.
///
/// Everything not listed waits for an online sign-in. Note what that includes:
/// `catalog.manage` (a price change is how a dismissed manager would steal), `staff.manage`,
/// `goods.receive` and `controlled.dispense`. None of them stops the counter serving a
/// customer, and all of them are actions where a stale scope does real damage.
bool survivesOfflineExpiry(String capability) =>
    kCapabilitiesSurvivingOfflineExpiry.contains(capability);

/// What the person at the counter is told.
///
/// Phrased as a fact plus a remedy, and leading with the reassurance. Somebody reading this
/// with a queue in front of them needs to know the till still works before they need to know
/// why a button vanished.
const String kOfflineExpiryMessage =
    'This terminal has been offline too long to authorise management actions. '
    'Selling and cash-up are unaffected — connect and sign in to restore the rest.';
