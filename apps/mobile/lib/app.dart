import 'dart:async' as async;

import 'package:flutter/material.dart';

import 'api/tenant_api.dart';
import 'auth/branch_placement.dart';
import 'auth/offline_credentials.dart';
import 'auth/session.dart';
import 'contracts/contracts.dart';
import 'core/theme.dart';
import 'data/catalog_repository.dart';
import 'data/controlled_repository.dart';
import 'data/local_db.dart';
import 'data/outbox.dart';
import 'data/inventory_repository.dart';
import 'data/sale_repository.dart';
import 'data/shift_repository.dart';
import 'l10n/locale_store.dart';
import 'l10n/strings.dart';
import 'sync/sync_client.dart';
import 'sync/sync_service.dart';
import 'ui/branch_picker_screen.dart';
import 'ui/kit.dart';
import 'ui/login_screen.dart';
import 'ui/request_account_screen.dart';
import 'ui/shell.dart';
import 'ui/terminal.dart';

/// Composition root.
///
/// Dependencies are built once here and passed down explicitly — the ones that decide
/// whether a sale is durable most of all. Once someone is signed in and the device knows
/// its branch, one [Terminal] carries them to every screen through [TerminalScope].
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
  late final TenantApi _api = TenantApi(baseUrl: widget.apiBaseUrl);
  final _offline = OfflineCredentials();
  final _navigator = GlobalKey<NavigatorState>();

  CatalogRepository? _catalog;
  SaleRepository? _sales;
  ShiftRepository? _shifts;
  InventoryRepository? _inventory;
  ControlledRepository? _controlled;
  SyncService? _syncService;

  CachedSession? _session;
  String? _terminalId;
  RememberedIdentity? _identity;
  Terminal? _terminal;

  /// Set while the signed-in user's session does not settle which branch this device is
  /// in, and nobody has chosen yet. The counter does not open until it is cleared.
  Placement? _placement;
  bool _booting = true;

  /// Set when the local database could not be read and was replaced (ADR-018). Held until
  /// someone acknowledges it; it gates nothing, but it must not be possible to miss.
  String? _quarantinedFile;
  LocaleStore? _locales;
  Strings _strings = Strings.en;

  @override
  void initState() {
    super.initState();
    async.unawaited(_boot());
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
    final identity = await _sessions.lastIdentity();

    // Read from the database, not this launch's flag: a force-close after a corrupt start
    // must not be a way to never see the warning (ADR-018).
    final quarantined = await db.pendingQuarantineNotice();

    if (!mounted) return;
    setState(() {
      _quarantinedFile = quarantined;
      _db = db;
      _catalog = catalog;
      _sales = sales;
      _shifts = shifts;
      _inventory = inventory;
      _controlled = ControlledRepository(db, outbox);
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
      _identity = identity;
      _locales = locales;
      _strings = strings;
      _booting = false;
    });
    await _place();
  }

  /// Makes sure the counter never opens without a branch (see [placeTerminal]).
  Future<void> _place() async {
    final session = _session;
    if (session == null) return;
    if (session.primaryBranchId != null) {
      await _openTerminal();
      return;
    }
    final placement = await placeTerminal(
      session: session,
      fetchBranches: () => _fetchBranches(session),
    );
    if (placement is Placed) {
      await _choose(placement.branchId);
    } else if (mounted) {
      setState(() => _placement = placement);
    }
  }

  /// The branch list rides on the pull the terminal makes anyway. A session restored at
  /// boot may hold an access token that has aged out, so a 401 renews once first.
  Future<List<BranchRef>> _fetchBranches(CachedSession session) async {
    try {
      return (await _client.pull(token: session.accessToken, cursor: 0))
          .branches;
    } on SyncTransportException catch (e) {
      if (e.statusCode != 401 || session.refreshToken.isEmpty) rethrow;
      final renewed = await _client.refresh(
          refreshToken: session.refreshToken, terminalId: _terminalId!);
      await _sessions.save(renewed, session.tenantCode);
      return (await _client.pull(token: renewed.accessToken, cursor: 0))
          .branches;
    }
  }

  Future<void> _choose(String branchId, {String? name}) async {
    await _sessions.setTerminalBranch(_session!.scope.tenantId, branchId,
        name: name);
    final reloaded = await _sessions.load();
    if (!mounted) return;
    setState(() {
      _session = reloaded;
      _placement = null;
    });
    await _openTerminal();
  }

  /// AC-1.1: a new pharmacy's owner creates its first branch before anything else.
  Future<void> _createFirstBranch(String name, String address) async {
    final session = _session!;
    Future<BranchInfo> create(String token) =>
        _api.createBranch(token, name: name, address: address);
    BranchInfo branch;
    try {
      branch = await create(session.accessToken);
    } on ApiException catch (e) {
      if (e.statusCode != 401) rethrow;
      final renewed = await _client.refresh(
          refreshToken: session.refreshToken, terminalId: _terminalId!);
      await _sessions.save(renewed, session.tenantCode);
      branch = await create(renewed.accessToken);
    }
    await _choose(branch.id, name: branch.name);
  }

  Future<void> _openTerminal() async {
    final session = _session;
    if (session == null || !mounted) return;
    _terminal?.dispose();
    final terminal = Terminal(
      session: session,
      terminalId: _terminalId!,
      catalog: _catalog!,
      sales: _sales!,
      shifts: _shifts!,
      inventory: _inventory!,
      controlled: _controlled!,
      syncService: _syncService!,
      api: _api,
      client: _client,
      branchName: await _sessions.terminalBranchName(session.scope.tenantId),
      // A session renewed mid-sync is written back once, so the refresh token is redeemed
      // once rather than on every tick (ADR-019).
      onSessionRenewed: (renewed) async {
        await _sessions.save(renewed, _session!.tenantCode);
        final who = _identity;
        if (who != null) {
          await _offline.refreshSession(who.tenantCode, who.username, renewed);
        }
        final reloaded = await _sessions.load();
        if (mounted && reloaded != null) {
          _session = reloaded;
          _terminal?.session = reloaded;
        }
      },
      onSignOut: () => async.unawaited(_signOut()),
    );
    setState(() => _terminal = terminal);
    await terminal.start();
    if (terminal.branchName == null) {
      async.unawaited(_learnBranchName(terminal));
    }
  }

  /// For a one-branch user nobody picked a branch by name, so learn it once, online.
  Future<void> _learnBranchName(Terminal terminal) async {
    try {
      final branches = await terminal.authed(_api.branches);
      final match = branches.where((b) => b.id == terminal.branchId);
      if (match.isEmpty) return;
      await _sessions.setTerminalBranchName(
          terminal.session.scope.tenantId, terminal.branchId, match.first.name);
      terminal.branchName = match.first.name;
      await terminal.refresh();
    } catch (_) {
      // Offline or not permitted: the pharmacy code stands in until next time.
    }
  }

  Future<void> _signIn(LoginResponse response, String tenantCode,
      String username, bool usedPassword) async {
    await _sessions.save(response, tenantCode);
    final identity = RememberedIdentity(
      tenantCode: tenantCode,
      username: username,
      displayName: response.scope.displayName,
      usesPassword: usedPassword,
    );
    await _sessions.rememberIdentity(identity);
    final loaded = await _sessions.load();
    if (!mounted) return;
    setState(() {
      _session = loaded;
      _identity = identity;
    });
    await _place();
  }

  Future<void> _signOut() async {
    // Signing out clears the cached scope. It does NOT touch the outbox: queued sales
    // belong to the pharmacy, not to the session, and must still reach the server after
    // the next sign-in. Nor the terminal's branch: the device has not moved.
    await _sessions.clear();
    _navigator.currentState?.popUntil((route) => route.isFirst);
    _terminal?.dispose();
    if (mounted) {
      setState(() {
        _terminal = null;
        _session = null;
        _placement = null;
      });
    }
  }

  @override
  void dispose() {
    _terminal?.dispose();
    _client.close();
    _api.close();
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
      onChange: (locale) => async.unawaited(_setLocale(locale)),
      child: MaterialApp(
        title: 'PharmaEt',
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        // Above the Navigator, so a pushed screen sees the terminal as well as the tabs do.
        builder: (context, child) => _terminal == null
            ? child!
            : TerminalScope(terminal: _terminal!, child: child!),
        home: _home(),
      ),
    );
  }

  Widget _home() {
    if (_booting) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_quarantinedFile != null) {
      return _RecoveryNotice(
        quarantinedFile: _quarantinedFile!,
        onAcknowledge: () async {
          await _db?.acknowledgeQuarantine();
          if (mounted) setState(() => _quarantinedFile = null);
        },
      );
    }
    if (_session == null) {
      return LoginScreen(
        key: ValueKey(_identity?.username ?? '-'),
        client: _client,
        terminalId: _terminalId!,
        remembered: _identity,
        offline: _offline,
        onForget: () async {
          await _sessions.forgetIdentity();
          if (mounted) setState(() => _identity = null);
        },
        onRequestAccount: () => _navigator.currentState!.push(
            MaterialPageRoute<void>(
                builder: (_) => RequestAccountScreen(api: _api))),
        onSignedIn: (response, tenantCode, username, usedPassword) => async
            .unawaited(_signIn(response, tenantCode, username, usedPassword)),
      );
    }
    if (_placement != null) {
      return BranchPickerScreen(
        placement: _placement!,
        canCreate: _session!.scope.role == 'owner',
        onChosen: (id, name) => async.unawaited(_choose(id, name: name)),
        onCreate: _createFirstBranch,
        onRetry: () => async.unawaited(_place()),
        onSignOut: () => async.unawaited(_signOut()),
      );
    }
    if (_terminal == null) {
      // Still resolving the branch — a moment, and usually no network at all.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return const Shell();
  }
}

/// Shown once after the local database was found unreadable and replaced (ADR-018).
///
/// It interrupts, and it requires a tap: the thing that has gone wrong is invisible in
/// normal use, because a fresh database looks like a quiet day rather than missing
/// records. It does not block trading — the button says so, and it is the only button.
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
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                children: [
                  const PMark(
                      icon: Icons.warning_amber_rounded, size: 74, warn: true),
                  const SizedBox(height: 20),
                  Text(
                    context.t('recovery.title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: PharmaColors.red),
                  ),
                  const SizedBox(height: 14),
                  Text(context.t('recovery.body'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14.5, height: 1.5)),
                  const SizedBox(height: 14),
                  PNotice.text(
                      Tone.red, Icons.info_outline, context.t('recovery.lost')),
                  PNotice(
                    tone: Tone.amber,
                    icon: Icons.inventory_2_outlined,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(context.t('recovery.kept')),
                        const SizedBox(height: 6),
                        // In full, so it can be read out over the phone to whoever helps.
                        SelectableText(quarantinedFile,
                            style: const TextStyle(
                                fontSize: 11.5, fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  PButton(
                    label: context.t('recovery.ack'),
                    onPressed: () => async.unawaited(onAcknowledge()),
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
