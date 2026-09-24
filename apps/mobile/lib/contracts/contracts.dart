// GENERATED FILE — DO NOT EDIT.
//
// Generated from packages/contracts/src by `pnpm gen:contracts`.
// Edit the Zod schemas there and regenerate; CI fails if this file is stale (ADR-010).
//
// The sync envelope is a CONTROLLED ARTIFACT (docs/06-delivery-plan.md §7): changing it
// needs an ADR, both-side contract tests including N-1 (ADR-009), a guardian-suite update,
// two reviews, and an RTM entry.
//
// Contract version: 1.2.0

// ignore_for_file: unnecessary_cast, lines_longer_than_80_chars, unnecessary_this

/// The contract version this client speaks, sent as the `x-contract-version` header.
const String kContractVersion = '1.2.0';

bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int _deepHash(Object? value) {
  if (value is List) return Object.hashAll(value.map(_deepHash));
  return value.hashCode;
}

/// Discriminated on `entityType`.
///
/// An unrecognised discriminator throws instead of being skipped: an operation we cannot
/// parse is an incident to surface, never a transaction to drop on the floor.
sealed class Operation {
  const Operation();

  Map<String, dynamic> toJson();

  static Operation fromJson(Map<String, dynamic> json) {
    switch (json['entityType'] as String) {
      case 'sale':
        return OperationSale.fromJson(json);
      case 'goods_receipt':
        return OperationGoodsReceipt.fromJson(json);
      case 'shift':
        return OperationShift.fromJson(json);
      case 'cash_up':
        return OperationCashUp.fromJson(json);
      case 'stock_adjustment':
        return OperationStockAdjustment.fromJson(json);
      default:
        throw FormatException('unknown entityType: ${json['entityType']}');
    }
  }
}

class OperationSale extends Operation {
  const OperationSale({
    required this.opId,
    required this.terminalId,
    required this.terminalSeq,
    required this.entityId,
    required this.opType,
    this.baseVersion,
    required this.tenantId,
    this.branchId,
    required this.actorId,
    required this.clientTs,
    required this.entityType,
    required this.payload,
  }) : super();

  /// Client-generated UUIDv7 identifier
  final String opId;
  final String terminalId;
  /// Monotonic per-terminal sequence number; the ordering key
  final int terminalSeq;
  final String entityId;
  final String opType;
  final int? baseVersion;
  final String tenantId;
  /// Client-generated UUIDv7 identifier
  final String? branchId;
  final String actorId;
  /// UTC ISO-8601 timestamp
  final String clientTs;
  final String entityType;
  final SalePayload payload;

  factory OperationSale.fromJson(Map<String, dynamic> json) => OperationSale(
        opId: json['opId'] as String,
        terminalId: json['terminalId'] as String,
        terminalSeq: json['terminalSeq'] as int,
        entityId: json['entityId'] as String,
        opType: json['opType'] as String,
        baseVersion: json['baseVersion'] == null ? null : json['baseVersion'] as int,
        tenantId: json['tenantId'] as String,
        branchId: json['branchId'] == null ? null : json['branchId'] as String,
        actorId: json['actorId'] as String,
        clientTs: json['clientTs'] as String,
        entityType: json['entityType'] as String,
        payload: SalePayload.fromJson(json['payload'] as Map<String, dynamic>),
      );

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'opId': opId,
        'terminalId': terminalId,
        'terminalSeq': terminalSeq,
        'entityId': entityId,
        'opType': opType,
        'baseVersion': baseVersion,
        'tenantId': tenantId,
        'branchId': branchId,
        'actorId': actorId,
        'clientTs': clientTs,
        'entityType': entityType,
        'payload': payload.toJson(),
      };

  List<Object?> get _props => <Object?>[opId, terminalId, terminalSeq, entityId, opType, baseVersion, tenantId, branchId, actorId, clientTs, entityType, payload];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is OperationSale && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'OperationSale(${toJson()})';
}

class SalePayload {
  const SalePayload({
    this.shiftId,
    required this.cashierId,
    required this.soldAt,
    required this.totalSantim,
    required this.lines,
    required this.payments,
  });

  /// Client-generated UUIDv7 identifier
  final String? shiftId;
  final String cashierId;
  final String soldAt;
  /// Money in santim (1 ETB = 100 santim)
  final int totalSantim;
  final List<SaleLinePayload> lines;
  final List<PaymentPayload> payments;

  factory SalePayload.fromJson(Map<String, dynamic> json) => SalePayload(
        shiftId: json['shiftId'] == null ? null : json['shiftId'] as String,
        cashierId: json['cashierId'] as String,
        soldAt: json['soldAt'] as String,
        totalSantim: json['totalSantim'] as int,
        lines: (json['lines'] as List<dynamic>).map((e) => SaleLinePayload.fromJson(e as Map<String, dynamic>)).toList(),
        payments: (json['payments'] as List<dynamic>).map((e) => PaymentPayload.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'shiftId': shiftId,
        'cashierId': cashierId,
        'soldAt': soldAt,
        'totalSantim': totalSantim,
        'lines': lines.map((e) => e.toJson()).toList(),
        'payments': payments.map((e) => e.toJson()).toList(),
      };

  List<Object?> get _props => <Object?>[shiftId, cashierId, soldAt, totalSantim, lines, payments];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is SalePayload && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'SalePayload(${toJson()})';
}

class SaleLinePayload {
  const SaleLinePayload({
    required this.id,
    required this.productId,
    this.batchId,
    required this.qty,
    required this.unitPriceSantim,
    required this.lineTotalSantim,
  });

  final String id;
  final String productId;
  /// Client-generated UUIDv7 identifier
  final String? batchId;
  /// Integer quantity in the base unit
  final int qty;
  /// Money in santim (1 ETB = 100 santim)
  final int unitPriceSantim;
  /// Money in santim (1 ETB = 100 santim)
  final int lineTotalSantim;

  factory SaleLinePayload.fromJson(Map<String, dynamic> json) => SaleLinePayload(
        id: json['id'] as String,
        productId: json['productId'] as String,
        batchId: json['batchId'] == null ? null : json['batchId'] as String,
        qty: json['qty'] as int,
        unitPriceSantim: json['unitPriceSantim'] as int,
        lineTotalSantim: json['lineTotalSantim'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'productId': productId,
        'batchId': batchId,
        'qty': qty,
        'unitPriceSantim': unitPriceSantim,
        'lineTotalSantim': lineTotalSantim,
      };

  List<Object?> get _props => <Object?>[id, productId, batchId, qty, unitPriceSantim, lineTotalSantim];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is SaleLinePayload && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'SaleLinePayload(${toJson()})';
}

class PaymentPayload {
  const PaymentPayload({
    required this.id,
    required this.method,
    required this.amountSantim,
  });

  final String id;
  final String method;
  /// Money in santim (1 ETB = 100 santim)
  final int amountSantim;

  factory PaymentPayload.fromJson(Map<String, dynamic> json) => PaymentPayload(
        id: json['id'] as String,
        method: json['method'] as String,
        amountSantim: json['amountSantim'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'method': method,
        'amountSantim': amountSantim,
      };

  List<Object?> get _props => <Object?>[id, method, amountSantim];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is PaymentPayload && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'PaymentPayload(${toJson()})';
}

class OperationGoodsReceipt extends Operation {
  const OperationGoodsReceipt({
    required this.opId,
    required this.terminalId,
    required this.terminalSeq,
    required this.entityId,
    required this.opType,
    this.baseVersion,
    required this.tenantId,
    this.branchId,
    required this.actorId,
    required this.clientTs,
    required this.entityType,
    required this.payload,
  }) : super();

  final String opId;
  final String terminalId;
  final int terminalSeq;
  final String entityId;
  final String opType;
  final int? baseVersion;
  final String tenantId;
  final String? branchId;
  final String actorId;
  final String clientTs;
  final String entityType;
  final GoodsReceiptPayload payload;

  factory OperationGoodsReceipt.fromJson(Map<String, dynamic> json) => OperationGoodsReceipt(
        opId: json['opId'] as String,
        terminalId: json['terminalId'] as String,
        terminalSeq: json['terminalSeq'] as int,
        entityId: json['entityId'] as String,
        opType: json['opType'] as String,
        baseVersion: json['baseVersion'] == null ? null : json['baseVersion'] as int,
        tenantId: json['tenantId'] as String,
        branchId: json['branchId'] == null ? null : json['branchId'] as String,
        actorId: json['actorId'] as String,
        clientTs: json['clientTs'] as String,
        entityType: json['entityType'] as String,
        payload: GoodsReceiptPayload.fromJson(json['payload'] as Map<String, dynamic>),
      );

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'opId': opId,
        'terminalId': terminalId,
        'terminalSeq': terminalSeq,
        'entityId': entityId,
        'opType': opType,
        'baseVersion': baseVersion,
        'tenantId': tenantId,
        'branchId': branchId,
        'actorId': actorId,
        'clientTs': clientTs,
        'entityType': entityType,
        'payload': payload.toJson(),
      };

  List<Object?> get _props => <Object?>[opId, terminalId, terminalSeq, entityId, opType, baseVersion, tenantId, branchId, actorId, clientTs, entityType, payload];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is OperationGoodsReceipt && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'OperationGoodsReceipt(${toJson()})';
}

class GoodsReceiptPayload {
  const GoodsReceiptPayload({
    required this.supplierName,
    required this.receivedAt,
    required this.lines,
  });

  final String supplierName;
  final String receivedAt;
  final List<GoodsReceiptLinePayload> lines;

  factory GoodsReceiptPayload.fromJson(Map<String, dynamic> json) => GoodsReceiptPayload(
        supplierName: json['supplierName'] as String,
        receivedAt: json['receivedAt'] as String,
        lines: (json['lines'] as List<dynamic>).map((e) => GoodsReceiptLinePayload.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'supplierName': supplierName,
        'receivedAt': receivedAt,
        'lines': lines.map((e) => e.toJson()).toList(),
      };

  List<Object?> get _props => <Object?>[supplierName, receivedAt, lines];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is GoodsReceiptPayload && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'GoodsReceiptPayload(${toJson()})';
}

class GoodsReceiptLinePayload {
  const GoodsReceiptLinePayload({
    required this.id,
    required this.productId,
    required this.lotNo,
    required this.expiryDate,
    required this.qty,
    required this.costSantim,
  });

  final String id;
  final String productId;
  final String lotNo;
  final String expiryDate;
  /// Integer quantity in the base unit
  final int qty;
  /// Money in santim (1 ETB = 100 santim)
  final int costSantim;

  factory GoodsReceiptLinePayload.fromJson(Map<String, dynamic> json) => GoodsReceiptLinePayload(
        id: json['id'] as String,
        productId: json['productId'] as String,
        lotNo: json['lotNo'] as String,
        expiryDate: json['expiryDate'] as String,
        qty: json['qty'] as int,
        costSantim: json['costSantim'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'productId': productId,
        'lotNo': lotNo,
        'expiryDate': expiryDate,
        'qty': qty,
        'costSantim': costSantim,
      };

  List<Object?> get _props => <Object?>[id, productId, lotNo, expiryDate, qty, costSantim];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is GoodsReceiptLinePayload && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'GoodsReceiptLinePayload(${toJson()})';
}

class OperationShift extends Operation {
  const OperationShift({
    required this.opId,
    required this.terminalId,
    required this.terminalSeq,
    required this.entityId,
    required this.opType,
    this.baseVersion,
    required this.tenantId,
    this.branchId,
    required this.actorId,
    required this.clientTs,
    required this.entityType,
    required this.payload,
  }) : super();

  final String opId;
  final String terminalId;
  final int terminalSeq;
  final String entityId;
  final String opType;
  final int? baseVersion;
  final String tenantId;
  final String? branchId;
  final String actorId;
  final String clientTs;
  final String entityType;
  final ShiftPayload payload;

  factory OperationShift.fromJson(Map<String, dynamic> json) => OperationShift(
        opId: json['opId'] as String,
        terminalId: json['terminalId'] as String,
        terminalSeq: json['terminalSeq'] as int,
        entityId: json['entityId'] as String,
        opType: json['opType'] as String,
        baseVersion: json['baseVersion'] == null ? null : json['baseVersion'] as int,
        tenantId: json['tenantId'] as String,
        branchId: json['branchId'] == null ? null : json['branchId'] as String,
        actorId: json['actorId'] as String,
        clientTs: json['clientTs'] as String,
        entityType: json['entityType'] as String,
        payload: ShiftPayload.fromJson(json['payload'] as Map<String, dynamic>),
      );

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'opId': opId,
        'terminalId': terminalId,
        'terminalSeq': terminalSeq,
        'entityId': entityId,
        'opType': opType,
        'baseVersion': baseVersion,
        'tenantId': tenantId,
        'branchId': branchId,
        'actorId': actorId,
        'clientTs': clientTs,
        'entityType': entityType,
        'payload': payload.toJson(),
      };

  List<Object?> get _props => <Object?>[opId, terminalId, terminalSeq, entityId, opType, baseVersion, tenantId, branchId, actorId, clientTs, entityType, payload];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is OperationShift && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'OperationShift(${toJson()})';
}

class ShiftPayload {
  const ShiftPayload({
    required this.userId,
    required this.openedAt,
    this.closedAt,
    required this.openingFloatSantim,
  });

  final String userId;
  final String openedAt;
  /// UTC ISO-8601 timestamp
  final String? closedAt;
  /// Money in santim (1 ETB = 100 santim)
  final int openingFloatSantim;

  factory ShiftPayload.fromJson(Map<String, dynamic> json) => ShiftPayload(
        userId: json['userId'] as String,
        openedAt: json['openedAt'] as String,
        closedAt: json['closedAt'] == null ? null : json['closedAt'] as String,
        openingFloatSantim: json['openingFloatSantim'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userId': userId,
        'openedAt': openedAt,
        'closedAt': closedAt,
        'openingFloatSantim': openingFloatSantim,
      };

  List<Object?> get _props => <Object?>[userId, openedAt, closedAt, openingFloatSantim];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ShiftPayload && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'ShiftPayload(${toJson()})';
}

class OperationCashUp extends Operation {
  const OperationCashUp({
    required this.opId,
    required this.terminalId,
    required this.terminalSeq,
    required this.entityId,
    required this.opType,
    this.baseVersion,
    required this.tenantId,
    this.branchId,
    required this.actorId,
    required this.clientTs,
    required this.entityType,
    required this.payload,
  }) : super();

  final String opId;
  final String terminalId;
  final int terminalSeq;
  final String entityId;
  final String opType;
  final int? baseVersion;
  final String tenantId;
  final String? branchId;
  final String actorId;
  final String clientTs;
  final String entityType;
  final CashUpPayload payload;

  factory OperationCashUp.fromJson(Map<String, dynamic> json) => OperationCashUp(
        opId: json['opId'] as String,
        terminalId: json['terminalId'] as String,
        terminalSeq: json['terminalSeq'] as int,
        entityId: json['entityId'] as String,
        opType: json['opType'] as String,
        baseVersion: json['baseVersion'] == null ? null : json['baseVersion'] as int,
        tenantId: json['tenantId'] as String,
        branchId: json['branchId'] == null ? null : json['branchId'] as String,
        actorId: json['actorId'] as String,
        clientTs: json['clientTs'] as String,
        entityType: json['entityType'] as String,
        payload: CashUpPayload.fromJson(json['payload'] as Map<String, dynamic>),
      );

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'opId': opId,
        'terminalId': terminalId,
        'terminalSeq': terminalSeq,
        'entityId': entityId,
        'opType': opType,
        'baseVersion': baseVersion,
        'tenantId': tenantId,
        'branchId': branchId,
        'actorId': actorId,
        'clientTs': clientTs,
        'entityType': entityType,
        'payload': payload.toJson(),
      };

  List<Object?> get _props => <Object?>[opId, terminalId, terminalSeq, entityId, opType, baseVersion, tenantId, branchId, actorId, clientTs, entityType, payload];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is OperationCashUp && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'OperationCashUp(${toJson()})';
}

class CashUpPayload {
  const CashUpPayload({
    required this.shiftId,
    required this.userId,
    required this.countedAt,
    required this.expectedSantim,
    required this.countedSantim,
    required this.varianceSantim,
    this.note,
  });

  final String shiftId;
  final String userId;
  final String countedAt;
  /// Money in santim (1 ETB = 100 santim)
  final int expectedSantim;
  /// Money in santim (1 ETB = 100 santim)
  final int countedSantim;
  final int varianceSantim;
  final String? note;

  factory CashUpPayload.fromJson(Map<String, dynamic> json) => CashUpPayload(
        shiftId: json['shiftId'] as String,
        userId: json['userId'] as String,
        countedAt: json['countedAt'] as String,
        expectedSantim: json['expectedSantim'] as int,
        countedSantim: json['countedSantim'] as int,
        varianceSantim: json['varianceSantim'] as int,
        note: json['note'] == null ? null : json['note'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'shiftId': shiftId,
        'userId': userId,
        'countedAt': countedAt,
        'expectedSantim': expectedSantim,
        'countedSantim': countedSantim,
        'varianceSantim': varianceSantim,
        'note': note,
      };

  List<Object?> get _props => <Object?>[shiftId, userId, countedAt, expectedSantim, countedSantim, varianceSantim, note];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is CashUpPayload && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'CashUpPayload(${toJson()})';
}

class OperationStockAdjustment extends Operation {
  const OperationStockAdjustment({
    required this.opId,
    required this.terminalId,
    required this.terminalSeq,
    required this.entityId,
    required this.opType,
    this.baseVersion,
    required this.tenantId,
    this.branchId,
    required this.actorId,
    required this.clientTs,
    required this.entityType,
    required this.payload,
  }) : super();

  final String opId;
  final String terminalId;
  final int terminalSeq;
  final String entityId;
  final String opType;
  final int? baseVersion;
  final String tenantId;
  final String? branchId;
  final String actorId;
  final String clientTs;
  final String entityType;
  final StockAdjustmentPayload payload;

  factory OperationStockAdjustment.fromJson(Map<String, dynamic> json) => OperationStockAdjustment(
        opId: json['opId'] as String,
        terminalId: json['terminalId'] as String,
        terminalSeq: json['terminalSeq'] as int,
        entityId: json['entityId'] as String,
        opType: json['opType'] as String,
        baseVersion: json['baseVersion'] == null ? null : json['baseVersion'] as int,
        tenantId: json['tenantId'] as String,
        branchId: json['branchId'] == null ? null : json['branchId'] as String,
        actorId: json['actorId'] as String,
        clientTs: json['clientTs'] as String,
        entityType: json['entityType'] as String,
        payload: StockAdjustmentPayload.fromJson(json['payload'] as Map<String, dynamic>),
      );

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'opId': opId,
        'terminalId': terminalId,
        'terminalSeq': terminalSeq,
        'entityId': entityId,
        'opType': opType,
        'baseVersion': baseVersion,
        'tenantId': tenantId,
        'branchId': branchId,
        'actorId': actorId,
        'clientTs': clientTs,
        'entityType': entityType,
        'payload': payload.toJson(),
      };

  List<Object?> get _props => <Object?>[opId, terminalId, terminalSeq, entityId, opType, baseVersion, tenantId, branchId, actorId, clientTs, entityType, payload];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is OperationStockAdjustment && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'OperationStockAdjustment(${toJson()})';
}

class StockAdjustmentPayload {
  const StockAdjustmentPayload({
    required this.batchId,
    required this.productId,
    required this.delta,
    required this.reason,
    this.note,
    required this.countedAt,
    required this.previousQtyOnHand,
  });

  final String batchId;
  final String productId;
  final int delta;
  final String reason;
  final String? note;
  final String countedAt;
  final int previousQtyOnHand;

  factory StockAdjustmentPayload.fromJson(Map<String, dynamic> json) => StockAdjustmentPayload(
        batchId: json['batchId'] as String,
        productId: json['productId'] as String,
        delta: json['delta'] as int,
        reason: json['reason'] as String,
        note: json['note'] == null ? null : json['note'] as String,
        countedAt: json['countedAt'] as String,
        previousQtyOnHand: json['previousQtyOnHand'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'batchId': batchId,
        'productId': productId,
        'delta': delta,
        'reason': reason,
        'note': note,
        'countedAt': countedAt,
        'previousQtyOnHand': previousQtyOnHand,
      };

  List<Object?> get _props => <Object?>[batchId, productId, delta, reason, note, countedAt, previousQtyOnHand];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is StockAdjustmentPayload && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'StockAdjustmentPayload(${toJson()})';
}

class Ack {
  const Ack({
    required this.opId,
    required this.status,
    this.serverVersion,
    this.reason,
  });

  final String opId;
  final String status;
  final int? serverVersion;
  final String? reason;

  factory Ack.fromJson(Map<String, dynamic> json) => Ack(
        opId: json['opId'] as String,
        status: json['status'] as String,
        serverVersion: json['serverVersion'] == null ? null : json['serverVersion'] as int,
        reason: json['reason'] == null ? null : json['reason'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'opId': opId,
        'status': status,
        'serverVersion': serverVersion,
        'reason': reason,
      };

  List<Object?> get _props => <Object?>[opId, status, serverVersion, reason];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Ack && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'Ack(${toJson()})';
}

class PushRequest {
  const PushRequest({
    this.contractVersion,
    required this.terminalId,
    required this.operations,
  });

  final String? contractVersion;
  final String terminalId;
  final List<Operation> operations;

  factory PushRequest.fromJson(Map<String, dynamic> json) => PushRequest(
        contractVersion: json['contractVersion'] == null ? null : json['contractVersion'] as String,
        terminalId: json['terminalId'] as String,
        operations: (json['operations'] as List<dynamic>).map((e) => Operation.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'contractVersion': contractVersion,
        'terminalId': terminalId,
        'operations': operations.map((e) => e.toJson()).toList(),
      };

  List<Object?> get _props => <Object?>[contractVersion, terminalId, operations];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is PushRequest && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'PushRequest(${toJson()})';
}

class PushResponse {
  const PushResponse({
    required this.contractVersion,
    required this.acks,
    required this.changeSeq,
  });

  final String contractVersion;
  final List<Ack> acks;
  /// Server-assigned monotonic per-tenant change sequence
  final int changeSeq;

  factory PushResponse.fromJson(Map<String, dynamic> json) => PushResponse(
        contractVersion: json['contractVersion'] as String,
        acks: (json['acks'] as List<dynamic>).map((e) => Ack.fromJson(e as Map<String, dynamic>)).toList(),
        changeSeq: json['changeSeq'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'contractVersion': contractVersion,
        'acks': acks.map((e) => e.toJson()).toList(),
        'changeSeq': changeSeq,
      };

  List<Object?> get _props => <Object?>[contractVersion, acks, changeSeq];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is PushResponse && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'PushResponse(${toJson()})';
}

class PullResponse {
  const PullResponse({
    required this.contractVersion,
    required this.cursor,
    required this.hasMore,
    required this.products,
    required this.branches,
    required this.users,
    required this.stockBatches,
    required this.serverTime,
  });

  final String contractVersion;
  final int cursor;
  final bool hasMore;
  final List<ProductRef> products;
  final List<BranchRef> branches;
  final List<UserRef> users;
  final List<StockBatchRef> stockBatches;
  final String serverTime;

  factory PullResponse.fromJson(Map<String, dynamic> json) => PullResponse(
        contractVersion: json['contractVersion'] as String,
        cursor: json['cursor'] as int,
        hasMore: json['hasMore'] as bool,
        products: (json['products'] as List<dynamic>).map((e) => ProductRef.fromJson(e as Map<String, dynamic>)).toList(),
        branches: (json['branches'] as List<dynamic>).map((e) => BranchRef.fromJson(e as Map<String, dynamic>)).toList(),
        users: (json['users'] as List<dynamic>).map((e) => UserRef.fromJson(e as Map<String, dynamic>)).toList(),
        stockBatches: (json['stockBatches'] as List<dynamic>).map((e) => StockBatchRef.fromJson(e as Map<String, dynamic>)).toList(),
        serverTime: json['serverTime'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'contractVersion': contractVersion,
        'cursor': cursor,
        'hasMore': hasMore,
        'products': products.map((e) => e.toJson()).toList(),
        'branches': branches.map((e) => e.toJson()).toList(),
        'users': users.map((e) => e.toJson()).toList(),
        'stockBatches': stockBatches.map((e) => e.toJson()).toList(),
        'serverTime': serverTime,
      };

  List<Object?> get _props => <Object?>[contractVersion, cursor, hasMore, products, branches, users, stockBatches, serverTime];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is PullResponse && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'PullResponse(${toJson()})';
}

class ProductRef {
  const ProductRef({
    required this.id,
    required this.name,
    required this.unit,
    required this.isControlled,
    this.psychotropicClass,
    required this.currentPriceSantim,
    required this.changeSeq,
    this.deletedAt,
  });

  final String id;
  final String name;
  final String unit;
  final bool isControlled;
  final String? psychotropicClass;
  /// Money in santim (1 ETB = 100 santim)
  final int currentPriceSantim;
  final int changeSeq;
  /// UTC ISO-8601 timestamp
  final String? deletedAt;

  factory ProductRef.fromJson(Map<String, dynamic> json) => ProductRef(
        id: json['id'] as String,
        name: json['name'] as String,
        unit: json['unit'] as String,
        isControlled: json['isControlled'] as bool,
        psychotropicClass: json['psychotropicClass'] == null ? null : json['psychotropicClass'] as String,
        currentPriceSantim: json['currentPriceSantim'] as int,
        changeSeq: json['changeSeq'] as int,
        deletedAt: json['deletedAt'] == null ? null : json['deletedAt'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'unit': unit,
        'isControlled': isControlled,
        'psychotropicClass': psychotropicClass,
        'currentPriceSantim': currentPriceSantim,
        'changeSeq': changeSeq,
        'deletedAt': deletedAt,
      };

  List<Object?> get _props => <Object?>[id, name, unit, isControlled, psychotropicClass, currentPriceSantim, changeSeq, deletedAt];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ProductRef && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'ProductRef(${toJson()})';
}

class BranchRef {
  const BranchRef({
    required this.id,
    required this.name,
    this.address,
    required this.changeSeq,
    this.deletedAt,
  });

  final String id;
  final String name;
  final String? address;
  final int changeSeq;
  /// UTC ISO-8601 timestamp
  final String? deletedAt;

  factory BranchRef.fromJson(Map<String, dynamic> json) => BranchRef(
        id: json['id'] as String,
        name: json['name'] as String,
        address: json['address'] == null ? null : json['address'] as String,
        changeSeq: json['changeSeq'] as int,
        deletedAt: json['deletedAt'] == null ? null : json['deletedAt'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'address': address,
        'changeSeq': changeSeq,
        'deletedAt': deletedAt,
      };

  List<Object?> get _props => <Object?>[id, name, address, changeSeq, deletedAt];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is BranchRef && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'BranchRef(${toJson()})';
}

class UserRef {
  const UserRef({
    required this.id,
    required this.displayName,
    required this.role,
    required this.branchIds,
    required this.changeSeq,
    this.deletedAt,
  });

  final String id;
  final String displayName;
  final String role;
  final List<String> branchIds;
  final int changeSeq;
  /// UTC ISO-8601 timestamp
  final String? deletedAt;

  factory UserRef.fromJson(Map<String, dynamic> json) => UserRef(
        id: json['id'] as String,
        displayName: json['displayName'] as String,
        role: json['role'] as String,
        branchIds: (json['branchIds'] as List<dynamic>).map((e) => e as String).toList(),
        changeSeq: json['changeSeq'] as int,
        deletedAt: json['deletedAt'] == null ? null : json['deletedAt'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'displayName': displayName,
        'role': role,
        'branchIds': branchIds,
        'changeSeq': changeSeq,
        'deletedAt': deletedAt,
      };

  List<Object?> get _props => <Object?>[id, displayName, role, branchIds, changeSeq, deletedAt];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is UserRef && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'UserRef(${toJson()})';
}

class StockBatchRef {
  const StockBatchRef({
    required this.id,
    required this.branchId,
    required this.productId,
    required this.lotNo,
    required this.expiryDate,
    required this.qtyOnHand,
    required this.changeSeq,
    this.deletedAt,
  });

  final String id;
  final String branchId;
  final String productId;
  final String lotNo;
  /// ISO-8601 calendar date
  final String expiryDate;
  /// Integer quantity in the base unit
  final int qtyOnHand;
  final int changeSeq;
  /// UTC ISO-8601 timestamp
  final String? deletedAt;

  factory StockBatchRef.fromJson(Map<String, dynamic> json) => StockBatchRef(
        id: json['id'] as String,
        branchId: json['branchId'] as String,
        productId: json['productId'] as String,
        lotNo: json['lotNo'] as String,
        expiryDate: json['expiryDate'] as String,
        qtyOnHand: json['qtyOnHand'] as int,
        changeSeq: json['changeSeq'] as int,
        deletedAt: json['deletedAt'] == null ? null : json['deletedAt'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'branchId': branchId,
        'productId': productId,
        'lotNo': lotNo,
        'expiryDate': expiryDate,
        'qtyOnHand': qtyOnHand,
        'changeSeq': changeSeq,
        'deletedAt': deletedAt,
      };

  List<Object?> get _props => <Object?>[id, branchId, productId, lotNo, expiryDate, qtyOnHand, changeSeq, deletedAt];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is StockBatchRef && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'StockBatchRef(${toJson()})';
}

class LoginRequest {
  const LoginRequest({
    required this.tenantCode,
    required this.username,
    required this.secret,
    required this.terminalId,
  });

  final String tenantCode;
  final String username;
  final String secret;
  final String terminalId;

  factory LoginRequest.fromJson(Map<String, dynamic> json) => LoginRequest(
        tenantCode: json['tenantCode'] as String,
        username: json['username'] as String,
        secret: json['secret'] as String,
        terminalId: json['terminalId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tenantCode': tenantCode,
        'username': username,
        'secret': secret,
        'terminalId': terminalId,
      };

  List<Object?> get _props => <Object?>[tenantCode, username, secret, terminalId];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is LoginRequest && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'LoginRequest(${toJson()})';
}

class LoginResponse {
  const LoginResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scope,
    required this.offlineValidUntil,
  });

  final String accessToken;
  final String refreshToken;
  final String expiresAt;
  final AuthScope scope;
  final String offlineValidUntil;

  factory LoginResponse.fromJson(Map<String, dynamic> json) => LoginResponse(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        expiresAt: json['expiresAt'] as String,
        scope: AuthScope.fromJson(json['scope'] as Map<String, dynamic>),
        offlineValidUntil: json['offlineValidUntil'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt,
        'scope': scope.toJson(),
        'offlineValidUntil': offlineValidUntil,
      };

  List<Object?> get _props => <Object?>[accessToken, refreshToken, expiresAt, scope, offlineValidUntil];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is LoginResponse && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'LoginResponse(${toJson()})';
}

class AuthScope {
  const AuthScope({
    required this.userId,
    required this.tenantId,
    required this.role,
    required this.branchIds,
    required this.displayName,
  });

  final String userId;
  final String tenantId;
  final String role;
  final List<String> branchIds;
  final String displayName;

  factory AuthScope.fromJson(Map<String, dynamic> json) => AuthScope(
        userId: json['userId'] as String,
        tenantId: json['tenantId'] as String,
        role: json['role'] as String,
        branchIds: (json['branchIds'] as List<dynamic>).map((e) => e as String).toList(),
        displayName: json['displayName'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userId': userId,
        'tenantId': tenantId,
        'role': role,
        'branchIds': branchIds,
        'displayName': displayName,
      };

  List<Object?> get _props => <Object?>[userId, tenantId, role, branchIds, displayName];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is AuthScope && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'AuthScope(${toJson()})';
}

class RefreshRequest {
  const RefreshRequest({
    required this.refreshToken,
    required this.terminalId,
  });

  final String refreshToken;
  final String terminalId;

  factory RefreshRequest.fromJson(Map<String, dynamic> json) => RefreshRequest(
        refreshToken: json['refreshToken'] as String,
        terminalId: json['terminalId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'refreshToken': refreshToken,
        'terminalId': terminalId,
      };

  List<Object?> get _props => <Object?>[refreshToken, terminalId];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is RefreshRequest && _deepEquals(_props, other._props));

  @override
  int get hashCode => _deepHash(_props);

  @override
  String toString() => 'RefreshRequest(${toJson()})';
}
