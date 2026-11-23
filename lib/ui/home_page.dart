import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/library.dart';
import '../services/recommendations.dart';
import 'library_page.dart';
import 'source_filter.dart';
import 'tag_chips.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'track_menu.dart';
import 'widgets.dart';

/// Главная: приветствие, быстрые плитки, карусели рекомендаций.
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _source; // показывать подборки только одной площадки (null — все)

  late Future<List<RecSection>> _future = app.recs.forYou();

  Future<void> _refresh() async {
    final f = app.recs.forYou(force: true);
    setState(() => _future = f);
    await f;
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5) return 'Доброй ночи';
    if (h < 12) return 'Доброе утро';
    if (h < 18) return 'Добрый день';
    return 'Добрый вечер';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListenableBuilder(
            listenable: Listenable.merge([app.player, app.library]),
            builder: (context, _) => CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 4, 8),
                  child: Row(children: [
                    Expanded(
                      child: Text(_greeting, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
                    ),
                  ]),
                ),
              ),
              const SliverToBoxAdapter(child: _WaveCard()),
              const SliverToBoxAdapter(child: YourTags()),
              SliverToBoxAdapter(child: _QuickGrid()),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SourceFilterBar(value: _source, onChanged: (v) => setState(() => _source = v)),
                ),
              ),
              SliverToBoxAdapter(
                child: FutureBuilder<List<RecSection>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(48),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final sections = snap.data ?? [];
                    if (sections.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Послушай что-нибудь через поиск — здесь появятся подборки по твоей истории.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textDim),
                        ),
                      );
                    }
                    final shown = [for (final s in sections) _Carousel(section: s, source: _source)];
                    final anyTracks = sections.any((s) =>
                        s.tracks.any((t) => (_source == null || t.source == _source) && app.library.allowedInRecs(t)));
                    if (!anyTracks) {
                      return Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'В подборках пока нет треков с площадки ${sourceNames[_source] ?? _source}. '
                          'Послушай что-нибудь оттуда — подборки появятся.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.textDim),
                        ),
                      );
                    }
                    return Column(children: shown);
                  },
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// «Моя волна»: бесконечное радио по твоему вкусу (что слушаешь, лайкаешь и пропускаешь).
class _WaveCard extends StatelessWidget {
  const _WaveCard();

  Future<void> _start(BuildContext context) async {
    final p = app.player;
    if (p.radioSeed?.kind == RadioKind.wave && p.current != null) {
      p.player.playing ? await p.player.pause() : await p.player.play();
      return;
    }
    await p.startWave();
    if (p.current == null && p.error != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(p.error!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = app.player;
    final on = p.radioSeed?.kind == RadioKind.wave && p.current != null;
    final empty = app.library.history.isEmpty && app.library.liked.tracks.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Material(
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF2B1A6B), Color(0xFF6A3DE8), Color(0xFFB04BD9)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: InkWell(
            onTap: p.radioStarting ? null : () => _start(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Моя волна', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 4),
                    Text(
                      on
                          ? 'Играет. Пропускай то, что не нравится, — волна подстроится'
                          : empty
                              ? 'Начнём с популярного, дальше — по твоему вкусу'
                              : 'Бесконечно, по твоему вкусу: ${app.library.topArtists(3).join(', ')} и похожие',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ]),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 52,
                  height: 52,
                  child: p.radioStarting
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                        )
                      : StreamBuilder<bool>(
                          stream: p.player.playingStream,
                          builder: (_, snap) => CircleAvatar(
                            backgroundColor: Colors.white,
                            child: Icon(on && (snap.data ?? false) ? Icons.pause : Icons.play_arrow,
                                color: const Color(0xFF6A3DE8), size: 32),
                          ),
                        ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Плитки 2×N: «Любимое», свои плейлисты, последние треки.
class _QuickGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final lib = app.library;
    final items = <_QuickItem>[
      _QuickItem('Любимое', null, Icons.favorite, () => openPlaylist(context, lib.liked)),
      for (final p in lib.playlists.where((p) => p.id != Library.likedId).take(3))
        _QuickItem(p.name, p.tracks.where((t) => t.coverUrl != null).firstOrNull?.coverUrl, Icons.queue_music,
            () => openPlaylist(context, p)),
      for (final t in lib.history.take(6 - 1 - lib.playlists.where((p) => p.id != Library.likedId).take(3).length))
        _QuickItem(t.title, t.coverUrl, Icons.music_note, () => app.player.playQueue(lib.history, lib.history.indexOf(t))),
    ];
    if (items.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 3.2,
        children: [for (final i in items) _QuickTile(item: i)],
      ),
    );
  }
}

class _QuickItem {
  final String title;
  final String? cover;
  final IconData icon;
  final VoidCallback onTap;
  _QuickItem(this.title, this.cover, this.icon, this.onTap);
}

class _QuickTile extends StatelessWidget {
  final _QuickItem item;
  const _QuickTile({required this.item});
  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(4),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: item.onTap,
          child: Row(children: [
            AspectRatio(
              aspectRatio: 1,
              child: item.icon == Icons.favorite
                  ? Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(colors: [Color(0xFF4A1FB8), AppColors.accent]),
                      ),
                      child: const Icon(Icons.favorite, color: Colors.white),
                    )
                  : LayoutBuilder(
                      builder: (_, c) => Cover(item.cover, size: c.maxHeight, radius: 0, placeholderIcon: item.icon)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(item.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ]),
        ),
      );
}

class _Carousel extends StatelessWidget {
  final RecSection section;
  final String? source;
  const _Carousel({required this.section, this.source});

  @override
  Widget build(BuildContext context) {
    // «не нравится» пропадает сразу, не дожидаясь обновления главной
    final tracks = section.tracks
        .where((t) => (source == null || t.source == source) && app.library.allowedInRecs(t))
        .toList();
    if (tracks.isEmpty) return const SizedBox.shrink();
    // подборки «похожего» продолжаются радио; история, любимое и чарт — просто списки
    final isRadio = section.title.startsWith('Похоже') || section.title.startsWith('Новое');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionTitle(
        section.title,
        subtitle: section.subtitle,
        trailing: IconButton(
          icon: const Icon(Icons.play_circle_fill, size: 36, color: AppColors.accent),
          tooltip: 'Слушать',
          onPressed: () => app.player.playQueue(tracks, 0, radio: isRadio),
        ),
      ),
      SizedBox(
        height: 206,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: tracks.length,
          separatorBuilder: (_, __) => const SizedBox(width: 14),
          itemBuilder: (context, i) {
            final t = tracks[i];
            return CoverCard(
              cover: t.coverUrl,
              title: t.title,
              subtitle: t.artist,
              explicit: t.explicit,
              playing: app.player.current == t,
              onTap: () => app.player.playQueue(tracks, i, radio: isRadio),
              onLongPress: () => showTrackMenu(context, t),
            );
          },
        ),
      ),
    ]);
  }
}
