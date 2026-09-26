import '../core/compliance.dart';
import '../core/ids.dart';
import '../core/money.dart';
import 'catalog_repository.dart';
import 'local_db.dart';
import 'outbox.dart';

/// Why a dispense was blocked at the till. BR-4.2: blocked, never warned.
enum DispenseBlock {
  expired,
  notYetValid,
  anotherPsychotropic,
  noPrescriptionNumber
}

class DispenseBlocked implements Exception {
  DispenseBlocked(this.reason, {this.daysUsed});
  final DispenseBlock reason;
  final int? daysUsed;
}

/// Controlled dispensing on the till (FR-4 §4a–4b, FR-6; ADR-024).
///
/// The rules run here, against this device's own record, so they hold with no network; the
/// server applies them again on sync and is the authority. A dispense is one local
/// transaction — the sale (so the cash reaches the cash-up), the dispense record (so the next
/// prescription check can see it), and the outbox entry (so it will sync) commit together.
class ControlledRepository {
  ControlledRepository(this._db, this._outbox);

  final LocalDb _db;
  final Outbox _outbox;

  static const _switchKey = 'controlled_dispensing';

  /// The server's switch as last seen online (ADR-024), so a till that learned it was on can
  /// keep dispensing through an outage — and one that never heard it was on never starts.
  Future<bool> enabled() async => await _db.meta(_switchKey) == 'on';

  Future<void> rememberSwitch(bool on) =>
      _db.setMeta(_switchKey, on ? 'on' : 'off');

  /// Checks the rules for [product] against a prescription, without writing anything.
  Future<({int daysUsed})> check({
    required LocalProduct product,
    required String prescriptionNo,
    required String issuedOn,
    DateTime? now,
  }) async {
    final key = normalisePrescriptionNumber(prescriptionNo);
    if (PsychotropicRules.dedicatedPrescriptionRequired && key.isEmpty) {
      throw DispenseBlocked(DispenseBlock.noPrescriptionNumber);
    }
    final validity =
        prescriptionValidOn(issuedOn, addisDate(now ?? DateTime.now()));
    if (validity.daysUsed < 0) {
      throw DispenseBlocked(DispenseBlock.notYetValid,
          daysUsed: validity.daysUsed);
    }
    if (!validity.valid) {
      throw DispenseBlocked(DispenseBlock.expired, daysUsed: validity.daysUsed);
    }
    final others = await _db.db.rawQuery(
      'SELECT DISTINCT product_id FROM controlled_dispense '
      'WHERE prescription_key = ? AND product_id <> ?',
      [key, product.id],
    );
    if (others.length >=
        PsychotropicRules.maxPsychotropicSubstancesPerPrescription) {
      throw DispenseBlocked(DispenseBlock.anotherPsychotropic);
    }
    return (daysUsed: validity.daysUsed);
  }

  /// Records the dispense and its sale, and queues it — after checking the rules again.
  Future<String> dispense({
    required LocalProduct product,
    required int qty,
    required String prescriptionNo,
    required String prescriber,
    required String issuedOn,
    required String branchId,
    required String cashierId,
    String? shiftId,
    String paymentMethod = 'cash',
  }) async {
    await check(
        product: product, prescriptionNo: prescriptionNo, issuedOn: issuedOn);

    final saleId = newId();
    final lineId = newId();
    final paymentId = newId();
    final dispensedAt = DateTime.now().toUtc().toIso8601String();
    final total =
        lineTotalSantim(qty: qty, unitPriceSantim: product.priceSantim);

    await _db.db.transaction((txn) async {
      await txn.insert('sale', {
        'id': saleId,
        'branch_id': branchId,
        'cashier_id': cashierId,
        'shift_id': shiftId,
        'total_santim': total,
        'sold_at': dispensedAt,
        'synced': 0,
      });
      await txn.insert('sale_line', {
        'id': lineId,
        'sale_id': saleId,
        'product_id': product.id,
        'batch_id': null,
        'qty': qty,
        'unit_price_santim': product.priceSantim,
        'line_total_santim': total,
      });
      await txn.insert('payment', {
        'id': paymentId,
        'sale_id': saleId,
        'method': paymentMethod,
        'amount_santim': total,
      });
      await txn.insert('controlled_dispense', {
        'id': newId(),
        'sale_id': saleId,
        'product_id': product.id,
        'qty': qty,
        'prescription_no': prescriptionNo.trim(),
        'prescription_key': normalisePrescriptionNumber(prescriptionNo),
        'prescriber': prescriber.trim(),
        'issued_on': issuedOn,
        'dispensed_at': dispensedAt,
      });
      await _outbox.enqueue(
        txn,
        opId: newId(),
        entityType: 'controlled_dispense',
        entityId: saleId,
        payload: {
          'shiftId': shiftId,
          'cashierId': cashierId,
          'dispensedAt': dispensedAt,
          'productId': product.id,
          'lineId': lineId,
          'qty': qty,
          'unitPriceSantim': product.priceSantim,
          'lineTotalSantim': total,
          'prescription': {
            'number': prescriptionNo.trim(),
            'prescriber': prescriber.trim(),
            'issuedOn': issuedOn,
          },
          'payments': [
            {'id': paymentId, 'method': paymentMethod, 'amountSantim': total},
          ],
        },
      );
    });
    return saleId;
  }
}
