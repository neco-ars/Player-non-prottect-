import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import '../services/recommendations.dart';
import '../services/tags.dart';
import 'theme.dart';

/// Запустить радио по тегу и сказать, если не вышло.
Future<void> startTagRadio(BuildContext context, String tag) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text('Радио: #$tag — подбираю…'), duration: const Duration(seconds: 2)));
  await app.player.startTagRadio(tag);
  if (app.player.radioSeed?.kind != RadioKind.tag && app.player.error != null) {
    messenger.showSnackBar(SnackBar(content: Text(app.player.error!)));
  }
}

class _Chip extends StatelessWidget {
  final String tag;
  const _Chip(this.tag);
  @override
  Widget build(BuildContext context) => ActionChip(
        label: Text('#$tag', style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        backgroundColor: AppColors.card,
        side: BorderSide.none,
        tooltip: 'Радио по тегу',
        onPressed: () => startTagRadio(context, tag),
      );
}

/// Теги играющего трека: нажми — радио по этому тегу.
class TrackTags extends StatelessWidget {
  final Track track;
  const TrackTags({super.key, required this.track});

  @override
  Widget build(BuildContext context) => FutureBuilder<Tags>(
        key: ValueKey(track.key),
        future: app.tags.trackTags(track, artist: Recommendations.trueArtist(track)),
        builder: (context, snap) {
          final t = TagService.top(snap.data ?? const {}, 5).where((x) => x != 'russian').toList();
          if (t.isEmpty) return const SizedBox(height: 4);
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 4, children: [for (final x in t) _Chip(x)]),
          );
        },
      );
}

/// «Твои теги» на главной: из чего состоит твой вкус. Нажми — радио по тегу.
class YourTags extends StatelessWidget {
  const YourTags({super.key});

  @override
  Widget build(BuildContext context) => FutureBuilder<(Tags, Tags)>(
        future: app.tags.profile(app.library),
        builder: (context, snap) {
          final t = TagService.top(snap.data?.$1 ?? const {}, 10).where((x) => x != 'russian').toList();
          if (t.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Твои теги', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textDim)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [for (final x in t) _Chip(x)]),
            ]),
          );
        },
      );
}
