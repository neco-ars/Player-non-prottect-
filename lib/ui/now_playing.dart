import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/app_services.dart';
import '../services/player_service.dart';
import 'equalizer_page.dart';
import 'lyrics_sheet.dart';
import 'nav.dart';
import 'position.dart';
import 'theme.dart';
import 'track_menu.dart';
import 'widgets.dart';

/// Полноэкранный плеер.
class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  static Route<void> route() => PageRouteBuilder(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => const NowPlayingPage(),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = app.player;
    return ListenableBuilder(
      listenable: Listenable.merge([p, app.library]),
      builder: (context, _) {
        final t = p.current;
        if (t == null) {
          return const Scaffold(body: Center(child: Text('Ничего не играет')));
        }
        final liked = app.library.isLiked(t);
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: Stack(fit: StackFit.expand, children: [
            // «размытая» обложка на фоне: декодируем её крошечной (12 px) и растягиваем со сглаживанием.
            // Выглядит как размытие, но не нагружает видеочип в отличие от настоящего фильтра blur.
            if (t.coverUrl != null)
              RepaintBoundary(
                child: Opacity(
                  opacity: 0.85,
                  child: t.coverUrl!.startsWith('file:')
                      ? const SizedBox()
                      : Image.network(t.coverUrl!,
                          fit: BoxFit.cover,
                          cacheWidth: 12,
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => const SizedBox()),
                ),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0xEE121212), AppColors.bg],
                  stops: [0, 0.55, 1],
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(builder: (context, box) {
                final coverSize = (box.maxWidth - 48).clamp(160.0, box.maxHeight * 0.45).toDouble();
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(children: [
                    // верхняя панель
                    Row(children: [
                      IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Column(children: [
                          Text(p.radio ? 'РАДИО' : 'СЕЙЧАС ИГРАЕТ',
                              style: const TextStyle(fontSize: 11, letterSpacing: 1.2, color: AppColors.textDim)),
                          Text(sourceNames[t.source] ?? t.source,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        ]),
                      ),
                      IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showTrackMenu(context, t)),
                    ]),
                    const Spacer(),
                    // обложка: свайп влево — следующий трек, вправо — предыдущий
                    SwipeToSkip(
                      onTap: t.isVideo ? p.showVideo : null,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(anim), child: child),
                        ),
                        child: Stack(key: ValueKey(t.key), alignment: Alignment.center, children: [
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(0, 12))],
                            ),
                            child: Cover(t.coverUrl, size: coverSize, radius: 8),
                          ),
                          if (t.isVideo)
                            const CircleAvatar(
                              radius: 30,
                              backgroundColor: Colors.black54,
                              child: Icon(Icons.smart_display, size: 34, color: Colors.white),
                            ),
                        ]),
                      ),
                    ),
                    const Spacer(),
                    // название + лайк
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          // название → альбом с этим треком
                          GestureDetector(
                            onTap: () => openAlbumOf(context, t),
                            child: Text(t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(height: 4),
                          Row(children: [
                            if (t.explicit) const ExplicitBadge(),
                            Flexible(
                              // исполнитель → его страница
                              child: GestureDetector(
                                onTap: () => openArtistOf(context, t),
                                child: Text(t.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 16, color: AppColors.textDim)),
                              ),
                            ),
                          ]),
                        ]),
                      ),
                      IconButton(
                        iconSize: 28,
                        icon: Icon(liked ? Icons.favorite : Icons.favorite_border,
                            color: liked ? AppColors.accent : AppColors.text),
                        onPressed: () => app.library.toggleLike(t),
                      ),
                    ]),
                    const ExplicitOffer(),
                    if (p.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(p.error!,
                            maxLines: 3, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                      ),
                    const SizedBox(height: 12),
                    if (t.isVideo)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.smart_display),
                          label: const Text('Открыть ролик YouTube'),
                          onPressed: p.showVideo,
                        ),
                      )
                    else
                      _SeekBar(player: p.player),
                    // кнопки
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      IconButton(
                        iconSize: 26,
                        icon: Icon(Icons.shuffle, color: p.shuffle ? AppColors.accent : AppColors.text),
                        onPressed: p.toggleShuffle,
                      ),
                      IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous), onPressed: p.previous),
                      StreamBuilder<PlayerState>(
                        stream: p.player.playerStateStream,
                        builder: (_, snap) {
                          final st = snap.data;
                          final busy = p.loading ||
                              st?.processingState == ProcessingState.loading ||
                              st?.processingState == ProcessingState.buffering;
                          if (busy && !t.isVideo) {
                            return const SizedBox(
                              width: 68,
                              height: 68,
                              child: Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator(strokeWidth: 3)),
                            );
                          }
                          final playing = st?.playing ?? false;
                          return PlayButton(
                            size: 68,
                            playing: playing,
                            onPressed: t.isVideo ? p.showVideo : (playing ? p.player.pause : p.player.play),
                          );
                        },
                      ),
                      IconButton(
                          iconSize: 40, icon: const Icon(Icons.skip_next), onPressed: p.hasNext ? p.next : null),
                      IconButton(
                        iconSize: 26,
                        icon: Icon(p.repeat == Repeat.one ? Icons.repeat_one : Icons.repeat,
                            color: p.repeat == Repeat.off ? AppColors.text : AppColors.accent),
                        onPressed: p.cycleRepeat,
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      TextButton.icon(
                        icon: Icon(Icons.radio, color: p.radio ? AppColors.accent : AppColors.textDim),
                        label: Text(p.radio ? 'Радио вкл.' : 'Радио',
                            style: TextStyle(color: p.radio ? AppColors.accent : AppColors.textDim)),
                        onPressed: () => p.setRadio(!p.radio),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Текст песни',
                        icon: const Icon(Icons.lyrics_outlined, color: AppColors.textDim),
                        onPressed: () => showLyrics(context, t),
                      ),
                      IconButton(
                        tooltip: 'Эквалайзер',
                        icon: Icon(Icons.equalizer,
                            color: p.equalizer.enabled ? AppColors.accent : AppColors.textDim),
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage())),
                      ),
                      IconButton(
                        tooltip: 'Очередь',
                        icon: const Icon(Icons.queue_music, color: AppColors.textDim),
                        onPressed: () => showQueue(context),
                      ),
                    ]),
                    const SizedBox(height: 8),
                  ]),
                );
              }),
            ),
          ]),
        );
      },
    );
  }
}

/// Плашка «Найдена версия без цензуры — переключить?».
class ExplicitOffer extends StatelessWidget {
  final bool compact;
  const ExplicitOffer({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final alt = app.player.explicitAlternative;
    if (alt == null) return const SizedBox.shrink();
    return Container(
      margin: compact ? EdgeInsets.zero : const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(compact ? 0 : 8),
      ),
      child: Row(children: [
        const ExplicitBadge(),
        Expanded(
          child: Text('Есть версия без цензуры · ${sourceNames[alt.source] ?? alt.source}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
        ),
        TextButton(onPressed: app.player.switchToOriginal, child: const Text('Включить')),
        IconButton(
          icon: const Icon(Icons.close, size: 16),
          visualDensity: VisualDensity.compact,
          onPressed: app.player.dismissOriginal,
        ),
      ]),
    );
  }
}

/// Очередь воспроизведения.
void showQueue(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (ctx, scroll) => ListenableBuilder(
        listenable: app.player,
        builder: (ctx, _) {
          final q = app.player.queue;
          return Column(children: [
            SectionTitle(
              'Очередь',
              subtitle: app.player.radio ? 'Радио: похожие треки догружаются сами' : '${q.length} треков',
              trailing: app.player.radio
                  ? TextButton(onPressed: () => app.player.setRadio(false), child: const Text('Выключить радио'))
                  : null,
            ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemCount: q.length,
                itemBuilder: (ctx, i) => TrackTile(
                  track: q[i],
                  playing: i == app.player.index,
                  onTap: () => app.player.jumpTo(i),
                  onMenu: () => showTrackMenu(ctx, q[i]),
                ),
              ),
            ),
          ]);
        },
      ),
    ),
  );
}

class _SeekBar extends StatefulWidget {
  final AudioPlayer player;
  const _SeekBar({required this.player});
  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    // полторы-две перерисовки в секунду достаточно для плавного ползунка
    return PositionBuilder(
      player: widget.player,
      period: const Duration(milliseconds: 500),
      builder: (context, pos, total) {
        final max = total.inMilliseconds.toDouble();
        final value = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, max > 0 ? max : 1.0);
        final shown = _drag != null ? Duration(milliseconds: _drag!.round()) : pos;
        return Column(children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackShape: const RectangularSliderTrackShape(),
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              max: max > 0 ? max : 1.0,
              value: value,
              onChanged: max > 0 ? (v) => setState(() => _drag = v) : null,
              onChangeEnd: (v) {
                widget.player.seek(Duration(milliseconds: v.round()));
                setState(() => _drag = null);
              },
            ),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Text(fmtDuration(shown).isEmpty ? '0:00' : fmtDuration(shown),
                style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
            const Spacer(),
            Text(fmtDuration(total), style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
          ]),
        ]);
      },
    );
  }
}
