import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import 'theme.dart';
import 'widgets.dart';

/// Ряд кнопок «Все · Яндекс · Звук · SoundCloud · …» — показать только одну площадку.
/// [value] == null — все площадки. Показываются только подключённые площадки.
class SourceFilterBar extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;

  /// Какие площадки предлагать (по умолчанию — все подключённые).
  final Iterable<String>? only;
  const SourceFilterBar({super.key, required this.value, required this.onChanged, this.only});

  @override
  Widget build(BuildContext context) {
    final ids = only?.toList() ?? [for (final s in app.search.sources) if (s.isConfigured) s.id];
    if (ids.length < 2) return const SizedBox.shrink(); // выбирать не из чего
    Widget chip(String? id, String label, Color? dot) {
      final selected = value == id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          avatar: dot == null ? null : CircleAvatar(radius: 5, backgroundColor: dot),
          label: Text(label),
          selected: selected,
          showCheckmark: false,
          onSelected: (_) => onChanged(id),
          selectedColor: AppColors.text,
          labelStyle: TextStyle(color: selected ? Colors.black : AppColors.text, fontWeight: FontWeight.w600, fontSize: 13),
          backgroundColor: AppColors.card,
          side: BorderSide.none,
          shape: const StadiumBorder(),
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          chip(null, 'Все', null),
          for (final id in ids) chip(id, sourceNames[id] ?? id, sourceColors[id]),
        ],
      ),
    );
  }
}

/// Оставить в группах версий только треки одной площадки (пустые группы убираются).
List<TrackGroup> filterGroups(List<TrackGroup> groups, String? source) => source == null
    ? groups
    : [
        for (final g in groups)
          if (g.variants.any((v) => v.source == source)) TrackGroup(g.variants.where((v) => v.source == source).toList())
      ];
