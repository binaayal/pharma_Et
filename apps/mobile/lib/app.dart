import 'package:flutter/material.dart';

import 'auth/session.dart';
import 'core/theme.dart';
import 'data/catalog_repository.dart';
import 'data/local_db.dart';
import 'data/outbox.dart';
import 'data/sale_repository.dart';
import 'data/shift_repository.dart';
import 'sync/sync_client.dart';
import 'sync/sync_service.dart';
import 'ui/login_screen.dart';
import 'ui/pos_screen.dart';

/// Composition root.
///
/// Dependencies are built once here and passed down explicitly. At this size that is
/// clearer than a service locator, and it keeps every collaborator visible in a widget's
/// constructor — which matters most for the ones that decide whether a sale is durable.
class PharmaEtApp extends StatefulWidget {
  const PharmaEtApp({super.key, required this.apiBaseUrl});

  /// Defaults to the Android emulator's route to the host machine. A real device or a
  /// deployed build overrides it with --dart-define=API_BASE_URL=...
  final String apiBaseUrl;

  @override
  State<PharmaEtApp> createState() => _PharmaEtAppState();
}

class _PharmaEtAppState extends State<PharmaEtApp> {
  LocalDb? _db;
  late final SessionStore _sessions = SessionStore();
  late final SyncClient _client = SyncClient(baseUrl: widget.apiBaseUrl);

  CatalogRepository? _catalog;
  SaleRepository? _sales;
  ShiftRepository? _shifts;
  SyncService? _syncService;

  CachedSession? _session;
  String? _terminalId;
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final db = await LocalDb.open();
    final outbox = Outbox(db);
    final catalog = CatalogRepository(db);
    final sales = SaleRepository(db, outbox, catalog);
    final shifts = ShiftRepository(db, outbox);

    final terminalId = await _sessions.terminalId();
    final session = await _sessions.load();

    if (!mounted) return;
    setState(() {
      _db = db;
      _catalog = catalog;
      _sales = sales;
      _shifts = shifts;
      _syncService = SyncService(
        db: db,
        outbox: outbox,
        client: _client,
        catalog: catalog,
        sales: sales,
      );
      _terminalId = terminalId;
      _session = session;
      _booting = false;
    });
  }

  @override
  void dispose() {
    _client.close();
    _db?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PharmaEt',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: _booting
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _session == null
              ? LoginScreen(
                  client: _client,
                  terminalId: _terminalId!,
                  onSignedIn: (response, tenantCode) async {
                    await _sessions.save(response, tenantCode);
                    final loaded = await _sessions.load();
                    if (mounted) setState(() => _session = loaded);
                  },
                )
              : PosScreen(
                  session: _session!,
                  catalog: _catalog!,
                  sales: _sales!,
                  shifts: _shifts!,
                  syncService: _syncService!,
                  terminalId: _terminalId!,
                  onSignOut: () async {
                    // Signing out clears the cached scope. It does NOT touch the outbox:
                    // queued sales belong to the pharmacy, not to the session, and they
                    // must still reach the server after the next sign-in.
                    await _sessions.clear();
                    if (mounted) setState(() => _session = null);
                  },
                ),
    );
  }
}
