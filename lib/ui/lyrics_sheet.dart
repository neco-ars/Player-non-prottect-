import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import '../services/lyrics.dart';
import 'position.dart';
import 'theme.dart';

/// Текст песни. Синхронный — подсвечивает текущую строку и прокручивается сам;
/// нажатие на строку перематывает трек на неё.
void showLyrics(BuildContext context, Track t) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF2A1A12),
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      minChildSize: 0.5,
      builder: (context, scroll) => _LyricsView(track: t, scroll: scroll),
    ),
  );
}

class _LyricsView extends StatefulWidget {
  final Track track;
  final ScrollController scroll;
  const _LyricsView({required this.track, required this.scroll});
  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  late final Future<Lyrics?> _future = app.lyrics.forTrack(widget.track);
  final _keys = <int, GlobalKey>{};
  int _active = -1;
  bool _follow = true; // пользователь сам листает — не мешаем

  void _onPosition(Duration pos, List<LyricLine> lines) {
    var i = -1;
    for (var k = 0; k < lines.length; k++) {
      if (lines[k].time <= pos + const Duration(milliseconds: 300)) {
        i = k;
      } else {
        break;
      }
    }
    if (i == _active) return;
    _active = i;
    if (_follow && i >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _keys[i]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx, alignment: 0.35, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    return Column(children: [
      const SizedBox(height: 8),
      Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(2))),
      ListTile(
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      Expanded(
        child: FutureBuilder<Lyrics?>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final l = snap.data;
            if (l == null || l.isEmpty) {
              return const _Center('Текст этой песни не найден.\n\nТексты берутся из открытой базы LRCLIB — '
                  'в ней есть не все песни, особенно редкие и свежие.');
            }
            if (l.instrumental && l.synced.isEmpty && (l.plain?.trim().isEmpty ?? true)) {
              return const _Center('Инструментал — без слов.');
            }
            if (l.synced.isEmpty) {
              return ListView(controller: widget.scroll, padding: const EdgeInsets.fromLTRB(24, 8, 24, 48), children: [
                Text(l.plain!, style: const TextStyle(fontSize: 20, height: 1.5, fontWeight: FontWeight.w600)),
              ]);
            }
            // синхронный текст работает только для текущего трека
            final isCurrent = app.player.current == t;
            return NotificationListener<UserScrollNotification>(
              onNotification: (_) {
                _follow = false; // листает сам
                return false;
              },
              child: PositionBuilder(
                player: app.player.player,
                period: const Duration(milliseconds: 250),
                builder: (context, pos, _) {
                  if (isCurrent) _onPosition(pos, l.synced);
                  return ListView.builder(
                    controller: widget.scroll,
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 160),
                    itemCount: l.synced.length,
                    itemBuilder: (context, i) {
                      final line = l.synced[i];
                      final active = isCurrent && i == _active;
                      final past = isCurrent && i < _active;
                      return InkWell(
                        key: _keys.putIfAbsent(i, GlobalKey.new),
                        onTap: isCurrent
                            ? () {
                                app.player.player.seek(line.time);
                                setState(() => _follow = true);
                              }
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: TextStyle(
                              fontSize: active ? 24 : 21,
                              height: 1.3,
                              fontWeight: FontWeight.w700,
                              color: active ? Colors.white : (past ? Colors.white54 : Colors.white38),
                            ),
                            child: Text(line.text.isEmpty ? '♪' : line.text),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            );
          },
        ),
      ),
      if (!_follow)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FilledButton.tonalIcon(
            icon: const Icon(Icons.my_location),
            label: const Text('К текущей строке'),
            onPressed: () => setState(() {
              _follow = true;
              _active = -1; // пересчитается и прокрутит
            }),
          ),
        ),
    ]);
  }
}

class _Center extends StatelessWidget {
  final String text;
  const _Center(this.text);
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim)),
        ),
      );
}
