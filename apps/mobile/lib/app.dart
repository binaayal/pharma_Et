import 'package:flutter/material.dart';

import 'auth/session.dart';
import 'core/theme.dart';
import 'data/catalog_repository.dart';
import 'data/local_db.dart';
import 'data/outbox.dart';
import 'data/inventory_repository.dart';
import 'data/sale_repository.dart';
import 'data/shift_repository.dart';
import 'l10n/locale_store.dart';
import 'l10n/strings.dart';
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
  InventoryRepository? _inventory;
  SyncService? _syncService;

  CachedSession? _session;
  String? _terminalId;
  bool _booting = true;

  /// Set when the local database could not be read and was replaced (ADR-018).
  ///
  /// Held until someone acknowledges it on screen. The terminal is usable throughout — this
  /// gates nothing — but it must not be possible to miss, because it means sales that were
  /// taken on this device and not yet synced are gone.
  String? _quarantinedFile;
  LocaleStore? _locales;
  Strings _strings = Strings.en;

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
    final inventory = InventoryRepository(db, outbox, catalog);

    final locales = LocaleStore(db);
    final strings = Strings.of(await locales.load());

    final terminalId = await _sessions.terminalId();
    final session = await _sessions.load();

    // Read from the database, not from this launch's flag: a force-close after a corrupt
    // start must not be a way to never see the warning (ADR-018).
    final quarantined = await db.pendingQuarantineNotice();

    if (!mounted) return;
    setState(() {
      _quarantinedFile = quarantined;
      _db = db;
      _catalog = catalog;
      _sales = sales;
      _shifts = shifts;
      _inventory = inventory;
      _syncService = SyncService(
        db: db,
        outbox: outbox,
        client: _client,
        catalog: catalog,
        sales: sales,
        inventory: inventory,
      );
      _terminalId = terminalId;
      _session = session;
      _locales = locales;
      _strings = strings;
      _booting = false;
    });
  }

  @override
  void dispose() {
    _client.close();
    _db?.close();
    super.dispose();
  }

  Future<void> _setLocale(String locale) async {
    await _locales?.save(locale);
    if (mounted) setState(() => _strings = Strings.of(locale));
  }

  @override
  Widget build(BuildContext context) {
    return L10n(
      strings: _strings,
      onChange: (locale) => unawaited(_setLocale(locale)),
      child: _buildApp(),
    );
  }

  Widget _buildApp() {
    return MaterialApp(
      title: 'PharmaEt',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: _booting
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _quarantinedFile != null
              ? _RecoveryNotice(
                  quarantinedFile: _quarantinedFile!,
                  onAcknowledge: () async {
                    await _db?.acknowledgeQuarantine();
                    if (mounted) setState(() => _quarantinedFile = null);
                  },
                )
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
                      // A session renewed mid-sync is written back to secure storage and to
                      // the running app, so the refresh token is redeemed once rather than
                      // on every tick (ADR-019).
                      onSessionRenewed: (renewed) async {
                        await _sessions.save(renewed, _session!.tenantCode);
                        final reloaded = await _sessions.load();
                        if (mounted && reloaded != null) {
                          setState(() => _session = reloaded);
                        }
                      },
                      catalog: _catalog!,
                      sales: _sales!,
                      shifts: _shifts!,
                      inventory: _inventory!,
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

/// Shown once after the local database was found unreadable and replaced (ADR-018).
///
/// It interrupts, and it requires a tap. Both are deliberate. The terminal works perfectly
/// from this moment on, which is exactly why a passive banner would be scrolled past: the
/// thing that has gone wrong is invisible in normal use, because a fresh database looks like
/// a quiet day rather than like missing records.
///
/// It does not block trading. The button says so, and it is the only button.
class _RecoveryNotice extends StatelessWidget {
  const _RecoveryNotice({
    required this.quarantinedFile,
    required this.onAcknowledge,
  });

  final String quarantinedFile;
  final Future<void> Function() onAcknowledge;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 44, color: PharmaColors.amber),
                  const SizedBox(height: 16),
                  const Text(
                    'This terminal had to start a new local record',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'The data stored on this device could not be read — usually after a '
                    'power cut or a storage fault. Anything that had already reached the '
                    'server is safe and will come back when you sync.',
                    style: TextStyle(fontSize: 14.5, height: 1.45),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Sales taken on this device that had NOT yet synced are not in the new '
                    'record. Tell the owner, and check the last cash-up against the takings '
                    'you actually have.',
                    style: TextStyle(
                        fontSize: 14.5,
                        height: 1.45,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: PharmaColors.amberTint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'The old record has been kept, not deleted:',
                          style: TextStyle(
                              fontSize: 12.5, color: PharmaColors.amber),
                        ),
                        const SizedBox(height: 6),
                        // Shown in full so it can be read out over the phone to whoever is
                        // helping. A message that says "a file was kept" without saying
                        // which one is not help.
                        SelectableText(
                          quarantinedFile,
                          style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: PharmaColors.amber),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: () => unawaited(onAcknowledge()),
                    child: const Text('I understand — continue selling'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fire-and-forget, deliberately: a language change must not block the UI thread, and a
/// failed write costs the user one re-selection rather than a frozen screen.
void unawaited(Future<void> future) {
  future.catchError((Object _) {});
}
