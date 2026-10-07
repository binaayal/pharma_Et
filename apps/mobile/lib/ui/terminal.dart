import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import '../api/tenant_api.dart';
import '../auth/offline_window.dart';
import '../auth/session.dart';
import '../contracts/contracts.dart';
import '../core/permissions.dart';
import '../data/backup.dart';
import '../data/catalog_repository.dart';
import '../data/controlled_repository.dart';
import '../data/customer_repository.dart';
import '../data/supplier_repository.dart';
import '../data/insights_repository.dart';
import '../data/inventory_repository.dart';
import '../data/sale_repository.dart';
import '../data/shift_repository.dart';
import '../sync/sync_client.dart';
import '../sync/sync_service.dart';

/// Everything the tabs share about this terminal and whoever is signed in to it.
///
/// One object rather than state per screen, because the prototype's shell has five tabs
/// over one till: a cart started on Sell must survive a look at Stock, and the sync chip on
/// every screen must be telling the same story.
class Terminal extends ChangeNotifier with WidgetsBindingObserver {
  Terminal({
    required CachedSession session,
    required this.terminalId,
    required this.catalog,
    required this.sales,
    required this.shifts,
    required this.inventory,
    required this.controlled,
    required this.backups,
    required this.customers,
    required this.suppliers,
    required this.insights,
    required this.syncService,
    required this.api,
    required this.client,
    required this.onSessionRenewed,
    required this.onSignOut,
    this.onDeactivated,
    this.branchName,
  }) : _session = session;

  /// How often the counter tries to sync on its own (FR-9: "on connectivity, the client
  /// pushes"; actor "system (background)"). An interval rather than a connectivity
  /// listener: it needs no plugin, and it also catches a network that is up but not
  /// reaching the server.
  static const syncInterval = Duration(seconds: 30);

  /// With nothing queued, the timer still pulls reference data — but only this often.
  /// Prices and products change rarely, and at 1,000 pharmacies a pull every 30 s is most of
  /// the server's load for no new information (NFR-3.1). Anything queued still goes within
  /// [syncInterval]; a commit, a resume or a tap syncs at once regardless.
  static const idlePullInterval = Duration(minutes: 2);
  DateTime? _lastSync;

  final String terminalId;
  final CatalogRepository catalog;
  final SaleRepository sales;
  final ShiftRepository shifts;
  final InventoryRepository inventory;
  final ControlledRepository controlled;
  final BackupService backups;
  final CustomerRepository customers;

  /// Suppliers and what is owed to them (FR-18).
  final SupplierRepository suppliers;
  final InsightsRepository insights;
  final SyncService syncService;
  final TenantApi api;
  final SyncClient client;
  final Future<void> Function(LoginResponse) onSessionRenewed;
  final VoidCallback onSignOut;

  /// The platform deactivated this pharmacy (ADR-025), with the reason it gave. The app
  /// signs out and wipes this device's offline sign-in; the outbox is left alone.
  final void Function(String reason)? onDeactivated;

  /// The name of the branch this device stands in, when known.
  String? branchName;

  CachedSession _session;
  CachedSession get session => _session;
  set session(CachedSession next) {
    _session = next;
    notifyListeners();
  }

  SyncStatus status =
      const SyncStatus(state: SyncState.idle, pending: 0, needsAttention: 0);
  bool _syncing = false;
  ActiveShift? shift;
  List<LocalProduct> products = [];
  SubscriptionInfo? subscription;

  /// Whether controlled dispensing is live (ADR-024) — off until A-1 is verified.
  bool controlledEnabled = false;
  final List<CartLine> cart = [];

  /// Whether the sale being assembled is for a wholesale customer (FR-19). A property of
  /// the whole sale — a clinic does not buy half its basket at retail — so switching it
  /// re-prices every line at once.
  bool wholesale = false;

  /// Whether this pharmacy has set a wholesale price on anything. Where it has not, the
  /// counter is never shown the switch: a choice between two identical prices is noise.
  bool get hasWholesalePrices => products.any((p) => p.hasWholesalePrice);

  void setWholesale(bool value) {
    if (value == wholesale) return;
    wholesale = value;
    for (var i = 0; i < cart.length; i++) {
      final line = cart[i];
      cart[i] = CartLine(
        product: line.product,
        qty: line.qty,
        batchId: line.batchId,
        pack: line.pack,
        expiryOverrideBy: line.expiryOverrideBy,
        wholesale: value,
      );
    }
    notifyListeners();
  }

  /// The batch FEFO chose for each cart line, and what the branch holds of that product —
  /// what the cart shows under each line, and what decides the oversell notice.
  final Map<String, LocalBatch?> cartBatch = {};
  final Map<String, int> cartOnHand = {};
  Timer? _timer;

  String get branchId => session.primaryBranchId ?? '';
  String get role => session.scope.role;
  String get firstName => session.scope.displayName.split(' ').first;
  bool get isOwner => role == 'owner';

  /// The FR-2 matrix, then the offline ceiling (BR-2.3). Controls for a denied capability
  /// are not rendered at all — a disabled button teaches people to hunt for a way round it.
  bool can(String capability) {
    if (!role.can(capability)) return false;
    if (session.offlineWindowExpired && !survivesOfflineExpiry(capability)) {
      return false;
    }
    return true;
  }

  /// Whether this person may sell on credit and take repayments (FR-16, ADR-034).
  ///
  /// Anyone who may sell. Whether to trust a customer is a judgment made at the counter by
  /// whoever is standing there; the system's part is to record who made it, which every
  /// credit sale and repayment does. No separate capability — and so no change to the
  /// FR-2 matrix.
  bool get canTakeCredit => can(Capability.saleCreate);

  /// Whether this person sees suppliers and what is owed to them (FR-18, ADR-038): anyone
  /// who may receive a delivery, since a delivery is where a debt to a supplier begins.
  bool get canSeeSuppliers => can(Capability.goodsReceive);

  /// Whether this person is offered "pay a supplier": the owner and a branch manager — the
  /// people who already set prices. Money leaving the business is not a counter decision.
  /// (Decided on the phone; see ADR-038 for what the server does and does not enforce.)
  bool get canPaySuppliers => can(Capability.catalogManage);

  /// Whether this person may back up and restore this phone (FR-15, ADR-033).
  ///
  /// The owner and a branch manager: a backup holds the branch's sales, which is what the
  /// branch report already shows them. Decided on the role alone, **ignoring the offline
  /// ceiling** that [can] applies — a phone offline for eight days is exactly the phone
  /// whose queue most needs copying somewhere safe, and withdrawing the button then would
  /// take the lifeboat away for being too far from shore.
  bool get canBackUp {
    final reach = role.reach(Capability.reportBranch);
    return reach == Grant.branch || reach == Grant.tenant;
  }

  /// Branch or tenant reports — a cashier's `own` grant covers their cash-up, not these.
  bool get canReadReports {
    if (!can(Capability.reportBranch)) return false;
    final reach = role.reach(Capability.reportBranch);
    return reach == Grant.branch || reach == Grant.tenant;
  }

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    await refresh();
    unawaited(sync());
    _timer = Timer.periodic(syncInterval, (_) => _tick());
    unawaited(loadSubscription());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app is the likeliest moment the network came back too.
    if (state == AppLifecycleState.resumed) unawaited(sync());
  }

  /// Bumped whenever local data may have changed (a sale, a receipt, a count, a pull), so
  /// screens holding their own queries — Home's figures, the stock list — know to re-read.
  int revision = 0;

  Future<void> refresh() async {
    revision++;
    controlledEnabled = await controlled.enabled();
    products = await catalog.products();
    status = await syncService.status();
    shift = await shifts.activeShift(session.scope.userId);
    notifyListeners();
  }

  /// The background timer: push whenever something is waiting, pull when it is due.
  Future<void> _tick() async {
    final due = _lastSync == null ||
        clock.now().difference(_lastSync!) >= idlePullInterval;
    if (status.pending > 0 || due) await sync();
  }

  Future<SyncStatus> sync() async {
    if (_syncing) return status;
    _syncing = true;
    status = SyncStatus(
      state: SyncState.syncing,
      pending: status.pending,
      needsAttention: status.needsAttention,
      lastSyncedAt: status.lastSyncedAt,
    );
    notifyListeners();
    try {
      status = await syncService.sync(
        token: session.accessToken,
        refreshToken: session.refreshToken,
        tenantId: session.scope.tenantId,
        branchId: branchId,
        actorId: session.scope.userId,
        terminalId: terminalId,
        onRenewed: onSessionRenewed,
      );
    } finally {
      _syncing = false;
      _lastSync = clock.now();
    }
    if (status.state == SyncState.accountDeactivated) {
      onDeactivated?.call(status.message ?? '');
      return status;
    }
    await refresh();
    // Cheap, owner-only, and the way a suspension or a verified payment reaches a phone
    // that stays open all day.
    unawaited(loadSubscription());
    unawaited(_learnSwitch());
    return status;
  }

  /// Asks the server whether the regulated half is live, and remembers the answer offline.
  Future<void> _learnSwitch() async {
    try {
      final on = await api.controlledDispensingEnabled();
      await controlled.rememberSwitch(on);
      if (on != controlledEnabled) {
        controlledEnabled = on;
        notifyListeners();
      }
    } catch (_) {
      // Offline: the last answer stands.
    }
  }

  /// An online call with the session's token, renewed once on a 401 (ADR-019).
  Future<T> authed<T>(Future<T> Function(String token) call) async {
    try {
      return await call(session.accessToken);
    } on ApiException catch (e) {
      if (e.statusCode != 401 || session.refreshToken.isEmpty) rethrow;
      final renewed = await client.refresh(
          refreshToken: session.refreshToken, terminalId: terminalId);
      await onSessionRenewed(renewed);
      return call(renewed.accessToken);
    }
  }

  /// The owner's subscription, for the lock screen and Settings. Best effort: offline, the
  /// last known state stands, and a sale is never blocked on it (NFR-1.2, ADR-016).
  Future<void> loadSubscription() async {
    if (!can(Capability.settingsConfigure)) return;
    try {
      subscription = await authed(api.subscription);
      notifyListeners();
    } catch (_) {
      // Offline or refused: nothing to show, nothing to block.
    }
  }

  /// The product a scanned barcode belongs to, or null (FR-13).
  ///
  /// Looked up in the catalogue already on this phone, so a scan works with no network —
  /// and [barcode] must be canonical (`parseScan` / `canonicalBarcode`), because that is
  /// the form the links are stored in.
  LocalProduct? productForBarcode(String barcode) {
    for (final product in products) {
      if (product.barcodes.contains(barcode)) return product;
    }
    return null;
  }

  // ------------------------------------------------------------------------ cart

  int get cartTotal => cart.fold(0, (sum, line) => sum + line.lineTotalSantim);
  int get cartItems => cart.fold(0, (sum, line) => sum + line.qty);

  void addLine(LocalProduct product,
      {LocalBatch? batch, String? overrideBy, int onHand = 0}) {
    final i = cart.indexWhere((line) => line.product.id == product.id);
    if (i >= 0) {
      setQty(i, cart[i].qty + 1);
    } else {
      cartBatch[product.id] = batch;
      cartOnHand[product.id] = onHand;
      cart.add(CartLine(
          product: product,
          qty: 1,
          batchId: batch?.id,
          expiryOverrideBy: overrideBy,
          wholesale: wholesale));
      notifyListeners();
    }
  }

  void setQty(int index, int qty) {
    final line = cart[index];
    if (qty <= 0) {
      cart.removeAt(index);
      cartBatch.remove(line.product.id);
      cartOnHand.remove(line.product.id);
    } else {
      cart[index] = CartLine(
        product: line.product,
        qty: qty,
        batchId: line.batchId,
        pack: line.pack,
        expiryOverrideBy: line.expiryOverrideBy,
        wholesale: wholesale,
      );
    }
    notifyListeners();
  }

  /// Switches a cart line between the base unit ([pack] null) and one of the product's
  /// packs (FR-11). The count is kept: three tablets become three boxes, because the
  /// cashier who taps "box" after tapping ＋ twice means three boxes — and the line total
  /// on screen says so before anything is charged.
  void setPack(int index, ProductPack? pack) {
    final line = cart[index];
    cart[index] = CartLine(
      product: line.product,
      qty: line.qty,
      batchId: line.batchId,
      pack: pack,
      expiryOverrideBy: line.expiryOverrideBy,
      wholesale: wholesale,
    );
    notifyListeners();
  }

  /// Commits the cart as one local transaction and pushes it without holding the counter.
  ///
  /// With [creditSantim], that much of the total is not paid now and is owed by
  /// [customerId] (FR-16); the rest is settled by [method].
  Future<CommittedSale> commit(
      {String method = 'cash',
      String? customerId,
      int creditSantim = 0}) async {
    final sale = await sales.commitSale(
      customerId: customerId,
      creditSantim: creditSantim,
      wholesale: wholesale,
      lines: List.of(cart),
      tenantId: session.scope.tenantId,
      branchId: branchId,
      cashierId: session.scope.userId,
      terminalId: terminalId,
      // A missing shift never stops a sale (BR-4.1).
      shiftId: shift?.id,
      paymentMethod: method,
    );
    cart.clear();
    cartBatch.clear();
    cartOnHand.clear();
    // Back to retail for the next customer: wholesale is the exception, and a till left
    // on it would undercharge everyone who walked in afterwards.
    wholesale = false;
    await refresh();
    unawaited(sync());
    return sale;
  }
}

/// Makes the [Terminal] reachable from any screen under the shell.
class TerminalScope extends InheritedNotifier<Terminal> {
  const TerminalScope(
      {super.key, required Terminal terminal, required super.child})
      : super(notifier: terminal);

  static Terminal of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TerminalScope>();
    assert(scope != null, 'TerminalScope is missing from the widget tree');
    return scope!.notifier!;
  }

  /// Read without subscribing to rebuilds — for callbacks.
  static Terminal read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TerminalScope>()!.notifier!;
}
