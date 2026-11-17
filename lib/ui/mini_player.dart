import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/app_services.dart';
import 'now_playing.dart';
import 'position.dart';
import 'theme.dart';
import 'widgets.dart';

/// Мини-плеер: карточка над вкладками. Нажатие открывает полноэкранный плеер.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final p = app.player;
    return ListenableBuilder(
      listenable: Listenable.merge([p, app.library]),
      builder: (context, _) {
        final t = p.current;
        if (t == null) return const SizedBox.shrink();
        final liked = app.library.isLiked(t);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Material(
            color: AppColors.cardHover,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => Navigator.of(context, rootNavigator: true).push(NowPlayingPage.route()),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const ExplicitOffer(compact: true),
                if (p.error != null)
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.errorContainer,
                    padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
                    child: Row(children: [
                      Expanded(
                        child: Text(p.error!,
                            maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        visualDensity: VisualDensity.compact,
                        onPressed: p.clearError,
                      ),
                    ]),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 0, 6),
                  child: Row(children: [
                    Cover(t.coverUrl, size: 42),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        Row(children: [
                          if (p.radio)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(Icons.radio, size: 12, color: AppColors.accent),
                            ),
                          SourceDot(t.source),
                          Flexible(
                            child: Text(t.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
                          ),
                        ]),
                      ]),
                    ),
                    IconButton(
                      icon: Icon(liked ? Icons.favorite : Icons.favorite_border,
                          color: liked ? AppColors.accent : AppColors.text),
                      onPressed: () => app.library.toggleLike(t),
                    ),
                    if (t.isVideo)
                      IconButton(icon: const Icon(Icons.smart_display), onPressed: p.showVideo)
                    else
                      StreamBuilder<PlayerState>(
                        stream: p.player.playerStateStream,
                        builder: (_, snap) {
                          final st = snap.data;
                          final busy = p.loading ||
                              st?.processingState == ProcessingState.loading ||
                              st?.processingState == ProcessingState.buffering;
                          if (busy) {
                            return const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                            );
                          }
                          final playing = st?.playing ?? false;
                          return IconButton(
                            iconSize: 30,
                            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                            onPressed: playing ? p.player.pause : p.player.play,
                          );
                        },
                      ),
                    IconButton(icon: const Icon(Icons.skip_next), onPressed: p.hasNext ? p.next : null),
                  ]),
                ),
                if (!t.isVideo) _ThinProgress(player: p.player),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Тонкая полоска прогресса внизу мини-плеера.
class _ThinProgress extends StatelessWidget {
  final AudioPlayer player;
  const _ThinProgress({required this.player});
  // тонкая полоска — раз в секунду вполне достаточно
  @override
  Widget build(BuildContext context) => PositionBuilder(
        player: player,
        period: const Duration(seconds: 1),
        builder: (context, pos, total) => LinearProgressIndicator(
          value: total > Duration.zero ? (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0) : 0,
          minHeight: 2,
          backgroundColor: Colors.white24,
          color: AppColors.text,
        ),
      );
}
