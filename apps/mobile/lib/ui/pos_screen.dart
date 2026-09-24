import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/session.dart';
import '../auth/offline_window.dart';
import '../contracts/contracts.dart';
import '../core/money.dart';
import '../core/permissions.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/sale_repository.dart';
import '../data/inventory_repository.dart';
import '../data/shift_repository.dart';
import '../l10n/locale_store.dart';
import '../sync/sync_service.dart';
import 'cash_up_screen.dart';
import 'receive_screen.dart';
import 'reconcile_screen.dart';
import 'sync_chip.dart';

/// The counter (FR-4).
///
/// The rule this screen exists to honour: **a sale is never blocked.** Not by a stock count,
/// not by a missing network, not by a stale catalog. Committing is a local transaction that
/// returns in well under 100 ms (NFR-3.2), and the sync chip tells the cashier their work is
/// safe. Everything else about this screen is secondary to that.
class PosScreen extends StatefulWidget {
  const PosScreen({
    super.key,
    required this.session,
    required this.catalog,
    required this.sales,
    required this.shifts,
    required this.inventory,
    required this.syncService,
    required this.terminalId,
    required this.onSignOut,
    required this.onSessionRenewed,
  });

  final CachedSession session;
  final CatalogRepository catalog;
  final SaleRepository sales;
  final ShiftRepository shifts;
  final InventoryRepository inventory;
  final SyncService syncService;
  final String terminalId;
  final VoidCallback onSignOut;

  /// Persists a session renewed mid-sync (ADR-019), so the terminal does not redeem its
  /// refresh token again on the very next tick.
  final Future<void> Function(LoginResponse) onSessionRenewed;

  /// How often the counter tries to sync on its own (FR-9: "on connectivity, the client
  /// pushes"). The actor is the system, not the cashier: a sale must not sit on the device
  /// because nobody pressed a button. A retry interval stands in for a connectivity
  /// listener — it needs no plugin, and it also catches the network that is "up" but not
  /// reaching the server, which a connectivity event would report as online.
  static const syncInterval = Duration(seconds: 30);

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> with WidgetsBindingObserver {
  Timer? _syncTimer;

  List<LocalProduct> _products = [];
  final List<CartLine> _cart = [];
  ActiveShift? _shift;
  SyncStatus _status = const SyncStatus(
    state: SyncState.idle,
    pending: 0,
    needsAttention: 0,
  );
  bool _syncing = false;

  String get _branchId => widget.session.primaryBranchId ?? '';

  /// The FR-2 matrix, read from the generated table the server enforces (AC-2.1).
  ///
  /// Controls for a denied capability are **not rendered at all**. A disabled button just
  /// teaches people to hunt for the way to enable it, and an action the server will refuse
  /// reads to a user as the product being broken.
  ///
  /// Two gates, not one. The matrix says what this *role* may ever do; the offline window
  /// says what this *terminal* may still do on authority it has not refreshed (BR-2.3). A
  /// cashier dismissed last week passes the first and must fail the second.
  bool _can(String capability) {
    if (!widget.session.scope.role.can(capability)) return false;
    if (widget.session.offlineWindowExpired &&
        !survivesOfflineExpiry(capability)) {
      return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _sync();
    _syncTimer = Timer.periodic(PosScreen.syncInterval, (_) => _sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app is the likeliest moment the network came back too.
    if (state == AppLifecycleState.resumed) _sync();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    final products = await widget.catalog.products();
    final status = await widget.syncService.status();
    final shift = await widget.shifts.activeShift(widget.session.scope.userId);
    if (!mounted) return;
    setState(() {
      _products = products;
      _status = status;
      _shift = shift;
    });
  }

  /// Opening the till asks for the float that is already in the drawer.
  ///
  /// It is part of the expected figure, so skipping it would report a variance equal to the
  /// float on every shift — and a control that is always wrong is one that gets ignored.
  Future<void> _openShift() async {
    final controller = TextEditingController(text: '0');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t('shift.openTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.t('shift.openingFloatHint'),
                style: const TextStyle(fontSize: 13.5)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  InputDecoration(labelText: context.t('shift.openingFloat')),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.t('shift.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.t('shift.open')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final birr = double.tryParse(controller.text.trim()) ?? 0;
    final shift = await widget.shifts.openShift(
      userId: widget.session.scope.userId,
      branchId: _branchId,
      // Parsed once, at the edge, and immediately integral. Nothing downstream sees a
      // double (guardian G4).
      openingFloatSantim: (birr * 100).round(),
    );
    if (!mounted) return;
    setState(() => _shift = shift);
    await _load();
  }

  /// Receiving stock and counting it are both branch-scoped capabilities the FR-2 matrix
  /// grants a cashier (`goods.receive`) — this is counter work, not back-office work.
  Future<void> _openInventory(Widget screen) async {
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => screen));
    if (!mounted) return;
    await _load();
    await _sync();
  }

  Future<void> _cashUp() async {
    final shift = _shift;
    if (shift == null) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CashUpScreen(
          shift: shift,
          shifts: widget.shifts,
          onCompleted: (_) {},
        ),
      ),
    );
    if (!mounted) return;
    await _load();
    // The close and the cash-up are queued; push them when there is a network.
    await _sync();
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _status = SyncStatus(
        state: SyncState.syncing,
        pending: _status.pending,
        needsAttention: _status.needsAttention,
      );
    });
    final status = await widget.syncService.sync(
      token: widget.session.accessToken,
      refreshToken: widget.session.refreshToken,
      tenantId: widget.session.scope.tenantId,
      branchId: _branchId,
      actorId: widget.session.scope.userId,
      terminalId: widget.terminalId,
      onRenewed: widget.onSessionRenewed,
    );
    if (!mounted) return;
    setState(() {
      _status = status;
      _syncing = false;
    });
    await _load();
  }

  Future<void> _addToCart(LocalProduct product) async {
    // Belt and braces with the matrix: a role that cannot sell should not reach a cart in
    // the first place, but the check costs nothing and the server enforces it regardless.
    if (!_can(Capability.saleCreate)) return;

    // Controlled substances route through the immutable ledger and carry dispensing rules
    // that arrive in Phase 2, behind the A-1 compliance gate. Refusing here is honest;
    // selling one through the standard path would put an unauditable record in the system.
    if (product.isControlled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t('pos.controlledLater'))),
      );
      return;
    }

    // FEFO picks the batch (AC-3.2). A null batch does NOT stop the sale: the terminal may
    // simply not know about stock that exists, and the counter keeps running (BR-3.2).
    var batch = await widget.catalog.fefoBatch(product.id, _branchId);
    String? overrideBy;

    if (batch == null) {
      // Nothing in date. Before asking the user to sell blind, find out whether the reason is
      // "no stock" or "the only stock here is expired" — those are very different things to
      // the person about to take a box off the shelf (E-4.2, ADR-020).
      final expired =
          await widget.catalog.expiredFallbackBatch(product.id, _branchId);
      if (!mounted) return;

      if (expired != null) {
        final authorised = await _confirmExpiredDispense(product, expired);
        if (!mounted) return;
        if (authorised) {
          batch = expired;
          overrideBy = widget.session.scope.userId;
        }
        // Declined, or not authorised to override: the sale still proceeds, unattributed.
        // Refusing it would not stop the box leaving the shelf — it would only stop the
        // pharmacy trading (NFR-1.2), and the discrepancy surfaces at the next count.
      }
    }

    if (!mounted) return;
    setState(() {
      final existing =
          _cart.indexWhere((line) => line.product.id == product.id);
      if (existing >= 0) {
        final line = _cart[existing];
        _cart[existing] = CartLine(
          product: line.product,
          qty: line.qty + 1,
          batchId: line.batchId,
        );
      } else {
        _cart.add(CartLine(
          product: product,
          qty: 1,
          batchId: batch?.id,
          expiryOverrideBy: overrideBy,
        ));
      }
    });
  }

  /// Warns that the only stock is expired, and asks for an override (E-4.2, ADR-020).
  ///
  /// Returns true only when somebody who *may* authorise it has done so. A cashier sees the
  /// warning too — they simply have no button, because the matrix denies them
  /// `expiry.override` and this screen never renders a control the server would refuse.
  Future<bool> _confirmExpiredDispense(
      LocalProduct product, LocalBatch expired) async {
    final mayOverride = _can(Capability.expiryOverride);

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded,
            color: PharmaColors.red, size: 36),
        title: Text(dialogContext.t('expired.title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dialogContext.tf('expired.body', {
                'product': product.name,
                'lot': expired.lotNo,
                'date': dialogContext.l10n.calendarDate(expired.expiryDate),
              }),
              style: const TextStyle(fontSize: 14.5, height: 1.4),
            ),
            const SizedBox(height: 12),
            Text(
              dialogContext.t(mayOverride
                  ? 'expired.mayOverride'
                  : 'expired.cannotOverride'),
              style: const TextStyle(
                  fontSize: 13.5, height: 1.4, color: PharmaColors.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext
                .t(mayOverride ? 'expired.doNot' : 'common.continue')),
          ),
          if (mayOverride)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: PharmaColors.red),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(dialogContext.t('expired.authorise')),
            ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _commit() async {
    if (_cart.isEmpty) return;
    final started = DateTime.now();

    final sale = await widget.sales.commitSale(
      lines: List.of(_cart),
      tenantId: widget.session.scope.tenantId,
      branchId: _branchId,
      cashierId: widget.session.scope.userId,
      terminalId: widget.terminalId,
      // A missing shift never stops a sale (BR-4.1). It just means this one cannot be
      // attributed to a till session, which the cash-up banner tells the cashier about.
      shiftId: _shift?.id,
    );

    final elapsed = DateTime.now().difference(started).inMilliseconds;
    if (!mounted) return;

    setState(() => _cart.clear());
    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: PharmaColors.greenDark,
        content: Text(
          '${context.t('pos.saleCommitted')} · ${formatEtb(sale.totalSantim)} · '
          '${context.t('pos.savedLocally')} (${elapsed}ms)',
        ),
        // No action button. A SnackBar with an action persists until dismissed, and this
        // one sits exactly over "Take cash & commit" — found on a phone, where the next
        // customer's sale could not be committed until the cashier swiped it away. The sale
        // syncs itself below; the sync chip remains the manual control.
      ),
    );
    // Push it now rather than on the next tick, without holding the counter for it: the
    // sale is already durable, and the network is allowed to be slow or absent.
    unawaited(_sync());
  }

  int get _cartTotal =>
      _cart.fold(0, (sum, line) => sum + line.lineTotalSantim);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('pos.title')),
        actions: [
          if (_can(Capability.goodsReceive))
            PopupMenuButton<String>(
              icon: const Icon(Icons.inventory_2_outlined),
              tooltip: context.t('stock.menu'),
              onSelected: (choice) => _openInventory(
                choice == 'receive'
                    ? ReceiveScreen(
                        catalog: widget.catalog,
                        inventory: widget.inventory,
                        branchId: _branchId,
                      )
                    : ReconcileScreen(
                        catalog: widget.catalog,
                        inventory: widget.inventory,
                        branchId: _branchId,
                      ),
              ),
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'receive', child: Text(context.t('stock.receive'))),
                PopupMenuItem(
                    value: 'count', child: Text(context.t('stock.count'))),
              ],
            ),
          // Switchable per user, from the screen they spend the day on — a language buried
          // in a settings page is one nobody finds on a shared counter terminal.
          PopupMenuButton<String>(
            icon: const Icon(Icons.language),
            tooltip: context.t('settings.language'),
            onSelected: L10n.of(context).onChange,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'en', child: Text('English')),
              PopupMenuItem(value: 'am', child: Text('አማርኛ')),
            ],
          ),
          if (_shift != null && _can(Capability.cashupPerform))
            IconButton(
              icon: const Icon(Icons.calculate_outlined),
              onPressed: _cashUp,
              tooltip: context.t('cashup.title'),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: SyncChip(status: _status, onTap: _sync)),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: widget.onSignOut,
            tooltip: context.t('settings.signOut'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Said out loud rather than left as a silently missing button. The matrix rule —
          // never render a denied control — is right when the role will *never* have it,
          // because a disabled button teaches people to hunt for the switch. This is the
          // other case: the user does hold the capability and it is temporarily unavailable,
          // and a control that vanishes without explanation reads as the app being broken.
          if (widget.session.offlineWindowExpired)
            const Material(
              color: PharmaColors.amberTint,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off_outlined,
                        size: 18, color: PharmaColors.amber),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        kOfflineExpiryMessage,
                        style: TextStyle(
                            color: PharmaColors.amber, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_shift == null && _can(Capability.saleCreate))
            Material(
              color: PharmaColors.amberTint,
              child: InkWell(
                onTap: _openShift,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  child: Row(
                    children: [
                      const Icon(Icons.point_of_sale_outlined,
                          size: 18, color: PharmaColors.amber),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          context.t('shift.noTill'),
                          style: const TextStyle(
                              color: PharmaColors.amber, fontSize: 12.5),
                        ),
                      ),
                      Text(context.t('shift.openTill'),
                          style: const TextStyle(
                              color: PharmaColors.amber,
                              fontWeight: FontWeight.w800,
                              fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          if (_status.state == SyncState.offline)
            Container(
              width: double.infinity,
              color: PharmaColors.amberTint,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                '${context.t('pos.offlineBanner')} (${_status.pending})',
                style:
                    const TextStyle(color: PharmaColors.amber, fontSize: 12.5),
              ),
            ),
          Expanded(
            child: _products.isEmpty
                ? const _EmptyCatalog()
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _products.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final product = _products[index];
                      return Card(
                        child: ListTile(
                          title: Text(product.name),
                          subtitle: Text(
                            product.isControlled
                                ? context.t('pos.controlled')
                                : '${context.t('pos.perUnit')} ${product.unit}',
                            style: TextStyle(
                              color: product.isControlled
                                  ? PharmaColors.amber
                                  : PharmaColors.muted,
                              fontSize: 12.5,
                            ),
                          ),
                          trailing: Text(
                            formatEtb(product.priceSantim),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          onTap: () => _addToCart(product),
                        ),
                      );
                    },
                  ),
          ),
          if (_cart.isNotEmpty)
            _CartBar(
              cart: _cart,
              total: _cartTotal,
              onCommit: _commit,
              totalLabel: context.t('pos.total'),
              commitLabel: context.t('pos.takeCash'),
            ),
        ],
      ),
    );
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inventory_2_outlined,
                  size: 40, color: PharmaColors.faint),
              const SizedBox(height: 12),
              Text(
                context.t('pos.noCatalog'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                context.t('pos.noCatalogHint'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: PharmaColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
}

class _CartBar extends StatelessWidget {
  const _CartBar({
    required this.cart,
    required this.total,
    required this.onCommit,
    required this.totalLabel,
    required this.commitLabel,
  });

  final List<CartLine> cart;
  final int total;
  final VoidCallback onCommit;
  final String totalLabel;
  final String commitLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 12,
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in cart)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                          child: Text('${line.qty} × ${line.product.name}')),
                      Text(formatEtb(line.lineTotalSantim)),
                    ],
                  ),
                ),
              const Divider(),
              Row(
                children: [
                  Text(totalLabel,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text(
                    formatEtb(total),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 17),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: onCommit, child: Text(commitLabel)),
            ],
          ),
        ),
      ),
    );
  }
}
