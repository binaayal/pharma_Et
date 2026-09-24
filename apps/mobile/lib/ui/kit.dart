import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';

/// The prototype's components (docs/prototype/index.html), one widget per CSS class, so a
/// screen reads like the markup it was designed from: `.topbar`, `.tile`, `.rows`/`.row`,
/// `.badge`, `.btn`, `.fld`, `.notice`, `.lang`, `.summary`, `.tabs`.

// ------------------------------------------------------------------------ .topbar

enum BarTone { plain, green, red }

/// `.topbar` (plain), `.topbar.g` (green) and `.topbar.r` (red).
class PTopBar extends StatelessWidget implements PreferredSizeWidget {
  const PTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.tone = BarTone.plain,
    this.onBack,
    this.trailing = const [],
  });

  final String title;
  final String? subtitle;
  final BarTone tone;
  final VoidCallback? onBack;
  final List<Widget> trailing;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final coloured = tone != BarTone.plain;
    final fg = coloured ? Colors.white : PharmaColors.ink;
    final bg = switch (tone) {
      BarTone.green => PharmaColors.green,
      BarTone.red => PharmaColors.red,
      BarTone.plain => Colors.transparent,
    };
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Light icons over the green and red bars, as the prototype's status bar reads.
      value: coloured
          ? SystemUiOverlayStyle.light.copyWith(statusBarColor: bg)
          : SystemUiOverlayStyle.dark
              .copyWith(statusBarColor: Colors.transparent),
      child: Material(
        color: bg,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  if (onBack != null) ...[
                    Semantics(
                      label: 'Back',
                      button: true,
                      child: InkWell(
                        onTap: onBack,
                        borderRadius: BorderRadius.circular(9),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: coloured
                                ? Colors.white.withValues(alpha: 0.16)
                                : Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Icon(Icons.chevron_left, color: fg, size: 22),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: fg,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3)),
                        if (subtitle != null)
                          Text(subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: coloured
                                      ? Colors.white.withValues(alpha: 0.85)
                                      : PharmaColors.muted,
                                  fontSize: 12)),
                      ],
                    ),
                  ),
                  for (final t in trailing) ...[const SizedBox(width: 8), t],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.icon-btn`.
class PIconButton extends StatelessWidget {
  const PIconButton(
      {super.key, required this.icon, required this.tooltip, this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.045),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 19, color: PharmaColors.ink),
          ),
        ),
      );
}

// ------------------------------------------------------------------------- .body

/// `.body` — the padded scroll area under a top bar.
class PBody extends StatelessWidget {
  const PBody({super.key, required this.children, this.padding});
  final List<Widget> children;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => ListView(
        padding: padding ?? const EdgeInsets.fromLTRB(18, 8, 18, 20),
        children: children,
      );
}

/// `.sec` — the small uppercase section label.
class PSection extends StatelessWidget {
  const PSection(this.text, {super.key, this.first = false});
  final String text;
  final bool first;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(2, first ? 6 : 20, 2, 10),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            color: PharmaColors.faint,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.55,
          ),
        ),
      );
}

/// The action area pinned under a screen's content (`.body` with `flex:none`).
class PFooter extends StatelessWidget {
  const PFooter({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
          child: child,
        ),
      );
}

// ------------------------------------------------------------------------ .tiles

/// `.tile` and `.tile.hero`.
class PTile extends StatelessWidget {
  const PTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.delta,
    this.hero = false,
    this.valueColor,
    this.onTap,
  });

  final String label;
  final String value;
  final String? unit;
  final String? delta;
  final bool hero;
  final Color? valueColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = hero ? Colors.white : (valueColor ?? PharmaColors.ink);
    final sub = hero ? const Color(0xFFBFE0D5) : PharmaColors.muted;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: hero ? null : PharmaColors.card,
          gradient: hero
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [PharmaColors.heroFrom, PharmaColors.heroTo])
              : null,
          borderRadius: BorderRadius.circular(16),
          boxShadow: hero
              ? const [
                  BoxShadow(
                      color: Color(0x380D3B2B),
                      blurRadius: 30,
                      offset: Offset(0, 12))
                ]
              : cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: sub)),
            const SizedBox(height: 5),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: value,
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.7,
                          color: fg,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                  if (unit != null)
                    TextSpan(
                        text: ' $unit',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: sub)),
                ]),
              ),
            ),
            if (delta != null) ...[
              const SizedBox(height: 6),
              Text(delta!,
                  style: TextStyle(
                      fontSize: 11.5,
                      color:
                          hero ? const Color(0xFFCDEBDF) : PharmaColors.green)),
            ],
          ],
        ),
      ),
    );
  }
}

/// `.tiles` — two columns; a hero tile spans both.
class PTiles extends StatelessWidget {
  const PTiles({super.key, this.hero, this.tiles = const []});
  final Widget? hero;
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (hero != null) rows.add(hero!);
    for (var i = 0; i < tiles.length; i += 2) {
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: tiles[i]),
          const SizedBox(width: 11),
          Expanded(
              child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox()),
        ],
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 11),
          rows[i],
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------ .rows / .row

enum Tone { green, amber, red, blue, grey }

Color toneFg(Tone tone) => switch (tone) {
      Tone.green => PharmaColors.greenDark,
      Tone.amber => PharmaColors.amber,
      Tone.red => PharmaColors.red,
      Tone.blue => PharmaColors.blue,
      Tone.grey => PharmaColors.muted,
    };

Color toneBg(Tone tone) => switch (tone) {
      Tone.green => PharmaColors.greenTint,
      Tone.amber => PharmaColors.amberTint,
      Tone.red => PharmaColors.redTint,
      Tone.blue => PharmaColors.blueTint,
      Tone.grey => const Color(0xFFEEF1F0),
    };

/// `.rows` — a white rounded card holding `.row`s separated by hairlines.
class PRows extends StatelessWidget {
  const PRows({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: cardShadow,
        ),
        // Its own Material, so a row's tap ripple paints on the card rather than under it.
        child: Material(
          color: PharmaColors.card,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  const Divider(
                      height: 1, thickness: 1, color: PharmaColors.rowLine),
                children[i],
              ],
            ],
          ),
        ),
      );
}

/// `.row` — avatar, title and subtitle, and a right-hand value or chevron.
class PRow extends StatelessWidget {
  const PRow({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.avatar,
    this.avatarIcon,
    this.avatarTone = Tone.green,
    this.value,
    this.valueCaption,
    this.valueColor,
    this.trailing,
    this.chevron = false,
    this.titleColor,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;
  final String? avatar;

  /// An icon in the avatar square instead of a letter or count.
  final IconData? avatarIcon;
  final Tone avatarTone;
  final String? value;
  final String? valueCaption;
  final Color? valueColor;
  final Widget? trailing;
  final bool chevron;
  final Color? titleColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              if (avatar != null || avatarIcon != null) ...[
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: toneBg(avatarTone),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: avatarIcon != null
                      ? Icon(avatarIcon, size: 20, color: toneFg(avatarTone))
                      : Text(avatar!,
                          style: TextStyle(
                              color: toneFg(avatarTone),
                              fontWeight: FontWeight.w700,
                              fontSize: 14)),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.1,
                            color: titleColor ?? PharmaColors.ink)),
                    if (subtitleWidget != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: subtitleWidget!)
                    else if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(subtitle!,
                            style: const TextStyle(
                                fontSize: 12.5, color: PharmaColors.muted)),
                      ),
                  ],
                ),
              ),
              if (value != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(value!,
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: valueColor ?? PharmaColors.ink,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                    if (valueCaption != null)
                      Text(valueCaption!,
                          style: const TextStyle(
                              fontSize: 11.5, color: PharmaColors.faint)),
                  ],
                ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              if (chevron)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.chevron_right,
                      size: 20, color: PharmaColors.faint),
                ),
            ],
          ),
        ),
      );
}

/// `.badge`.
class PBadge extends StatelessWidget {
  const PBadge(this.text, {super.key, this.tone = Tone.grey});
  final String text;
  final Tone tone;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: toneBg(tone),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
                color: toneFg(tone))),
      );
}

// ------------------------------------------------------------------------- .btn

enum BtnKind { primary, green, plain, warn }

/// `.btn.p` (amber — the main action), `.btn.g`, `.btn.d` (white) and `.btn.warn`.
class PButton extends StatelessWidget {
  const PButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = BtnKind.primary,
    this.small = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final bool small;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final (List<Color>? gradient, Color fg, Color shadow) = switch (kind) {
      BtnKind.primary => (
          [PharmaColors.ctaFrom, PharmaColors.ctaTo],
          PharmaColors.ctaInk,
          const Color(0x38C98A2C)
        ),
      BtnKind.green => (
          [PharmaColors.heroFrom, PharmaColors.heroTo],
          Colors.white,
          const Color(0x2E0D3B2B)
        ),
      BtnKind.warn => (
          [PharmaColors.warnFrom, PharmaColors.warnTo],
          Colors.white,
          const Color(0x38B4322A)
        ),
      BtnKind.plain => (null, PharmaColors.ink, const Color(0x0F0D3B2B)),
    };
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(13),
            child: Ink(
              decoration: BoxDecoration(
                color: gradient == null ? Colors.white : null,
                gradient: gradient == null
                    ? null
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradient),
                borderRadius: BorderRadius.circular(13),
                boxShadow: [
                  BoxShadow(
                      color: shadow, blurRadius: 18, offset: const Offset(0, 7))
                ],
              ),
              child: Container(
                alignment: Alignment.center,
                padding: EdgeInsets.symmetric(
                    vertical: small ? 11 : 15, horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: fg),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: fg,
                              fontSize: small ? 13.5 : 15.5,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.btn-row` — two buttons side by side.
class PButtonRow extends StatelessWidget {
  const PButtonRow({super.key, required this.left, required this.right});
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: left),
        const SizedBox(width: 10),
        Expanded(child: right),
      ]);
}

// ------------------------------------------------------------------------- .fld

/// `.fld` — an uppercase label over a white, shadowed input.
class PField extends StatelessWidget {
  const PField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.helper,
    this.keyboardType,
    this.obscure = false,
    this.large = false,
    this.maxLines = 1,
    this.onChanged,
    this.suffix,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
    this.enabled = true,
    this.child,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? helper;
  final TextInputType? keyboardType;
  final bool obscure;
  final bool large;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final Widget? suffix;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;

  /// Replaces the text input (a segmented control, a dropdown, an upload box).
  final Widget? child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(),
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: PharmaColors.muted,
                    letterSpacing: 0.5)),
            const SizedBox(height: 6),
            child ??
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x0D0D3B2B),
                          blurRadius: 12,
                          offset: Offset(0, 3))
                    ],
                  ),
                  child: TextField(
                    controller: controller,
                    enabled: enabled,
                    keyboardType: keyboardType,
                    obscureText: obscure,
                    maxLines: maxLines,
                    autofocus: autofocus,
                    onChanged: onChanged,
                    onSubmitted: onSubmitted,
                    textInputAction: textInputAction,
                    style: TextStyle(
                        fontSize: large ? 22 : 15,
                        fontWeight: large ? FontWeight.w700 : FontWeight.w400),
                    decoration: InputDecoration(
                      hintText: hint,
                      suffixIcon: suffix,
                      semanticCounterText: label,
                    ),
                  ),
                ),
            if (helper != null) ...[
              const SizedBox(height: 6),
              Text(helper!,
                  style: const TextStyle(
                      fontSize: 11.5, color: PharmaColors.faint)),
            ],
          ],
        ),
      );
}

// ----------------------------------------------------------------------- .notice

/// `.notice` in amber, red, green or blue.
class PNotice extends StatelessWidget {
  const PNotice({
    super.key,
    required this.tone,
    required this.icon,
    required this.child,
    this.margin = const EdgeInsets.only(bottom: 14),
  });

  final Tone tone;
  final IconData icon;
  final Widget child;
  final EdgeInsets margin;

  factory PNotice.text(Tone tone, IconData icon, String text,
          {Key? key, EdgeInsets margin = const EdgeInsets.only(bottom: 14)}) =>
      PNotice(
          key: key, tone: tone, icon: icon, margin: margin, child: Text(text));

  @override
  Widget build(BuildContext context) {
    final fg = tone == Tone.amber ? PharmaColors.amberInk : toneFg(tone);
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: toneBg(tone),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: DefaultTextStyle.merge(
              style: TextStyle(color: fg, fontSize: 13, height: 1.45),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------------- .lang

/// `.lang` — the segmented control used for language, filters and payment method.
class PSegmented<T> extends StatelessWidget {
  const PSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: PharmaColors.segment,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            for (final (key, label) in options)
              Expanded(
                child: Semantics(
                  selected: key == value,
                  button: true,
                  child: GestureDetector(
                    onTap: () => onChanged(key),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: pharmaEase,
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: key == value ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                        boxShadow: key == value
                            ? const [
                                BoxShadow(
                                    color: Color(0x1A0D3B2B),
                                    blurRadius: 7,
                                    offset: Offset(0, 2))
                              ]
                            : null,
                      ),
                      child: Text(label,
                          style: TextStyle(
                              fontSize: 13.5,
                              color: key == value
                                  ? PharmaColors.ink
                                  : PharmaColors.muted,
                              fontWeight: key == value
                                  ? FontWeight.w600
                                  : FontWeight.w400)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

// ---------------------------------------------------------------------- .summary

/// `.summary` — a card of `.sl` lines, the last optionally a dashed-rule total.
class PSummary extends StatelessWidget {
  const PSummary(
      {super.key, required this.lines, this.total, this.margin = true});
  final List<(String, String)> lines;
  final (String, String)? total;
  final bool margin;

  @override
  Widget build(BuildContext context) => Container(
        margin: EdgeInsets.only(top: margin ? 14 : 0),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: PharmaColors.card,
          borderRadius: BorderRadius.circular(16),
          boxShadow: cardShadow,
        ),
        child: Column(
          children: [
            for (final (k, v) in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Expanded(
                      child: Text(k,
                          style: const TextStyle(
                              fontSize: 13.5, color: PharmaColors.muted))),
                  Text(v,
                      style: const TextStyle(
                          fontSize: 13.5,
                          color: PharmaColors.muted,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ]),
              ),
            if (total != null) ...[
              if (lines.isNotEmpty) ...[
                const SizedBox(height: 6),
                const _Dashed(),
                const SizedBox(height: 11),
              ],
              Row(children: [
                Expanded(
                    child: Text(total!.$1,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800))),
                Text(total!.$2,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ]),
            ],
          ],
        ),
      );
}

class _Dashed extends StatelessWidget {
  const _Dashed();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final n = (box.maxWidth / 7).floor();
          return Row(
            children: List.generate(
              n,
              (_) => Container(
                width: 4,
                height: 1,
                margin: const EdgeInsets.only(right: 3),
                color: PharmaColors.line,
              ),
            ),
          );
        },
      );
}

// ------------------------------------------------------------------ .sync chip

/// The sync-state chip — "the signature element, always visible on mobile".
///
/// `on` is green with a green dot; `off` is amber with a haloed dot. The words say what the
/// state means to a cashier, never "error": offline is the expected, supported state.
class PSyncDot extends StatelessWidget {
  const PSyncDot(
      {super.key, required this.label, required this.on, this.onTap});
  final String label;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = on ? PharmaColors.greenDark : PharmaColors.amber;
    return Semantics(
      label: label,
      button: onTap != null,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: on ? PharmaColors.greenTint : PharmaColors.amberTint,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: on ? PharmaColors.green : PharmaColors.amber,
                shape: BoxShape.circle,
                boxShadow: on
                    ? null
                    : const [
                        BoxShadow(color: Color(0x26B26A12), spreadRadius: 3)
                      ],
              ),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ .ok-circle

/// `.ok-circle` / `.lock-circle` — the rounded-square status mark.
class PMark extends StatelessWidget {
  const PMark(
      {super.key, required this.icon, this.size = 60, this.warn = false});
  final IconData icon;
  final double size;
  final bool warn;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: warn
                ? const [PharmaColors.warnFrom, Color(0xFF9E281F)]
                : const [PharmaColors.heroFrom, PharmaColors.heroTo],
          ),
          borderRadius: BorderRadius.circular(size / 3),
          boxShadow: [
            BoxShadow(
                color: warn ? const Color(0x47B4322A) : const Color(0x380D3B2B),
                blurRadius: 26,
                offset: const Offset(0, 10))
          ],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.45),
      );
}

/// The ℞ brand mark from the login screen (`.pin-logo`).
class PLogo extends StatelessWidget {
  const PLogo({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 68,
        height: 68,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [PharmaColors.heroFrom, PharmaColors.heroTo]),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
                color: Color(0x330D3B2B), blurRadius: 26, offset: Offset(0, 12))
          ],
        ),
        child: const Text('℞',
            style: TextStyle(
                color: PharmaColors.gold,
                fontSize: 34,
                fontWeight: FontWeight.w800)),
      );
}

/// Shows a floating message in the brand's dark green.
void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
