import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';

/// What the screen says back after a scan it was asked to handle.
class ScanFeedback {
  const ScanFeedback(this.message, {this.ok = true});
  final String message;

  /// False for "no product has this barcode" — shown in amber rather than green.
  final bool ok;
}

/// The phone's camera as a barcode scanner (FR-13, ADR-031).
///
/// Two ways in, for the two things a counter does with a scan:
///
///   - [once] returns the first code read — linking a barcode, or reading a delivery box;
///   - [many] stays open and hands each code to a callback — ringing up a basket, where
///     closing and reopening the camera per item would be slower than typing.
///
/// Everything a scan is matched against is already on the phone, so this works with no
/// network. The camera is only ever asked for here, when somebody taps scan.
abstract final class BarcodeScanner {
  /// For tests: the codes a pretend camera will read, in order. Non-null replaces the
  /// camera entirely — a widget test has none, and the screens' behaviour after a scan is
  /// what needs testing.
  static List<String>? debugScans;

  static Future<String?> once(BuildContext context, {required String title}) {
    final scripted = debugScans;
    if (scripted != null) {
      return Future.value(scripted.isEmpty ? null : scripted.removeAt(0));
    }
    return Navigator.of(context).push(MaterialPageRoute<String>(
        builder: (_) => ScanScreen(title: title), fullscreenDialog: true));
  }

  static Future<void> many(
    BuildContext context, {
    required String title,
    required Future<ScanFeedback> Function(String raw) onCode,
  }) async {
    final scripted = debugScans;
    if (scripted != null) {
      while (scripted.isNotEmpty) {
        await onCode(scripted.removeAt(0));
      }
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<String>(
        builder: (_) => ScanScreen(title: title, onCode: onCode),
        fullscreenDialog: true));
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.title, this.onCode});

  final String title;

  /// Null: close with the first code. Set: stay open and report each one.
  final Future<ScanFeedback> Function(String raw)? onCode;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  /// How long the same code is ignored after it was read. The camera sees one box thirty
  /// times a second; without this, holding it still for a moment rings it up six times.
  /// Scanning a second box of the same medicine takes longer than this to do by hand.
  static const _repeatAfter = Duration(milliseconds: 1800);

  final _controller = MobileScannerController(
    // The codes a medicine box carries. Naming them keeps the detector from spending
    // frames on formats that are never there, which matters on a low-end phone.
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.dataMatrix,
      BarcodeFormat.code128,
      BarcodeFormat.qrCode,
    ],
    detectionSpeed: DetectionSpeed.normal,
  );

  String? _lastCode;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  ScanFeedback? _feedback;
  bool _busy = false;
  bool _closed = false;
  int _count = 0;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  Future<void> _detected(BarcodeCapture capture) async {
    if (_busy || _closed) return;
    final raw = capture.barcodes.map((b) => b.rawValue).firstWhere(
        (v) => v != null && v.trim().isNotEmpty,
        orElse: () => null);
    if (raw == null) return;

    final now = DateTime.now();
    if (raw == _lastCode && now.difference(_lastAt) < _repeatAfter) return;
    _lastCode = raw;
    _lastAt = now;

    final onCode = widget.onCode;
    if (onCode == null) {
      _closed = true;
      Navigator.of(context).pop(raw);
      return;
    }

    _busy = true;
    try {
      final feedback = await onCode(raw);
      if (!mounted) return;
      setState(() {
        _feedback = feedback;
        if (feedback.ok) _count++;
      });
    } finally {
      _busy = false;
      // Counted from when handling finished, so a slow handler cannot let the same box
      // straight back in.
      _lastAt = DateTime.now();
    }
  }

  /// Reads a barcode out of a picture already on the phone (FR-13).
  ///
  /// The same detector, the same handling, a still image instead of the camera: for a
  /// box photographed earlier, a label a supplier sent — and it is how the scanner was
  /// proved on a real handset when there was no box to hold in front of it.
  Future<void> _fromPicture() async {
    final nothing = context.t('scan.noneInPicture');
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null || !mounted) return;
      final capture = await _controller.analyzeImage(picked.path);
      if (!mounted) return;
      if (capture == null || capture.barcodes.isEmpty) {
        setState(() => _feedback = ScanFeedback(nothing, ok: false));
        return;
      }
      // A second picture of the same code is a deliberate second read, not the camera
      // seeing one box thirty times a second.
      _lastCode = null;
      await _detected(capture);
    } catch (_) {
      if (mounted) setState(() => _feedback = ScanFeedback(nothing, ok: false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedback = _feedback;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(children: [
        PTopBar(
          tone: BarTone.green,
          title: widget.title,
          onBack: () => Navigator.of(context).pop(),
          trailing: [
            PIconButton(
              icon: Icons.image_outlined,
              tooltip: context.t('scan.fromPicture'),
              onTap: () => unawaited(_fromPicture()),
            ),
            PIconButton(
              icon: Icons.flashlight_on_outlined,
              tooltip: context.t('scan.torch'),
              onTap: () => unawaited(_controller.toggleTorch()),
            ),
          ],
        ),
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            MobileScanner(
              controller: _controller,
              onDetect: _detected,
              // No camera, or permission refused. Said plainly, with the way out: every
              // screen that offers a scan also still takes typing.
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(context.t('scan.noCamera'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15, height: 1.4)),
                ),
              ),
            ),
            // A frame to aim at. Decoration only: the whole picture is scanned, because a
            // cashier does not line a box up, they wave it.
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 250,
                  height: 170,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ]),
        ),
        Container(
          width: double.infinity,
          color: feedback == null
              ? PharmaColors.ink
              : feedback.ok
                  ? PharmaColors.green
                  : const Color(0xFF8A5A00),
          padding: EdgeInsets.fromLTRB(
              18, 14, 18, MediaQuery.of(context).padding.bottom + 14),
          child: Row(children: [
            Expanded(
              child: Text(
                feedback?.message ?? context.t('scan.hint'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600),
              ),
            ),
            if (widget.onCode != null)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                    _count == 0
                        ? context.t('scan.done')
                        : '${context.t('scan.done')} · $_count',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      ]),
    );
  }
}
