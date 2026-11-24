import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import '../services/library.dart';
import '../sources/soundcloud.dart';
import 'nav.dart';
import 'widgets.dart';

/// Меню действий с треком. [playlist] — если открыто из плейлиста (тогда есть «Удалить»).
Future<void> showTrackMenu(BuildContext context, Track t, {Playlist? playlist}) {
  final lib = app.library;
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      void close() => Navigator.pop(ctx);
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Cover(t.coverUrl, size: 44),
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${t.artist} · ${sourceNames[t.source] ?? t.source}', maxLines: 1),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(lib.isLiked(t) ? Icons.favorite : Icons.favorite_border),
            title: Text(lib.isLiked(t) ? 'Убрать из «Любимого»' : 'В «Любимое»'),
            onTap: () {
              app.player.toggleLike(t);
              close();
            },
          ),
          ListTile(
            leading: Icon(lib.isDisliked(t) ? Icons.thumb_down : Icons.thumb_down_outlined),
            title: Text(lib.isDisliked(t) ? 'Снова показывать в рекомендациях' : 'Не нравится'),
            subtitle: lib.isDisliked(t) ? null : const Text('Убрать песню и исполнителя из волны и радио'),
            onTap: () {
              close();
              lib.isDisliked(t) ? app.player.undislike(t) : app.player.dislike(t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Добавить в плейлист'),
            onTap: () {
              close();
              pickPlaylistAndAdd(context, t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.album),
            title: const Text('Перейти к альбому'),
            onTap: () {
              close();
              openAlbumOf(context, t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Перейти к исполнителю'),
            onTap: () {
              close();
              openArtistOf(context, t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.radio),
            title: const Text('Радио по треку'),
            onTap: () {
              close();
              app.player.startRadio(t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_play_next),
            title: const Text('Играть следующим'),
            onTap: () {
              close();
              app.player.playNext(t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.add_to_queue),
            title: const Text('В конец очереди'),
            onTap: () {
              close();
              app.player.addToQueue(t);
            },
          ),
          if (SoundCloudSource.webUrl(t) != null)
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Открыть в SoundCloud'),
              onTap: () {
                close();
                launchUrl(SoundCloudSource.webUrl(t)!, mode: LaunchMode.externalApplication);
              },
            ),
          if (t.source == 'local')
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Удалить из «Моих файлов»'),
              onTap: () async {
                close();
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Удалить «${t.title}»?'),
                    content: const Text('Файл удалится из приложения. Оригинал на устройстве, если он остался, не трогаю.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
                    ],
                  ),
                );
                if (ok == true) await app.local.remove(t);
              },
            ),
          if (playlist != null && playlist.id != Library.likedId)
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: Text('Удалить из «${playlist.name}»'),
              onTap: () {
                lib.removeFrom(playlist, t);
                close();
              },
            ),
        ]),
      );
    },
  );
}

Future<String?> askName(BuildContext context, {String title = 'Новый плейлист', String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Название'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<void> pickPlaylistAndAdd(BuildContext context, Track t) async {
  final lib = app.library;
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Новый плейлист'),
          onTap: () => Navigator.pop(ctx, 'new'),
        ),
        for (final p in lib.playlists)
          ListTile(
            leading: Icon(p.id == Library.likedId ? Icons.favorite : Icons.queue_music),
            title: Text(p.name),
            subtitle: Text('${p.tracks.length} треков'),
            onTap: () => Navigator.pop(ctx, p),
          ),
      ]),
    ),
  );
  Playlist? target;
  if (choice == 'new') {
    if (!context.mounted) return;
    final name = await askName(context);
    if (name == null || name.isEmpty) return;
    target = lib.createPlaylist(name);
  } else if (choice is Playlist) {
    target = choice;
  }
  if (target == null) return;
  final added = lib.addTo(target, t);
  messenger.showSnackBar(SnackBar(content: Text(added ? 'Добавлено в «${target.name}»' : 'Уже есть в «${target.name}»')));
}
