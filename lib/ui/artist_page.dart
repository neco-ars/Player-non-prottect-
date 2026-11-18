import 'package:flutter/material.dart';

import '../models/track.dart';
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
  final String Function() notFound;
  const ArtistPage({super.key, required this.load, this.title, this.notFound = _defaultNotFound});

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

String _defaultNotFound() => 'Исполнитель не найден.';

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
            snap.hasError ? 'Не удалось загрузить исполнителя: ${snap.error}' : widget.notFound(),
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
      // все треки исполнителя — отдельным экраном с подгрузкой
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.library_music),
            label: const Text('Все треки'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ArtistTracksPage(artist: a.ref)),
            ),
          ),
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

/// Все треки исполнителя (а не только популярные), подгружаются порциями при прокрутке.
class ArtistTracksPage extends StatefulWidget {
  final ArtistRef artist;
  const ArtistTracksPage({super.key, required this.artist});

  @override
  State<ArtistTracksPage> createState() => _ArtistTracksPageState();
}

class _ArtistTracksPageState extends State<ArtistTracksPage> {
  final _tracks = <Track>[];
  final _keys = <String>{};
  final _scroll = ScrollController();
  Object? _next;
  bool _done = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      // подгружаем заранее, когда до конца списка осталось ~1.5 экрана
      if (_scroll.position.extentAfter < 1200) _loadMore();
    });
    _loadMore();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    final source = app.catalog.sourceById(widget.artist.source);
    if (source == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // пустые порции (например, сборники без треков исполнителя) пропускаем сразу
      var page = await source.artistTracks(widget.artist.id, cursor: _next).timeout(const Duration(seconds: 20));
      var guard = 0;
      while (page.tracks.isEmpty && page.next != null && guard++ < 5) {
        page = await source.artistTracks(widget.artist.id, cursor: page.next).timeout(const Duration(seconds: 20));
      }
      if (!mounted) return;
      setState(() {
        for (final t in page.tracks) {
          if (_keys.add(t.key)) _tracks.add(t);
        }
        _next = page.next;
        _done = page.next == null;
        _loading = false;
      });
      // если список короткий и экран не заполнен — догружаем ещё
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_done && _scroll.hasClients && _scroll.position.maxScrollExtent < 400) _loadMore();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.artist.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListenableBuilder(
        listenable: app.player,
        builder: (context, _) => ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: _tracks.length + 2,
          itemBuilder: (context, i) {
            if (i == 0) return _header();
            if (i == _tracks.length + 1) return _footer();
            final t = _tracks[i - 1];
            return TrackTile(
              track: t,
              number: i,
              playing: app.player.current == t,
              onTap: () => app.player.playQueue(_tracks, i - 1),
              onMenu: () => showTrackMenu(context, t),
            );
          },
        ),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(children: [
          SourceDot(widget.artist.source),
          Expanded(
            child: Text(
              _done ? 'Все треки: ${_tracks.length}' : 'Загружено: ${_tracks.length}…',
              style: const TextStyle(color: AppColors.textDim),
            ),
          ),
          IconButton(
            tooltip: 'Вперемешку',
            icon: const Icon(Icons.shuffle, color: AppColors.textDim),
            onPressed: _tracks.isEmpty ? null : () => app.player.playQueue(_tracks, 0, shuffled: true),
          ),
          PlayButton(onPressed: () => _tracks.isEmpty ? null : app.player.playQueue(_tracks, 0)),
        ]),
      );

  Widget _footer() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Text('Не удалось загрузить: $_error',
              textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _loadMore, child: const Text('Повторить')),
        ]),
      );
    }
    if (_loading) {
      return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    if (_done && _tracks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Text('У исполнителя на этой площадке нет треков.',
            textAlign: TextAlign.center, style: TextStyle(color: AppColors.textDim)),
      );
    }
    return const SizedBox(height: 24);
  }
}
