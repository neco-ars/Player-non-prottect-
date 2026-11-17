import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../sources/source.dart';
import 'album_page.dart';
import 'nav.dart';
import 'theme.dart';
import 'track_menu.dart';
import 'widgets.dart';

/// Исполнитель: популярные треки и дискография.
class ArtistPage extends StatefulWidget {
  final Future<ArtistInfo?> Function() load;
  final String? title;
  final String notFound;
  const ArtistPage({super.key, required this.load, this.title, this.notFound = 'Исполнитель не найден.'});

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  late Future<ArtistInfo?> _future = widget.load();
  bool _allTracks = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ArtistInfo?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return loadingScaffold(widget.title);
        final a = snap.data;
        if (a == null) {
          return messageScaffold(
            widget.title,
            snap.hasError ? 'Не удалось загрузить исполнителя: ${snap.error}' : widget.notFound,
            () => setState(() => _future = widget.load()),
          );
        }
        return Scaffold(body: ListenableBuilder(listenable: app.player, builder: (context, _) => _content(a)));
      },
    );
  }

  Widget _content(ArtistInfo a) {
    final top = a.topTracks;
    final shown = _allTracks ? top : top.take(5).toList();
    final playingHere = top.contains(app.player.current);
    final albums = a.albums.where((x) => x.type?.toLowerCase() != 'single').toList();
    final singles = a.albums.where((x) => x.type?.toLowerCase() == 'single').toList();

    return CustomScrollView(slivers: [
      SliverAppBar(
        pinned: true,
        expandedHeight: 300,
        backgroundColor: AppColors.bg,
        flexibleSpace: FlexibleSpaceBar(
          titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 14, end: 16),
          title: Text(a.ref.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          background: Stack(fit: StackFit.expand, children: [
            if (a.ref.imageUrl != null)
              Opacity(
                opacity: 0.6,
                child: Image.network(a.ref.imageUrl!,
                    fit: BoxFit.cover, cacheWidth: 600, errorBuilder: (_, __, ___) => const SizedBox()),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, AppColors.bg],
                  stops: [0.4, 1],
                ),
              ),
            ),
          ]),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(children: [
            SourceDot(a.ref.source),
            Text(sourceNames[a.ref.source] ?? a.ref.source, style: const TextStyle(color: AppColors.textDim)),
            const Spacer(),
            IconButton(
              tooltip: 'Радио исполнителя',
              icon: const Icon(Icons.radio, color: AppColors.textDim),
              onPressed: top.isEmpty ? null : () => app.player.startRadio(top.first),
            ),
            IconButton(
              tooltip: 'Вперемешку',
              icon: const Icon(Icons.shuffle, color: AppColors.textDim),
              onPressed: top.isEmpty ? null : () => app.player.playQueue(top, 0, shuffled: true),
            ),
            PlayButton(
              playing: playingHere && app.player.player.playing,
              onPressed: () {
                if (top.isEmpty) return;
                if (playingHere) {
                  app.player.player.playing ? app.player.player.pause() : app.player.player.play();
                } else {
                  app.player.playQueue(top, 0);
                }
              },
            ),
          ]),
        ),
      ),
      if (top.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionTitle('Популярные треки')),
        SliverList.builder(
          itemCount: shown.length,
          itemBuilder: (context, i) => TrackTile(
            track: shown[i],
            number: i + 1,
            playing: app.player.current == shown[i],
            onTap: () => app.player.playQueue(top, i),
            onMenu: () => showTrackMenu(context, shown[i]),
          ),
        ),
        if (top.length > 5)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _allTracks = !_allTracks),
                  child: Text(_allTracks ? 'Свернуть' : 'Показать все (${top.length})'),
                ),
              ),
            ),
          ),
      ],
      if (albums.isNotEmpty) ..._carousel('Альбомы', albums),
      if (singles.isNotEmpty) ..._carousel('Синглы и EP', singles),
      if (top.isEmpty && a.albums.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text('У исполнителя на этой площадке пока нет треков.',
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.textDim)),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]);
  }

  List<Widget> _carousel(String title, List<AlbumRef> items) => [
        SliverToBoxAdapter(child: SectionTitle(title)),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 206,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, i) {
                final al = items[i];
                return CoverCard(
                  cover: al.coverUrl,
                  title: al.title,
                  subtitle: [if (al.year != null) '${al.year}', al.typeLabel].join(' · '),
                  explicit: al.explicit,
                  onTap: () => openAlbum(context, al),
                );
              },
            ),
          ),
        ),
      ];
}
