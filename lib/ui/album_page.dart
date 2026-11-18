import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../sources/source.dart';
import 'nav.dart';
import 'theme.dart';
import 'track_menu.dart';
import 'widgets.dart';

/// Альбом: обложка, исполнитель (переход на его страницу), треки по порядку.
class AlbumPage extends StatefulWidget {
  final Future<AlbumInfo?> Function() load;
  final String? title;
  final AlbumRef? preview; // что показать, пока альбом грузится
  /// Текст, если альбом не нашёлся; считается после загрузки (там отчёт по площадкам).
  final String Function() notFound;
  const AlbumPage({
    super.key,
    required this.load,
    this.title,
    this.preview,
    this.notFound = _defaultNotFound,
  });

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

String _defaultNotFound() => 'Альбом не найден.';

class _AlbumPageState extends State<AlbumPage> {
  late Future<AlbumInfo?> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<AlbumInfo?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _Loading(title: widget.title, cover: widget.preview?.coverUrl);
          }
          final album = snap.data;
          if (album == null) {
            return _Message(
              title: widget.title,
              text: snap.hasError ? 'Не удалось загрузить альбом: ${snap.error}' : widget.notFound(),
              onRetry: () => setState(() => _future = widget.load()),
            );
          }
          return ListenableBuilder(listenable: app.player, builder: (context, _) => _content(album));
        },
      ),
    );
  }

  Widget _content(AlbumInfo album) {
    final ref = album.ref;
    final tracks = album.tracks;
    final playingHere = tracks.contains(app.player.current);
    final total = tracks.fold<Duration>(Duration.zero, (s, t) => s + (t.duration ?? Duration.zero));
    final meta = [
      ref.typeLabel,
      if (ref.year != null) '${ref.year}',
      '${tracks.length} тр.',
      if (total.inMinutes > 0) '${total.inMinutes} мин',
    ].join(' · ');

    return CustomScrollView(slivers: [
      SliverAppBar(
        pinned: true,
        expandedHeight: 320,
        backgroundColor: AppColors.bg,
        title: Text(ref.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        flexibleSpace: FlexibleSpaceBar(
          background: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF3A3A3A), AppColors.bg],
              ),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 56, bottom: 16),
                child: Container(
                  decoration: const BoxDecoration(
                    boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 10))],
                  ),
                  child: Cover(ref.coverUrl, size: 220, radius: 4, placeholderIcon: Icons.album),
                ),
              ),
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ref.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            // исполнитель — переход на его страницу
            InkWell(
              onTap: () => album.artist != null
                  ? openArtist(context, album.artist!)
                  : (tracks.isNotEmpty ? openArtistOf(context, tracks.first) : null),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.person, size: 18, color: AppColors.textDim),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(album.artist?.name ?? ref.artist,
                        style: const TextStyle(fontWeight: FontWeight.w600, decoration: TextDecoration.underline)),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 4),
            Row(children: [
              if (ref.explicit) const ExplicitBadge(),
              SourceDot(ref.source),
              Expanded(child: Text(meta, style: const TextStyle(color: AppColors.textDim, fontSize: 13))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              IconButton(
                tooltip: 'Вперемешку',
                icon: const Icon(Icons.shuffle, color: AppColors.textDim, size: 28),
                onPressed: tracks.isEmpty ? null : () => app.player.playQueue(tracks, 0, shuffled: true),
              ),
              const Spacer(),
              PlayButton(
                size: 56,
                playing: playingHere && app.player.player.playing,
                onPressed: () {
                  if (tracks.isEmpty) return;
                  if (playingHere) {
                    app.player.player.playing ? app.player.player.pause() : app.player.player.play();
                  } else {
                    app.player.playQueue(tracks, 0);
                  }
                },
              ),
            ]),
          ]),
        ),
      ),
      SliverList.builder(
        itemCount: tracks.length,
        itemBuilder: (context, i) => TrackTile(
          track: tracks[i],
          number: i + 1,
          playing: app.player.current == tracks[i],
          onTap: () => app.player.playQueue(tracks, i),
          onMenu: () => showTrackMenu(context, tracks[i]),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]);
  }
}

class _Loading extends StatelessWidget {
  final String? title;
  final String? cover;
  const _Loading({this.title, this.cover});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (cover != null) ...[Cover(cover, size: 160), const SizedBox(height: 24)],
            const CircularProgressIndicator(),
          ]),
        ),
      );
}

class _Message extends StatelessWidget {
  final String? title;
  final String text;
  final VoidCallback onRetry;
  const _Message({this.title, required this.text, required this.onRetry});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('Повторить')),
            ]),
          ),
        ),
      );
}

/// Для страницы исполнителя — те же заглушки.
Widget loadingScaffold(String? title) => _Loading(title: title);
Widget messageScaffold(String? title, String text, VoidCallback onRetry) =>
    _Message(title: title, text: text, onRetry: onRetry);
