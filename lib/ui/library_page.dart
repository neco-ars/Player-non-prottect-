import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import '../services/library.dart';
import 'theme.dart';
import 'track_menu.dart';
import 'widgets.dart';

void openPlaylist(BuildContext context, Playlist p) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => PlaylistPage(playlist: p)));

/// Медиатека: «Любимое», свои плейлисты, история.
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = app.library;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Моя медиатека'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, size: 28),
            tooltip: 'Новый плейлист',
            onPressed: () async {
              final name = await askName(context);
              if (name != null && name.isNotEmpty) lib.createPlaylist(name);
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([lib, app.local]),
        builder: (context, _) => ListView(padding: const EdgeInsets.only(bottom: 16), children: [
          if (app.local.supported)
            _LibraryRow(
              leading: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  gradient: const LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0B6E4F), Color(0xFF2EC4B6)]),
                ),
                child: const Icon(Icons.folder_special, color: Colors.white, size: 30),
              ),
              title: 'Мои файлы',
              subtitle: 'На устройстве · ${_tracksWord(app.local.tracks.length)}',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LocalFilesPage())),
            ),
          for (final p in lib.playlists)
            _LibraryRow(
              leading: _PlaylistArt(p, size: 64),
              title: p.name,
              subtitle: 'Плейлист · ${_tracksWord(p.tracks.length)}',
              onTap: () => openPlaylist(context, p),
            ),
          _LibraryRow(
            leading: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(4)),
              child: const Icon(Icons.history, color: AppColors.textDim, size: 30),
            ),
            title: 'Недавно прослушанные',
            subtitle: _tracksWord(lib.history.length),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryPage())),
          ),
          if (lib.disliked.isNotEmpty)
            _LibraryRow(
              leading: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(4)),
                child: const Icon(Icons.thumb_down_outlined, color: AppColors.textDim, size: 28),
              ),
              title: 'Скрытое',
              subtitle: 'Не нравится · ${_tracksWord(lib.disliked.length)}',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HiddenPage())),
            ),
        ]),
      ),
    );
  }
}

String _tracksWord(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = (m10 == 1 && m100 != 11)
      ? 'трек'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? 'трека'
          : 'треков';
  return '$n $w';
}

class _LibraryRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _LibraryRow({required this.leading, required this.title, required this.subtitle, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            leading,
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(subtitle, style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
              ]),
            ),
          ]),
        ),
      );
}

/// Обложка плейлиста: градиент с сердцем для «Любимого», иначе коллаж из 4 обложек.
class _PlaylistArt extends StatelessWidget {
  final Playlist p;
  final double size;
  const _PlaylistArt(this.p, {required this.size});
  @override
  Widget build(BuildContext context) {
    if (p.id == Library.likedId) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF4A1FB8), AppColors.accent]),
        ),
        child: Icon(Icons.favorite, color: Colors.white, size: size * 0.42),
      );
    }
    final covers = p.tracks.map((t) => t.coverUrl).whereType<String>().toSet().take(4).toList();
    if (covers.length < 4) return Cover(covers.firstOrNull, size: size, placeholderIcon: Icons.queue_music);
    final half = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: size,
        height: size,
        child: Wrap(children: [for (final c in covers) Cover(c, size: half, radius: 0)]),
      ),
    );
  }
}

class PlaylistPage extends StatelessWidget {
  final Playlist playlist;
  const PlaylistPage({super.key, required this.playlist});

  Future<void> _menu(BuildContext context) async {
    final lib = app.library;
    final p = playlist;
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit), title: const Text('Переименовать'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Удалить плейлист'),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (v == 'rename') {
      final name = await askName(context, title: 'Переименовать', initial: p.name);
      if (name != null && name.isNotEmpty) lib.renamePlaylist(p, name);
    } else if (v == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Удалить «${p.name}»?'),
          content: const Text('Сами треки на площадках останутся, удалится только плейлист.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
          ],
        ),
      );
      if (ok == true && context.mounted) {
        lib.deletePlaylist(p);
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = app.library;
    final p = playlist;
    final editable = p.id != Library.likedId;
    final accent = p.id == Library.likedId ? const Color(0xFF4A1FB8) : AppColors.accent;
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([lib, app.player]),
        builder: (context, _) {
          final playingHere = p.tracks.contains(app.player.current);
          return CustomScrollView(slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 300,
              backgroundColor: AppColors.bg,
              actions: [if (editable) IconButton(icon: const Icon(Icons.more_vert), onPressed: () => _menu(context))],
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 14, end: 56),
                title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                background: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [accent.withValues(alpha: 0.7), AppColors.bg],
                    ),
                  ),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 40, bottom: 40),
                      child: _PlaylistArt(p, size: 170),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [
                  Text(_tracksWord(p.tracks.length), style: const TextStyle(color: AppColors.textDim)),
                  const Spacer(),
                  IconButton(
                    iconSize: 28,
                    icon: const Icon(Icons.shuffle, color: AppColors.textDim),
                    tooltip: 'Вперемешку',
                    onPressed: p.tracks.isEmpty
                        ? null
                        : () => app.player.playQueue(p.tracks, (DateTime.now().millisecond) % p.tracks.length, shuffled: true),
                  ),
                  const SizedBox(width: 8),
                  PlayButton(
                    playing: playingHere && app.player.player.playing,
                    onPressed: () {
                      if (p.tracks.isEmpty) return;
                      if (playingHere) {
                        app.player.player.playing ? app.player.player.pause() : app.player.player.play();
                      } else {
                        app.player.playQueue(p.tracks, 0);
                      }
                    },
                  ),
                ]),
              ),
            ),
            if (p.tracks.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Пусто. Добавляй треки через ⋮ в поиске или на главной.',
                      textAlign: TextAlign.center, style: TextStyle(color: AppColors.textDim)),
                ),
              )
            else
              SliverReorderableList(
                itemCount: p.tracks.length,
                onReorder: (a, b) => lib.reorder(p, a, b),
                itemBuilder: (context, i) {
                  final t = p.tracks[i];
                  return Material(
                    key: ValueKey(t.key),
                    color: Colors.transparent,
                    child: TrackTile(
                      track: t,
                      playing: app.player.current == t,
                      onTap: () => app.player.playQueue(p.tracks, i),
                      onMenu: () => showTrackMenu(context, t, playlist: p),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.more_vert, color: AppColors.textDim),
                          onPressed: () => showTrackMenu(context, t, playlist: p),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Icon(Icons.drag_handle, color: AppColors.textDim),
                          ),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ]);
        },
      ),
    );
  }
}

/// «Мои файлы»: музыка, добавленная на устройство. Играет офлайн.
class LocalFilesPage extends StatefulWidget {
  const LocalFilesPage({super.key});
  @override
  State<LocalFilesPage> createState() => _LocalFilesPageState();
}

class _LocalFilesPageState extends State<LocalFilesPage> {
  bool _importing = false;

  Future<void> _add() async {
    setState(() => _importing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await app.local.pickAndImport();
      if (n > 0) messenger.showSnackBar(SnackBar(content: Text('Добавлено: ${_tracksWord(n)}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось добавить: $e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Мои файлы')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _add,
        icon: _importing
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
            : const Icon(Icons.add),
        label: Text(_importing ? 'Добавляю…' : 'Добавить музыку'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([app.local, app.player]),
        builder: (context, _) {
          final tracks = app.local.tracks;
          if (tracks.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Здесь будет музыка с этого устройства: mp3, flac, m4a, ogg, wav.\n\n'
                  'Нажми «Добавить музыку» и выбери файлы — они скопируются в приложение, '
                  'будут играть без интернета и появятся в поиске рядом с другими площадками.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textDim),
                ),
              ),
            );
          }
          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(children: [
                Text(_tracksWord(tracks.length), style: const TextStyle(color: AppColors.textDim)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.shuffle, color: AppColors.textDim),
                  onPressed: () => app.player.playQueue(tracks, 0, shuffled: true),
                ),
                PlayButton(onPressed: () => app.player.playQueue(tracks, 0)),
              ]),
            ),
            for (var i = 0; i < tracks.length; i++)
              TrackTile(
                track: tracks[i],
                playing: app.player.current == tracks[i],
                onTap: () => app.player.playQueue(tracks, i),
                onMenu: () => showTrackMenu(context, tracks[i]),
              ),
          ]);
        },
      ),
    );
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});
  @override
  Widget build(BuildContext context) {
    final List<Track> h = app.library.history;
    return Scaffold(
      appBar: AppBar(title: const Text('Недавно прослушанные')),
      body: ListenableBuilder(
        listenable: app.player,
        builder: (context, _) => ListView.builder(
          itemCount: h.length,
          itemBuilder: (context, i) => TrackTile(
            track: h[i],
            playing: app.player.current == h[i],
            onTap: () => app.player.playQueue(List.of(h), i),
            onMenu: () => showTrackMenu(context, h[i]),
          ),
        ),
      ),
    );
  }
}

/// «Скрытое»: песни с «Не нравится». Их исполнители тоже не попадают в волну и радио.
class HiddenPage extends StatelessWidget {
  const HiddenPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Скрытое')),
        body: ListenableBuilder(
          listenable: app.library,
          builder: (context, _) {
            final list = app.library.disliked;
            if (list.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Пусто. Нажми 👎 «Не нравится» в плеере — песня и её исполнитель пропадут из волны и радио.',
                      textAlign: TextAlign.center, style: TextStyle(color: AppColors.textDim)),
                ),
              );
            }
            return ListView(children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('Эти песни и их исполнители не попадают в «Мою волну», радио и подборки. '
                    'В поиске их по-прежнему можно найти.', style: TextStyle(color: AppColors.textDim)),
              ),
              for (final t in list)
                TrackTile(
                  track: t,
                  onTap: () => app.player.playQueue([t], 0),
                  trailing: TextButton(onPressed: () => app.player.undislike(t), child: const Text('Вернуть')),
                ),
            ]);
          },
        ),
      );
}
