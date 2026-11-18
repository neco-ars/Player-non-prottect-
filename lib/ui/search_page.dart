import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import '../services/catalog.dart';
import '../services/search_service.dart';
import '../sources/source.dart';
import 'nav.dart';
import '../sources/net.dart';
import 'settings_page.dart';
import 'source_filter.dart';
import 'theme.dart';
import 'track_menu.dart';
import 'widgets.dart';

/// Плитки жанров на пустом экране поиска: название и запрос.
const _genres = [
  ('Рэп', 'russian rap', Color(0xFFE13300)),
  ('Хип-хоп', 'hip hop', Color(0xFF8D67AB)),
  ('Фонк', 'phonk', Color(0xFF1E3264)),
  ('Трэп', 'trap', Color(0xFFBA5D07)),
  ('Дрилл', 'drill', Color(0xFF477D95)),
  ('Андеграунд', 'underground rap', Color(0xFF503750)),
  ('Рок', 'rock', Color(0xFFE91429)),
  ('Электроника', 'electronic', Color(0xFF0D73EC)),
  ('Поп', 'pop', Color(0xFF148A08)),
  ('Lo-fi', 'lofi', Color(0xFF7358FF)),
];

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

enum _Mode { tracks, albums, artists }

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  _Mode _mode = _Mode.tracks;
  SearchResult? _result; // треки
  CatalogResult<AlbumRef>? _albums;
  CatalogResult<ArtistRef>? _artists;
  String? _searched; // запрос, по которому показаны результаты текущей вкладки
  bool _loading = false;
  bool _explicitOnly = false;
  String? _source; // null — все площадки
  List<String> _pending = const [];
  Map<String, String> _errors = const {};

  StreamSubscription<Object>? _sub;

  bool get _hasResults => switch (_mode) {
        _Mode.tracks => _result != null,
        _Mode.albums => _albums != null,
        _Mode.artists => _artists != null,
      };

  Future<void> _search([String? q]) async {
    if (q != null) _controller.text = q;
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    await _sub?.cancel();
    setState(() {
      _loading = true;
      _searched = query;
      _pending = const [];
      _errors = const {};
      _result = null;
      _albums = null;
      _artists = null;
    });
    // результаты показываем по мере ответа площадок, не дожидаясь самой медленной
    void update(List<String> pending, Map<String, String> errors, void Function() apply) {
      if (!mounted) return;
      setState(() {
        apply();
        _pending = pending;
        _errors = errors;
        _loading = pending.isNotEmpty;
      });
    }

    _sub = switch (_mode) {
      _Mode.tracks => app.search.searchStream(query).listen((r) => update(r.pending, r.errors, () => _result = r)),
      _Mode.albums => app.catalog.searchAlbums(query).listen((r) => update(r.pending, r.errors, () => _albums = r)),
      _Mode.artists => app.catalog.searchArtists(query).listen((r) => update(r.pending, r.errors, () => _artists = r)),
    };
  }

  /// Какие площадки предлагать в фильтре: для альбомов и исполнителей — только те, у кого они есть.
  Iterable<String> get _sourcesForMode => [
        for (final s in app.search.sources)
          if (s.isConfigured && (_mode == _Mode.tracks || s.hasCatalog)) s.id
      ];

  void _setMode(_Mode m) {
    if (m == _mode) return;
    setState(() => _mode = m);
    // тот же запрос — сразу ищем на новой вкладке
    if (_controller.text.trim().isNotEmpty) _search();
  }

  void _clear() {
    _sub?.cancel();
    _controller.clear();
    setState(() {
      _result = null;
      _albums = null;
      _artists = null;
      _searched = null;
      _loading = false;
      _pending = const [];
      _errors = const {};
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  List<TrackGroup> get _groups {
    final g = filterGroups(_result?.groups ?? [], _source);
    return _explicitOnly ? g.where((x) => x.anyExplicit).toList() : g;
  }

  void _play(TrackGroup group, Track variant) {
    // очередь: выбранная версия, дальше — основные версии следующих песен
    final groups = _groups;
    final i = groups.indexOf(group);
    app.player.playQueue([variant, ...groups.skip(i + 1).map((g) => g.main)], 0);
  }

  Future<void> _openSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final missing = [
      if (Net.proxyMissing) 'прокси (без него Яндекс и SoundCloud в браузере не работают)',
      if (!app.yandex.isConfigured && !Net.proxyMissing) 'Яндекс Музыка',
      if (!app.youtube.isConfigured) 'YouTube',
    ];
    final noSources = !app.search.sources.any((s) => s.isConfigured);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(children: [
              const Expanded(child: Text('Поиск', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold))),
              IconButton(
                tooltip: 'Только explicit',
                icon: Icon(Icons.explicit, color: _explicitOnly ? AppColors.accent : AppColors.textDim, size: 28),
                onPressed: () => setState(() => _explicitOnly = !_explicitOnly),
              ),
            ]),
          ),
          // поле поиска — светлое, как в больших плеерах
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              style: const TextStyle(color: Colors.black, fontSize: 16),
              cursorColor: Colors.black,
              decoration: InputDecoration(
                hintText: switch (_mode) {
                  _Mode.tracks => 'Что хочешь послушать?',
                  _Mode.albums => 'Название альбома',
                  _Mode.artists => 'Имя исполнителя',
                },
                hintStyle: const TextStyle(color: Color(0xFF535353)),
                filled: true,
                fillColor: Colors.white,
                prefixIcon: const Icon(Icons.search, color: Colors.black),
                suffixIcon: _controller.text.isEmpty && !_hasResults
                    ? null
                    : IconButton(icon: const Icon(Icons.close, color: Colors.black), onPressed: _clear),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          // вкладки: треки / альбомы / исполнители
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(children: [
              for (final (m, label) in const [
                (_Mode.tracks, 'Треки'),
                (_Mode.albums, 'Альбомы'),
                (_Mode.artists, 'Исполнители'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _mode == m,
                    showCheckmark: false,
                    onSelected: (_) => _setMode(m),
                    selectedColor: AppColors.accent,
                    labelStyle: TextStyle(
                        color: _mode == m ? Colors.black : AppColors.text, fontWeight: FontWeight.w600),
                    backgroundColor: AppColors.card,
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                  ),
                ),
            ]),
          ),
          // площадки: все или одна
          if (_hasResults || _searched != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SourceFilterBar(
                value: _source,
                onChanged: (v) => setState(() => _source = v),
                only: _sourcesForMode,
              ),
            ),
          if (_loading) ...[
            const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
            if (_pending.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text('Ещё ищем: ${_pending.join(', ')}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
              ),
          ],
          if (missing.isNotEmpty)
            _Notice(
              text: noSources
                  ? 'Ни одна площадка не подключена, искать негде. Не хватает: ${missing.join(', ')}.'
                  : 'Не подключено: ${missing.join(', ')}.',
              action: 'Подключить',
              onAction: _openSettings,
            ),
          for (final e in _errors.entries)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text('${e.key}: ${e.value}', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ),
          Expanded(
            child: !_hasResults && _searched == null
                ? _GenreGrid(onPick: (q) {
                    setState(() => _mode = _Mode.tracks);
                    _search(q);
                  })
                : switch (_mode) {
                    _Mode.tracks => _results(noSources),
                    _Mode.albums => _albumResults(),
                    _Mode.artists => _artistResults(),
                  },
          ),
        ]),
      ),
    );
  }

  Widget _empty(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim)),
        ),
      );

  Widget _albumResults() {
    final items = [for (final a in _albums?.items ?? const <AlbumRef>[]) if (_source == null || a.source == _source) a];
    final list = _explicitOnly ? items.where((a) => a.explicit).toList() : items;
    if (list.isEmpty) {
      if (_loading) return const SizedBox.shrink();
      return _empty(_errors.isNotEmpty ? 'Ничего не найдено — площадки ответили ошибкой (см. выше).' : 'Альбомов не найдено.');
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final a = list[i];
        return InkWell(
          onTap: () => openAlbum(context, a),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              Cover(a.coverUrl, size: 64, placeholderIcon: Icons.album),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Row(children: [
                    if (a.explicit) const ExplicitBadge(),
                    SourceDot(a.source),
                    Flexible(
                      child: Text([a.typeLabel, a.artist, if (a.year != null) '${a.year}'].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
                    ),
                  ]),
                ]),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textDim),
            ]),
          ),
        );
      },
    );
  }

  Widget _artistResults() {
    final list = [for (final a in _artists?.items ?? const <ArtistRef>[]) if (_source == null || a.source == _source) a];
    if (list.isEmpty) {
      if (_loading) return const SizedBox.shrink();
      return _empty(_errors.isNotEmpty ? 'Ничего не найдено — площадки ответили ошибкой (см. выше).' : 'Исполнителей не найдено.');
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final a = list[i];
        return InkWell(
          onTap: () => openArtist(context, a),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              Cover(a.imageUrl, size: 64, radius: 32, placeholderIcon: Icons.person),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Row(children: [
                    SourceDot(a.source),
                    Text('Исполнитель · ${sourceNames[a.source] ?? a.source}',
                        style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
                  ]),
                ]),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textDim),
            ]),
          ),
        );
      },
    );
  }

  Widget _results(bool noSources) {
    if (_groups.isEmpty && _loading) return const SizedBox.shrink(); // ждём первую площадку
    if (_groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            noSources
                ? 'Ничего не искали: ни одна площадка не подключена.\nОткрой ⚙ Настройки на главной.'
                : _source != null && (_result?.groups.isNotEmpty ?? false)
                    ? 'На площадке ${sourceNames[_source] ?? _source} ничего не нашлось. Выбери «Все».'
                : _explicitOnly && (_result?.groups.isNotEmpty ?? false)
                    ? 'Explicit-версий не нашлось. Выключи фильтр «E», чтобы увидеть все.'
                    : (_result?.errors.isNotEmpty ?? false)
                        ? 'Ничего не найдено — площадки ответили ошибкой (см. выше).'
                        : 'Ничего не найдено.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textDim),
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: app.player,
      builder: (context, _) => ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 16),
        itemCount: _groups.length,
        itemBuilder: (context, i) => _GroupTile(
          group: _groups[i],
          current: app.player.current,
          onPlay: (v) => _play(_groups[i], v),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  final String action;
  final VoidCallback onAction;
  const _Notice({required this.text, required this.action, required this.onAction});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: AppColors.textDim))),
          TextButton(onPressed: onAction, child: Text(action)),
        ]),
      );
}

class _GenreGrid extends StatelessWidget {
  final void Function(String) onPick;
  const _GenreGrid({required this.onPick});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
        const Padding(
          padding: EdgeInsets.only(top: 14, bottom: 12),
          child: Text('Жанры', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.75,
          children: [
            for (final (name, query, color) in _genres)
              Material(
                color: color,
                borderRadius: BorderRadius.circular(6),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onPick(query),
                  child: Stack(children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                    ),
                    // декоративная «повёрнутая обложка» в углу
                    Positioned(
                      right: -14,
                      bottom: -6,
                      child: Transform.rotate(
                        angle: 0.42,
                        child: Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(Icons.music_note, color: Colors.white70),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
          ],
        ),
      ]);
}

class _GroupTile extends StatelessWidget {
  final TrackGroup group;
  final Track? current;
  final void Function(Track) onPlay;
  const _GroupTile({required this.group, required this.current, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final t = group.main;
    final playing = group.variants.any((v) => v.key == current?.key);
    final meta = [t.album, t.year?.toString()].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    return InkWell(
      onTap: () => onPlay(t),
      onLongPress: () => showTrackMenu(context, t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Cover(t.coverUrl, size: 56),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600, color: playing ? AppColors.accent : AppColors.text)),
              const SizedBox(height: 2),
              Row(children: [
                if (group.anyExplicit) const ExplicitBadge(),
                Flexible(
                  child: Text([t.artist, if (meta.isNotEmpty) meta].join(' · '),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
                ),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final v in group.variants)
                  VariantChip(track: v, playing: current?.key == v.key, onTap: () => onPlay(v)),
              ]),
            ]),
          ),
          IconButton(
              icon: const Icon(Icons.more_vert, color: AppColors.textDim), onPressed: () => showTrackMenu(context, t)),
        ]),
      ),
    );
  }
}
