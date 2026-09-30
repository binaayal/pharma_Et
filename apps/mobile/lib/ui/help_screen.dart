import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../l10n/help_content.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';

/// Help & user guide (FR-10): every task in the app, step by step, in Amharic and English.
///
/// Reachable from the sign-in screen as well as from More, because the person most likely
/// to need it is the one who cannot get past sign-in. It needs no session, no network and
/// no terminal — it reads only [L10n] — and it carries its own language switch, so someone
/// who cannot read the current language can still change it from here.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, this.initialTopic});

  /// A topic to open on arrival — `payment` from the subscription screens.
  final String? initialTopic;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  static const _icons = <String, IconData>{
    'rocket': Icons.rocket_launch_outlined,
    'lock': Icons.lock_outline,
    'cart': Icons.shopping_cart_outlined,
    'inventory': Icons.inventory_2_outlined,
    'checklist': Icons.checklist_rtl,
    'event': Icons.event_outlined,
    'payments': Icons.payments_outlined,
    'chart': Icons.bar_chart_rounded,
    'people': Icons.people_outline,
    'medication': Icons.medication_outlined,
    'sync': Icons.sync,
    'wallet': Icons.account_balance_wallet_outlined,
    'translate': Icons.translate,
    'help': Icons.help_outline,
  };

  /// Matches the title, the summary, every step and the tip, case-insensitively — an owner
  /// types what they are trying to do ("price", "ዋጋ"), not the name of the topic.
  bool _matches(HelpTopic topic, String q) {
    if (q.isEmpty) return true;
    final haystack = [
      topic.title,
      topic.summary,
      ...topic.steps,
      topic.tip ?? ''
    ].join('\n').toLowerCase();
    return haystack.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final guide = HelpGuide.of(l10n.strings.locale);
    final q = _query.text.trim().toLowerCase();
    final topics = guide.topics.where((t) => _matches(t, q)).toList();

    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: guide.title,
          onBack: Navigator.of(context).canPop()
              ? () => Navigator.of(context).pop()
              : null,
        ),
        Expanded(
          child: PBody(children: [
            PSegmented<String>(
              options: const [('en', 'English'), ('am', 'አማርኛ')],
              value: l10n.strings.locale,
              onChanged: l10n.onChange,
            ),
            PNotice.text(Tone.blue, Icons.menu_book_outlined, guide.intro),
            TextField(
              controller: _query,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: guide.searchHint,
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: PharmaColors.card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: PharmaColors.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: PharmaColors.line),
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (topics.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(guide.noMatch,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: PharmaColors.muted)),
              ),
            for (final topic in topics)
              _TopicCard(
                // Keyed by locale too, so switching language re-reads the expansion state
                // from `initiallyExpanded` rather than keeping a stale tile.
                key: ValueKey('${l10n.strings.locale}-${topic.id}'),
                topic: topic,
                icon: _icons[topic.icon] ?? Icons.help_outline,
                expanded: topic.id == widget.initialTopic || q.isNotEmpty,
              ),
            const SizedBox(height: 6),
            PNotice(
              tone: Tone.green,
              icon: Icons.support_agent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(guide.contactTitle,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  SelectableText(guide.contactBody),
                ],
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _TopicCard extends StatelessWidget {
  const _TopicCard({
    super.key,
    required this.topic,
    required this.icon,
    required this.expanded,
  });

  final HelpTopic topic;
  final IconData icon;
  final bool expanded;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: cardShadow,
        ),
        child: Material(
          color: PharmaColors.card,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Theme(
            // ExpansionTile draws dividers above and below itself when open; inside a card
            // they read as stray lines.
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: expanded,
              tilePadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              leading: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: PharmaColors.greenTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: PharmaColors.greenDark),
              ),
              title: Text(topic.title,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700)),
              subtitle: Text(topic.summary,
                  style: const TextStyle(
                      fontSize: 12.5, color: PharmaColors.muted)),
              children: [
                for (var i = 0; i < topic.steps.length; i++)
                  _Step(number: i + 1, text: topic.steps[i]),
                if (topic.tip != null)
                  PNotice.text(Tone.amber, Icons.lightbulb_outline, topic.tip!,
                      margin: const EdgeInsets.only(top: 6)),
              ],
            ),
          ),
        ),
      );
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              margin: const EdgeInsets.only(right: 10, top: 1),
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: PharmaColors.green,
                shape: BoxShape.circle,
              ),
              child: Text('$number',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ),
            Expanded(
              child: SelectableText(text,
                  style: const TextStyle(fontSize: 13.5, height: 1.5)),
            ),
          ],
        ),
      );
}
