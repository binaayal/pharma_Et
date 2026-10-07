import '../l10n/strings.dart';
import 'money.dart';

/// The end-of-day summary and the audit trail, as the owner's phone holds them (FR-17,
/// ADR-035). Plain data and the words made from it — no widgets, no network — so that what
/// the owner reads can be tested exactly.

int _int(Object? v) => v == null ? 0 : (v as num).toInt();

class DayShift {
  const DayShift({
    required this.userName,
    required this.branchName,
    required this.closed,
    this.countedSantim,
    this.expectedSantim,
    this.varianceSantim,
  });

  factory DayShift.fromJson(Map<String, dynamic> j) => DayShift(
        userName: (j['userName'] as String?) ?? '',
        branchName: (j['branchName'] as String?) ?? '',
        closed: j['closedAt'] != null,
        countedSantim:
            j['countedSantim'] == null ? null : _int(j['countedSantim']),
        expectedSantim:
            j['expectedSantim'] == null ? null : _int(j['expectedSantim']),
        varianceSantim:
            j['varianceSantim'] == null ? null : _int(j['varianceSantim']),
      );

  final String userName;
  final String branchName;
  final bool closed;
  final int? countedSantim;
  final int? expectedSantim;

  /// `counted − expected`; negative is cash missing. Null until the drawer is counted.
  final int? varianceSantim;
}

class LowStockItem {
  const LowStockItem(
      {required this.name, required this.unit, required this.onHand});
  factory LowStockItem.fromJson(Map<String, dynamic> j) => LowStockItem(
        name: j['productName'] as String,
        unit: (j['unit'] as String?) ?? '',
        onHand: _int(j['onHand']),
      );
  final String name;
  final String unit;
  final int onHand;
}

/// One day at the pharmacy, as the server adds it up.
class DailySummary {
  const DailySummary({
    required this.saleCount,
    required this.grossSantim,
    required this.cashSantim,
    required this.otherTenderSantim,
    required this.creditSantim,
    required this.countedShifts,
    required this.shortageSantim,
    required this.overageSantim,
    required this.openShifts,
    required this.shifts,
    required this.repaidSantim,
    required this.owedSantim,
    required this.customersOwing,
    required this.lowCount,
    required this.low,
    required this.expiringBatches,
    required this.oversoldBatches,
    required this.priceChanges,
    required this.stockWriteOffs,
    required this.expiredDispenses,
    this.lastSyncedAt,
  });

  factory DailySummary.fromJson(Map<String, dynamic> j) {
    final sales = j['sales'] as Map<String, dynamic>;
    final cash = j['cash'] as Map<String, dynamic>;
    final credit = j['credit'] as Map<String, dynamic>;
    final stock = j['stock'] as Map<String, dynamic>;
    final attention = j['attention'] as Map<String, dynamic>;
    return DailySummary(
      saleCount: _int(sales['saleCount']),
      grossSantim: _int(sales['grossSantim']),
      cashSantim: _int(sales['cashSantim']),
      otherTenderSantim: _int(sales['otherTenderSantim']),
      creditSantim: _int(sales['creditSantim']),
      countedShifts: _int(cash['countedShifts']),
      shortageSantim: _int(cash['shortageSantim']),
      overageSantim: _int(cash['overageSantim']),
      openShifts: _int(cash['openShifts']),
      shifts: [
        for (final s in (j['shifts'] as List<dynamic>? ?? const []))
          DayShift.fromJson(s as Map<String, dynamic>),
      ],
      repaidSantim: _int(credit['repaidSantim']),
      owedSantim: _int(credit['owedSantim']),
      customersOwing: _int(credit['customersOwing']),
      lowCount: _int(stock['lowCount']),
      low: [
        for (final r in (stock['low'] as List<dynamic>? ?? const []))
          LowStockItem.fromJson(r as Map<String, dynamic>),
      ],
      expiringBatches: _int(stock['expiringBatches']),
      oversoldBatches: _int(stock['oversoldBatches']),
      priceChanges: _int(attention['priceChanges']),
      stockWriteOffs: _int(attention['stockWriteOffs']),
      expiredDispenses: _int(attention['expiredDispenses']),
      lastSyncedAt: j['lastSyncedAt'] == null
          ? null
          : DateTime.parse(j['lastSyncedAt'] as String),
    );
  }

  final int saleCount;
  final int grossSantim;
  final int cashSantim;
  final int otherTenderSantim;
  final int creditSantim;
  final int countedShifts;

  /// Every shortfall added up, as a positive number. An overage elsewhere does not reduce
  /// it: 50 missing from one till and 50 extra in another is two things to ask about.
  final int shortageSantim;
  final int overageSantim;
  final int openShifts;
  final List<DayShift> shifts;
  final int repaidSantim;
  final int owedSantim;
  final int customersOwing;
  final int lowCount;
  final List<LowStockItem> low;
  final int expiringBatches;
  final int oversoldBatches;
  final int priceChanges;
  final int stockWriteOffs;
  final int expiredDispenses;
  final DateTime? lastSyncedAt;

  /// Who had a till open, each name once, in the order they opened.
  List<String> get onShift {
    final seen = <String>{};
    return [
      for (final s in shifts)
        if (s.userName.isNotEmpty && seen.add(s.userName)) s.userName,
    ];
  }

  /// Whether anything in the day wants the owner's attention. Decides the colour of the
  /// headline, so it is deliberately conservative: an open till at the end of the day, or
  /// one santim missing, counts.
  bool get needsAttention =>
      shortageSantim > 0 ||
      openShifts > 0 ||
      oversoldBatches > 0 ||
      expiredDispenses > 0 ||
      stockWriteOffs > 0;

  /// The summary as a short message — what gets shared to the owner's own chat.
  ///
  /// Every line is a fact with its number; nothing is rounded and nothing is left out
  /// because it is zero where zero is the news ("all tills balanced").
  String toText(Strings s, {required String shop, required String day}) {
    String f(String key, Map<String, Object> p) => s.f(key, p);
    final out = <String>[
      '$shop — $day',
      f('day.text.sales', {
        'n': saleCount,
        'total': formatEtbShort(grossSantim),
      }),
      f('day.text.split', {
        'cash': formatMoney(cashSantim),
        'other': formatMoney(otherTenderSantim),
        'credit': formatMoney(creditSantim),
      }),
      if (countedShifts == 0 && openShifts == 0)
        s.get('day.text.noTill')
      else if (shortageSantim > 0)
        f('day.text.short', {'amount': formatMoney(shortageSantim)})
      else if (countedShifts > 0)
        f('day.text.balanced', {'n': countedShifts}),
      if (overageSantim > 0)
        f('day.text.over', {'amount': formatMoney(overageSantim)}),
      if (openShifts > 0) f('day.text.open', {'n': openShifts}),
      if (onShift.isNotEmpty)
        f('day.text.onShift', {'names': onShift.join(', ')}),
      f('day.text.owed', {
        'owed': formatMoney(owedSantim),
        'n': customersOwing,
        'repaid': formatMoney(repaidSantim),
      }),
      if (lowCount > 0)
        f('day.text.low', {
          'n': lowCount,
          'names': low.take(4).map((r) => '${r.name} (${r.onHand})').join(', '),
        }),
      if (expiringBatches > 0) f('day.text.expiring', {'n': expiringBatches}),
      if (oversoldBatches > 0) f('day.text.oversold', {'n': oversoldBatches}),
      if (priceChanges > 0) f('day.text.prices', {'n': priceChanges}),
      if (stockWriteOffs > 0) f('day.text.writeOffs', {'n': stockWriteOffs}),
      if (expiredDispenses > 0) f('day.text.expired', {'n': expiredDispenses}),
    ];
    return out.join('\n');
  }
}

/// One entry in the audit trail.
class AuditEntry {
  const AuditEntry({
    required this.eventType,
    required this.occurredAt,
    required this.payload,
    this.actorName,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        eventType: j['eventType'] as String,
        occurredAt: DateTime.parse(j['occurredAt'] as String),
        payload: (j['payload'] as Map<String, dynamic>?) ?? const {},
        actorName: j['actorName'] as String?,
      );

  final String eventType;
  final DateTime occurredAt;
  final Map<String, dynamic> payload;

  /// Null when the actor is not one of the pharmacy's own people — the platform.
  final String? actorName;

  /// Which filter chip this entry belongs under.
  AuditKind get kind => switch (eventType) {
        'audit.price_changed' ||
        'audit.packs_changed' ||
        'audit.product_created' ||
        'audit.barcodes_changed' =>
          AuditKind.prices,
        'audit.stock_adjusted' || 'audit.expired_dispense' => AuditKind.stock,
        'audit.user_created' ||
        'audit.user_deactivated' ||
        'audit.branch_created' ||
        'audit.branch_updated' =>
          AuditKind.staff,
        _ => AuditKind.account,
      };

  /// Whether an owner reviewing for something wrong should look at this one first: money
  /// made cheaper, stock written off, expired medicine handed over.
  bool get flagged {
    switch (eventType) {
      case 'audit.price_changed':
        return _int(payload['priceSantim']) <
            _int(payload['previousPriceSantim']);
      case 'audit.stock_adjusted':
        return _int(payload['delta']) < 0 && payload['reason'] != 'recount';
      case 'audit.expired_dispense':
        return true;
      default:
        return false;
    }
  }

  /// What happened, in a sentence. [productName] resolves a product id from the catalogue
  /// on this phone; where it cannot, the sentence says "a product" rather than an id
  /// nobody can read.
  String describe(Strings s, {String? Function(String id)? productName}) {
    final p = payload;
    String product() =>
        (p['productName'] as String?) ??
        (p['productId'] is String
            ? productName?.call(p['productId'] as String)
            : null) ??
        s.get('audit.aProduct');
    switch (eventType) {
      case 'audit.price_changed':
        return s.f('audit.say.price', {
          'product': product(),
          'from': formatMoney(_int(p['previousPriceSantim'])),
          'to': formatMoney(_int(p['priceSantim'])),
        });
      case 'audit.packs_changed':
        return s.f('audit.say.packs', {'product': product()});
      case 'audit.barcodes_changed':
        return s.f('audit.say.barcodes', {'product': product()});
      case 'audit.product_created':
        return s.f('audit.say.productCreated', {
          'product': (p['name'] as String?) ?? s.get('audit.aProduct'),
          'price': formatMoney(_int(p['priceSantim'])),
        });
      case 'audit.stock_adjusted':
        final delta = _int(p['delta']);
        return s.f(delta < 0 ? 'audit.say.stockDown' : 'audit.say.stockUp', {
          'product': product(),
          'n': delta.abs(),
          'reason': s.get('audit.reason.${p['reason'] ?? 'other'}'),
        });
      case 'audit.expired_dispense':
        return s.f(
            p['authorisedBy'] == null
                ? 'audit.say.expiredUnauthorised'
                : 'audit.say.expired',
            {
              'product': product(),
              'n': _int(p['qty']),
              'lot': (p['lotNo'] as String?) ?? '—',
            });
      case 'audit.user_created':
        return s.f('audit.say.userCreated', {
          'user': (p['username'] as String?) ?? '—',
          'role': s.get('role.${p['role'] ?? 'cashier'}'),
        });
      case 'audit.user_deactivated':
        return s.f('audit.say.userDeactivated',
            {'user': (p['username'] as String?) ?? '—'});
      case 'audit.branch_created':
        return s.f('audit.say.branchCreated',
            {'branch': (p['name'] as String?) ?? '—'});
      case 'audit.branch_updated':
        return s.get('audit.say.branchUpdated');
      case 'audit.payment_proof_submitted':
        return s.f('audit.say.proofSubmitted',
            {'amount': formatMoney(_int(p['amountSantim']))});
      case 'audit.payment_accepted':
        return s.get('audit.say.paymentAccepted');
      case 'audit.payment_rejected':
        return s.get('audit.say.paymentRejected');
      case 'audit.payment_proof_image_deleted':
        return s.get('audit.say.proofImageDeleted');
      case 'audit.subscription_changed':
        return s.get('audit.say.subscriptionChanged');
      case 'audit.tenant_onboarded':
        return s.get('audit.say.tenantOnboarded');
      case 'audit.tenant_deactivated':
        return s.get('audit.say.tenantDeactivated');
      case 'audit.tenant_reactivated':
        return s.get('audit.say.tenantReactivated');
      default:
        // An event this version of the app has no sentence for — a newer server's. Shown
        // by its name rather than hidden: an audit trail does not get to skip entries.
        return eventType.replaceFirst('audit.', '').replaceAll('_', ' ');
    }
  }

  /// The free-text explanation someone gave, where the event carries one.
  String? get note {
    final n = payload['note'];
    return n is String && n.trim().isNotEmpty ? n.trim() : null;
  }
}

enum AuditKind { prices, stock, staff, account }
