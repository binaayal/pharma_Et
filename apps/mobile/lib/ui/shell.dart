import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'home_screen.dart';
import 'reports_screen.dart';
import 'sell_screen.dart';
import 'settings_screen.dart';
import 'stock_screen.dart';
import 'terminal.dart';

/// The app's frame (prototype `.tabs`): Home · Sell · Stock · Reports · More.
///
/// Sell is not a tab page. In the prototype it is a full screen with its own green bar and
/// a back arrow — the counter wants the whole display for the cart — so the Sell tab
/// pushes it rather than switching to it.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

enum _Tab { home, stock, reports, more }

class _ShellState extends State<Shell> {
  _Tab _tab = _Tab.home;

  void _go(_Tab tab) {
    setState(() => _tab = tab);
    // A payment approved on the platform should show here without restarting the app.
    if (tab == _Tab.more) {
      unawaited(TerminalScope.read(context).loadSubscription());
    }
  }

  Future<void> _sell() => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const SellScreen()));

  @override
  Widget build(BuildContext context) {
    final terminal = TerminalScope.of(context);
    final showReports = terminal.canReadReports;
    if (_tab == _Tab.reports && !showReports) _tab = _Tab.home;

    return Scaffold(
      body: IndexedStack(
        index: _tab.index,
        children: [
          HomeScreen(
            onSell: _sell,
            onStock: () => _go(_Tab.stock),
            onReports: () => _go(_Tab.reports),
          ),
          const StockScreen(),
          showReports ? const ReportsScreen() : const SizedBox(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Color(0xEBFFFFFF),
          border: Border(top: BorderSide(color: Color(0xBFDDE5DE))),
          boxShadow: [
            BoxShadow(
                color: Color(0x0A14201B), blurRadius: 22, offset: Offset(0, -8))
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Row(
              children: [
                _TabItem(
                    icon: Icons.home_outlined,
                    label: context.t('tab.home'),
                    on: _tab == _Tab.home,
                    onTap: () => _go(_Tab.home)),
                _TabItem(
                    icon: Icons.add_circle_outline,
                    label: context.t('tab.sell'),
                    on: false,
                    onTap: () => _sell()),
                _TabItem(
                    icon: Icons.inventory_2_outlined,
                    label: context.t('tab.stock'),
                    on: _tab == _Tab.stock,
                    onTap: () => _go(_Tab.stock)),
                if (showReports)
                  _TabItem(
                      icon: Icons.bar_chart_rounded,
                      label: context.t('tab.reports'),
                      on: _tab == _Tab.reports,
                      onTap: () => _go(_Tab.reports)),
                _TabItem(
                    icon: Icons.menu_rounded,
                    label: context.t('tab.more'),
                    on: _tab == _Tab.more,
                    onTap: () => _go(_Tab.more)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem(
      {required this.icon,
      required this.label,
      required this.on,
      required this.onTap});
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = on ? PharmaColors.green : PharmaColors.faint;
    return Expanded(
      child: Semantics(
        selected: on,
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(height: 3),
                Text(label,
                    style: TextStyle(
                        fontSize: 10.5,
                        color: color,
                        fontWeight: on ? FontWeight.w800 : FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
