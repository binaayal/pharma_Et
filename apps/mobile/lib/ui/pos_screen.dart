import 'package:flutter/material.dart';

import '../auth/session.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/sale_repository.dart';
import '../sync/sync_service.dart';
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
    required this.syncService,
    required this.terminalId,
    required this.onSignOut,
  });

  final CachedSession session;
  final CatalogRepository catalog;
  final SaleRepository sales;
  final SyncService syncService;
  final String terminalId;
  final VoidCallback onSignOut;

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  List<LocalProduct> _products = [];
  final List<CartLine> _cart = [];
  SyncStatus _status = const SyncStatus(
    state: SyncState.idle,
    pending: 0,
    needsAttention: 0,
  );
  bool _syncing = false;

  String get _branchId => widget.session.primaryBranchId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
    _sync();
  }

  Future<void> _load() async {
    final products = await widget.catalog.products();
    final status = await widget.syncService.status();
    if (!mounted) return;
    setState(() {
      _products = products;
      _status = status;
    });
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
      tenantId: widget.session.scope.tenantId,
      branchId: _branchId,
      actorId: widget.session.scope.userId,
      terminalId: widget.terminalId,
    );
    if (!mounted) return;
    setState(() {
      _status = status;
      _syncing = false;
    });
    await _load();
  }

  Future<void> _addToCart(LocalProduct product) async {
    // Controlled substances route through the immutable ledger and carry dispensing rules
    // that arrive in Phase 2, behind the A-1 compliance gate. Refusing here is honest;
    // selling one through the standard path would put an unauditable record in the system.
    if (product.isControlled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Controlled dispensing arrives with the compliance phase.'),
        ),
      );
      return;
    }

    // FEFO picks the batch (AC-3.2). A null batch does NOT stop the sale: the terminal may
    // simply not know about stock that exists, and the counter keeps running (BR-3.2).
    final batch = await widget.catalog.fefoBatch(product.id, _branchId);
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
        _cart.add(CartLine(product: product, qty: 1, batchId: batch?.id));
      }
    });
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
          'Sale committed · ${formatEtb(sale.totalSantim)} · saved locally in ${elapsed}ms',
        ),
        action: SnackBarAction(
          label: 'Sync now',
          textColor: Colors.white,
          onPressed: _sync,
        ),
      ),
    );
  }

  int get _cartTotal =>
      _cart.fold(0, (sum, line) => sum + line.lineTotalSantim);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sell'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: SyncChip(status: _status, onTap: _sync)),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: widget.onSignOut,
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_status.state == SyncState.offline)
            Container(
              width: double.infinity,
              color: PharmaColors.amberTint,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                'Offline — ${_status.pending} sale(s) waiting. Keep selling; they will sync.',
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
                                ? 'Controlled · ledger-dispensed'
                                : 'per ${product.unit}',
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
            _CartBar(cart: _cart, total: _cartTotal, onCommit: _commit),
        ],
      ),
    );
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inventory_2_outlined,
                  size: 40, color: PharmaColors.faint),
              SizedBox(height: 12),
              Text(
                'No catalog yet',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 4),
              Text(
                'Tap the sync chip to pull products and stock from the server.',
                textAlign: TextAlign.center,
                style: TextStyle(color: PharmaColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
}

class _CartBar extends StatelessWidget {
  const _CartBar(
      {required this.cart, required this.total, required this.onCommit});

  final List<CartLine> cart;
  final int total;
  final VoidCallback onCommit;

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
                  const Text('Total',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text(
                    formatEtb(total),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 17),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onCommit,
                child: const Text('Take cash & commit'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
