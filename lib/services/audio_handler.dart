import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'player_service.dart';

/// Связывает наш плеер с системой: уведомление в шторке Android,
/// экран блокировки iPhone, кнопки наушников и Media Session в браузере.
/// Кнопки ⏮/⏭ переключают треки по НАШЕЙ очереди (включая радио).
class PlayerAudioHandler extends BaseAudioHandler with SeekHandler {
  final PlayerService svc;
  String? _lastKey;

  PlayerAudioHandler(this.svc) {
    svc.player.playbackEventStream.listen((_) => _broadcastState());
    svc.player.playingStream.listen((_) => _broadcastState());
    svc.addListener(_onTrackChanged);
  }

  void _onTrackChanged() {
    final t = svc.current;
    if (t == null || t.key == _lastKey) {
      _broadcastState(); // могли измениться hasNext/hasPrev
      return;
    }
    _lastKey = t.key;
    mediaItem.add(MediaItem(
      id: t.key,
      title: t.title,
      artist: t.artist,
      album: t.album,
      artUri: t.coverUrl == null ? null : Uri.parse(t.coverUrl!),
      duration: t.duration == Duration.zero ? null : t.duration,
    ));
    _broadcastState();
  }

  void _broadcastState() {
    final p = svc.player;
    final video = svc.current?.isVideo == true;
    final playing = !video && p.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (!video) playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: video ? const [0, 1] : const [0, 1, 2],
      processingState: video
          ? AudioProcessingState.ready
          : svc.loading
              ? AudioProcessingState.loading
              : const {
                  ProcessingState.idle: AudioProcessingState.idle,
                  ProcessingState.loading: AudioProcessingState.loading,
                  ProcessingState.buffering: AudioProcessingState.buffering,
                  ProcessingState.ready: AudioProcessingState.ready,
                  ProcessingState.completed: AudioProcessingState.completed,
                }[p.processingState]!,
      playing: playing,
      updatePosition: video ? Duration.zero : p.position,
      bufferedPosition: video ? Duration.zero : p.bufferedPosition,
      speed: p.speed,
    ));
  }

  @override
  Future<void> play() => svc.player.play();
  @override
  Future<void> pause() => svc.player.pause();
  @override
  Future<void> seek(Duration position) => svc.player.seek(position);
  @override
  Future<void> skipToNext() => svc.next();
  @override
  Future<void> skipToPrevious() => svc.previous();
  @override
  Future<void> stop() async {
    await svc.player.stop();
    await super.stop();
  }
}
