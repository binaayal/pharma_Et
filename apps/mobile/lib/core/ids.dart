import 'package:uuid/uuid.dart';

/// Client-generated UUIDv7 (ADR-006).
///
/// The terminal mints every identifier itself. That is what makes an offline write complete
/// the moment it is committed: the sale has its final id, its lines reference it, and the
/// receipt can be printed — none of which needs the server to have ever seen it.
///
/// v7 rather than v4 because it is time-ordered, so ids sort usefully in an index and a
/// day's sales cluster instead of scattering across the B-tree.
const _uuid = Uuid();

String newId() => _uuid.v7();
