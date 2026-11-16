import 'dart:async';

import 'package:flutter/material.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import 'track_menu.dart';

/// Официальный встроенный плеер YouTube.
class VideoPage extends StatefulWidget {
  static const routeName = 'video';
  final Track track;
  const VideoPage({super.key, required this.track});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final YoutubePlayerController _controller;
  StreamSubscription? _sub;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.track.id,
      autoPlay: true,
      params: const YoutubePlayerParams(showFullscreenButton: true, strictRelatedVideos: true),
    );
    _sub = _controller.stream.listen((v) {
      if (v.playerState == PlayerState.ended && !_ended) {
        _ended = true;
        // закрываем ролик и переходим к следующему треку очереди
        if (mounted) Navigator.of(context).maybePop();
        app.player.videoEnded(widget.track);
      }
    });
    app.player.addListener(_onPlayerChanged);
  }

  /// Пользователь переключил трек на не-видео — закрываем ролик.
  void _onPlayerChanged() {
    final cur = app.player.current;
    if (mounted && cur != null && cur != widget.track && !cur.isVideo) {
      app.player.removeListener(_onPlayerChanged);
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    app.player.removeListener(_onPlayerChanged);
    _sub?.cancel();
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showTrackMenu(context, t))],
      ),
      body: ListView(children: [
        YoutubePlayer(controller: _controller, aspectRatio: 16 / 9),
        ListTile(
          title: Text(t.title),
          subtitle: Text(t.artist),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.skip_previous),
              label: const Text('Назад'),
              onPressed: app.player.hasPrev ? app.player.previous : null,
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Icons.skip_next),
              label: const Text('Дальше'),
              onPressed: app.player.hasNext ? app.player.next : null,
            ),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Ролики YouTube играют через официальный плеер YouTube, поэтому в фоне и с выключенным экраном они не звучат.',
              style: TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}
