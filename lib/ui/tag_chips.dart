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

/// Теги играющего трека: нажми — радио по тегу, ✎ — поправить теги исполнителя.
class TrackTags extends StatefulWidget {
  final Track track;
  const TrackTags({super.key, required this.track});

  @override
  State<TrackTags> createState() => _TrackTagsState();
}

class _TrackTagsState extends State<TrackTags> {
  late Future<Tags> _future = _load();

  Future<Tags> _load() => app.tags.trackTags(widget.track, artist: Recommendations.trueArtist(widget.track));

  @override
  void didUpdateWidget(TrackTags old) {
    super.didUpdateWidget(old);
    if (old.track.key != widget.track.key) _future = _load();
  }

  Future<void> _edit(List<String> current) async {
    final artist = Recommendations.trueArtist(widget.track).split(RegExp(r',|&| feat\.? | ft\.? ')).first.trim();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TagEditor(artist: artist, initial: current),
    );
    if (saved == true && mounted) {
      app.tags.invalidateProfile();
      app.recs.invalidate();
      setState(() => _future = _load());
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Tags>(
        future: _future,
        builder: (context, snap) {
          final all = TagService.top(snap.data ?? const {}, 8);
          final shown = all.where((x) => x != 'russian').take(5).toList();
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final x in shown) _Chip(x),
              ActionChip(
                avatar: const Icon(Icons.edit, size: 14),
                label: Text(shown.isEmpty ? 'добавить теги' : 'теги', style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: Colors.transparent,
                side: const BorderSide(color: AppColors.card),
                tooltip: 'Поправить теги исполнителя',
                onPressed: snap.connectionState == ConnectionState.done ? () => _edit(all) : null,
              ),
            ]),
          );
        },
      );
}

/// Свои теги исполнителя: убрать неверные, добавить свои. Главнее автоматических.
class _TagEditor extends StatefulWidget {
  final String artist;
  final List<String> initial;
  const _TagEditor({required this.artist, required this.initial});

  @override
  State<_TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<_TagEditor> {
  late final List<String> _tags = List.of(widget.initial);
  final _input = TextEditingController();

  void _add() {
    for (final raw in _input.text.split(RegExp(r'[,#\n]'))) {
      final t = raw.trim().toLowerCase();
      if (t.isNotEmpty && !_tags.contains(t)) _tags.add(t);
    }
    _input.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final custom = app.library.userTags.containsKey(app.library.artistKeyOf(widget.artist));
    return AlertDialog(
      title: Text('Теги: ${widget.artist}'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            custom
                ? 'Это твои теги. По ним работают радио и твой профиль вкуса.'
                : 'Теги собраны автоматически. Убери неверные и добавь свои — они заменят автоматические '
                    'для всех песен исполнителя.',
            style: const TextStyle(fontSize: 13, color: AppColors.textDim),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final t in _tags)
              InputChip(
                label: Text('#$t'),
                onDeleted: () => setState(() => _tags.remove(t)),
                visualDensity: VisualDensity.compact,
              ),
            if (_tags.isEmpty) const Text('Тегов нет', style: TextStyle(color: AppColors.textDim)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                decoration: const InputDecoration(
                    hintText: 'например: necrotrap, horrorcore', isDense: true, border: OutlineInputBorder()),
                onSubmitted: (_) => _add(),
              ),
            ),
            IconButton(icon: const Icon(Icons.add), onPressed: _add),
          ]),
        ]),
      ),
      actions: [
        if (custom)
          TextButton(
            onPressed: () {
              app.library.setUserTags(widget.artist, const []);
              app.tags.forget(widget.artist);
              Navigator.pop(context, true);
            },
            child: const Text('Вернуть автоматические'),
          ),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(
          onPressed: () {
            if (_input.text.trim().isNotEmpty) _add();
            app.library.setUserTags(widget.artist, _tags);
            Navigator.pop(context, true);
          },
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
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
