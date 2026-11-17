import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/track.dart';
import '../sources/net.dart';
import 'library.dart';
import 'recommendations.dart';
import 'search_service.dart';

enum Repeat { off, all, one }

/// Плеер со своей очередью. Ссылки на потоки временные,
/// поэтому получаем их только перед воспроизведением конкретного трека.
/// Видео YouTube играет через официальный плеер: сервис только сообщает интерфейсу,
/// что надо его показать (videoRequests), и ждёт videoEnded().
class PlayerService extends ChangeNotifier {
  final SearchService search;
  final Library library;
  final Recommendations recs;
  final AudioPlayer player = AudioPlayer();

  List<Track> _queue = [];
  int _index = -1;
  String? error;
  bool loading = false;

  /// Радио: когда очередь заканчивается, догружаем похожие треки.
  bool radio = false;
  bool _extending = false;

  final _videoRequests = StreamController<Track>.broadcast();
  Stream<Track> get videoRequests => _videoRequests.stream;

  /// Повтор: выкл / вся очередь / один трек.
  Repeat repeat = Repeat.off;

  /// Перемешивание. Исходный порядок запоминаем, чтобы вернуть при выключении.
  bool shuffle = false;
  List<Track>? _unshuffled;

  /// Искать в фоне версию без цензуры, когда играет «чистая».
  bool findOriginal = true;

  /// Найденная версия без цензуры для текущего трека — интерфейс предлагает переключиться.
  Track? explicitAlternative;
  final Map<String, Track?> _originalCache = {};

  PlayerService(this.search, this.library, this.recs) {
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _onCompleted();
    });
  }

  Future<void> _onCompleted() async {
    if (repeat == Repeat.one) {
      await player.seek(Duration.zero);
      await player.play();
    } else {
      await next();
    }
  }

  void cycleRepeat() {
    repeat = Repeat.values[(repeat.index + 1) % Repeat.values.length];
    notifyListeners();
  }

  void toggleShuffle() {
    final cur = current;
    shuffle = !shuffle;
    if (shuffle) {
      _unshuffled = List.of(_queue);
      // текущий трек остаётся первым, остальные — вперемешку
      final rest = List.of(_queue)..remove(cur);
      rest.shuffle();
      _queue = [if (cur != null) cur, ...rest];
      _index = cur == null ? -1 : 0;
    } else if (_unshuffled != null) {
      // вернуть исходный порядок, сохранив треки, добавленные за это время
      final added = _queue.where((t) => !_unshuffled!.contains(t));
      _queue = [..._unshuffled!, ...added];
      _index = cur == null ? -1 : _queue.indexOf(cur);
      _unshuffled = null;
    }
    notifyListeners();
  }

  Track? get current => _index >= 0 && _index < _queue.length ? _queue[_index] : null;
  List<Track> get queue => List.unmodifiable(_queue);
  int get index => _index;
  bool get hasNext => _index + 1 < _queue.length || radio || (repeat == Repeat.all && _queue.isNotEmpty);
  bool get hasPrev => _index > 0;

  Future<void> playQueue(List<Track> tracks, int start, {bool radio = false, bool shuffled = false}) async {
    _queue = List.of(tracks);
    this.radio = radio;
    shuffle = false;
    _unshuffled = null;
    if (shuffled) {
      _index = start;
      toggleShuffle(); // выбранный трек первым, остальные вперемешку
      start = 0;
    }
    await _playAt(start);
  }

  /// Радио по треку: играем его, дальше — похожие.
  Future<void> startRadio(Track seed) async {
    await playQueue([seed], 0, radio: true);
    unawaited(_extendRadio());
  }

  void playNext(Track t) {
    if (current == null) {
      playQueue([t], 0);
      return;
    }
    _queue.insert(_index + 1, t);
    notifyListeners();
  }

  void addToQueue(Track t) {
    if (current == null) {
      playQueue([t], 0);
      return;
    }
    _queue.add(t);
    notifyListeners();
  }

  Future<void> next() async {
    if (_index + 1 >= _queue.length && radio) await _extendRadio();
    if (_index + 1 < _queue.length) {
      await _playAt(_index + 1);
    } else if (repeat == Repeat.all && _queue.isNotEmpty) {
      await _playAt(0);
    }
  }

  Future<void> previous() async {
    if (current?.isVideo != true && (player.position > const Duration(seconds: 3) || !hasPrev)) {
      await player.seek(Duration.zero);
    } else if (hasPrev) {
      await _playAt(_index - 1);
    }
  }

  void jumpTo(int i) => _playAt(i);

  void setRadio(bool on) {
    radio = on;
    notifyListeners();
    if (on) unawaited(_extendRadio());
  }

  /// Ищем ту же песню с пометкой explicit на других площадках (без YouTube — бережём лимит).
  Future<void> _lookForOriginal(Track t) async {
    if (!findOriginal || t.explicit || t.isVideo) return;
    Track? found;
    if (_originalCache.containsKey(t.matchKey)) {
      found = _originalCache[t.matchKey];
    } else {
      try {
        final r = await search.search('${t.artist} ${t.title}', includeVideo: false);
        for (final g in r.groups) {
          for (final v in g.variants) {
            if (v.matchKey == t.matchKey && v.explicit && !v.previewOnly && !v.isVideo && v != t) {
              found = v;
              break;
            }
          }
          if (found != null) break;
        }
      } catch (_) {}
      _originalCache[t.matchKey] = found;
    }
    if (found != null && current == t) {
      explicitAlternative = found;
      notifyListeners();
    }
  }

  /// Переключиться на найденную версию без цензуры.
  Future<void> switchToOriginal() async {
    final alt = explicitAlternative;
    if (alt == null || _index < 0) return;
    explicitAlternative = null;
    _queue[_index] = alt;
    await _playAt(_index);
  }

  void dismissOriginal() {
    explicitAlternative = null;
    notifyListeners();
  }

  /// Снова открыть текущий ролик YouTube (если его закрыли).
  void showVideo() {
    final t = current;
    if (t != null && t.isVideo) _videoRequests.add(t);
  }

  /// Официальный плеер YouTube сообщил, что ролик закончился.
  void videoEnded(Track t) {
    if (current == t) next();
  }

  Future<void> _extendRadio() async {
    if (_extending || _queue.isEmpty) return;
    _extending = true;
    try {
      final exclude = {for (final t in _queue) ...[t.key, t.matchKey]};
      final more = await recs.radioBatch(_queue.last, exclude);
      if (more.isNotEmpty) {
        _queue.addAll(more);
        notifyListeners();
      }
    } finally {
      _extending = false;
    }
  }

  Future<Track> _resolveFull(Track t) async {
    if (!t.previewOnly) return t;
    // для превью (SoundCloud Go+) ищем полную версию на других площадках
    return await _alternative(t) ?? t;
  }

  /// Та же песня на другой площадке (полная, не видео).
  Future<Track?> _alternative(Track t) async {
    final r = await search.search('${t.artist} ${t.title}');
    for (final g in r.groups) {
      for (final v in g.variants) {
        if (v.matchKey == t.matchKey && v.source != t.source && !v.previewOnly && !v.isVideo) return v;
      }
    }
    return null;
  }

  Future<void> _startAudio(Track t) async {
    final info = await search.sourceOf(t).streamUrl(t);
    if (current != t) return;
    // уведомление в шторке ведёт audio_handler.dart — он следит за current
    await player.setAudioSource(info.hls ? HlsAudioSource(info.url) : AudioSource.uri(info.url));
    unawaited(player.play());
  }

  Future<void> _playAt(int i) async {
    _index = i;
    loading = true;
    explicitAlternative = null;
    notifyListeners();
    var t = _queue[i];
    try {
      final full = await _resolveFull(t);
      if (current != t) return; // пользователь уже переключил трек
      if (full != t) _queue[i] = t = full;

      if (t.isVideo) {
        await player.stop();
        _videoRequests.add(t);
      } else {
        try {
          try {
            await _startAudio(t);
          } catch (e) {
            // временный сетевой сбой (оборванное соединение) — одна повторная попытка
            if (!Net.isTransient(e) || current != t) rethrow;
            await Future.delayed(const Duration(milliseconds: 800));
            if (current != t) return;
            await _startAudio(t);
          }
        } catch (e) {
          // поток не играет — пробуем ту же песню на другой площадке
          final failed = t;
          final alt = await _alternative(t);
          if (alt == null || current != t) rethrow;
          error = '«${failed.title}» (${search.sourceOf(failed).name}): ${_msg(e)}. '
              'Играю версию из ${search.sourceOf(alt).name}';
          _queue[i] = t = alt;
          await _startAudio(t);
        }
      }
      library.addHistory(t);
      if (radio && _queue.length - _index <= 2) unawaited(_extendRadio());
      unawaited(_lookForOriginal(t));
    } catch (e) {
      // ошибку оставляем видимой, даже когда переходим к следующему треку
      error = 'Пропущен «${t.title}» (${search.sourceOf(t).name}): ${_msg(e)}';
      debugPrint(error);
      if (_index + 1 < _queue.length || radio) {
        loading = false;
        notifyListeners();
        await Future.delayed(const Duration(seconds: 2));
        if (current == t) await next();
        return;
      }
    }
    loading = false;
    notifyListeners();
  }

  static String _msg(Object e) =>
      Net.describe(e).replaceFirst(RegExp(r'^PlayerException.*?\): '), '');

  void clearError() {
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _videoRequests.close();
    player.dispose();
    super.dispose();
  }
}
