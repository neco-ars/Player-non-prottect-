import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import '../sources/net.dart';
import '../sources/source.dart' show StreamInfo;
import 'equalizer.dart';
import 'library.dart';
import 'recommendations.dart';
import 'search_service.dart';

enum Repeat { off, all, one }

/// Площадка вместо полного трека отдала короткий фрагмент.
class PreviewOnlyStream implements Exception {
  final String source;
  const PreviewOnlyStream(this.source);
  @override
  String toString() => source == 'zvuk'
      ? 'Звук отдал только 30-секундный фрагмент — войди в свой аккаунт Звука в ⚙ Настройках'
      : 'площадка отдала только короткий фрагмент';
}

/// Плеер со своей очередью. Ссылки на потоки временные,
/// поэтому получаем их только перед воспроизведением конкретного трека.
/// Видео YouTube играет через официальный плеер: сервис только сообщает интерфейсу,
/// что надо его показать (videoRequests), и ждёт videoEnded().
class PlayerService extends ChangeNotifier {
  final SearchService search;
  final Library library;
  final Recommendations recs;
  final EqualizerService equalizer;

  /// Плеер со звуковым трактом, в который на Android включён эквалайзер.
  late final AudioPlayer player = AudioPlayer(audioPipeline: equalizer.pipeline);

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

  // ---------- воспроизведение без пауз ----------
  // Плеер держит плейлист из двух элементов: текущий трек и заранее подготовленный следующий.
  // Когда текущий заканчивается, плеер сам переходит на следующий — он уже буферизован.
  ConcatenatingAudioSource? _playlist;
  Track? _preloaded; // трек, который лежит в плейлисте вторым
  int _preloadedIndex = -1; // его место в нашей очереди
  bool _preloading = false;
  Timer? _preloadTimer;

  /// За сколько до конца трека начинать готовить следующий.
  static const _preloadAhead = Duration(seconds: 90);

  /// Ссылки на потоки живут недолго — держим их несколько минут (повтор, «назад», предзагрузка).
  final Map<String, (DateTime, StreamInfo)> _urlCache = {};

  PlayerService(this.search, this.library, this.recs, this.equalizer) {
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _onCompleted();
    });
    player.currentIndexStream.listen(_onIndexChanged);
    player.playingStream.listen((playing) => playing ? _armPreload() : _preloadTimer?.cancel());
  }

  Future<void> _onCompleted() async {
    // сюда попадаем, только если следующий не был подготовлен заранее
    await next();
  }

  void cycleRepeat() {
    repeat = Repeat.values[(repeat.index + 1) % Repeat.values.length];
    // повтор одного трека — средствами плеера; следующий в этом режиме не готовим
    player.setLoopMode(repeat == Repeat.one ? LoopMode.one : LoopMode.off);
    if (repeat == Repeat.one) _dropPreload();
    notifyListeners();
  }

  /// Проверяем раз в 15 секунд, пока играет: не пора ли готовить следующий трек.
  void _armPreload() {
    _preloadTimer?.cancel();
    _preloadTimer = Timer.periodic(const Duration(seconds: 15), (_) => _maybePreload());
    _maybePreload();
  }

  void _maybePreload() {
    final dur = player.duration;
    if (dur == null || current == null || current!.isVideo) return;
    if (dur - player.position <= _preloadAhead) unawaited(_preloadNext());
  }

  int? get _nextIndex {
    if (repeat == Repeat.one) return null;
    if (_index + 1 < _queue.length) return _index + 1;
    if (repeat == Repeat.all && _queue.isNotEmpty) return 0;
    return null;
  }

  Future<StreamInfo> _stream(Track t) async {
    final cached = _urlCache[t.key];
    if (cached != null && DateTime.now().difference(cached.$1) < const Duration(minutes: 4)) return cached.$2;
    final info = await search.sourceOf(t).streamUrl(t);
    _urlCache[t.key] = (DateTime.now(), info);
    if (_urlCache.length > 30) _urlCache.remove(_urlCache.keys.first);
    return info;
  }

  static AudioSource _source(StreamInfo info) => info.hls ? HlsAudioSource(info.url) : AudioSource.uri(info.url);

  /// Готовим следующий трек: получаем ссылку и кладём в плейлист вторым — плеер начнёт буферизацию.
  Future<void> _preloadNext() async {
    if (_preloading || _preloaded != null || _playlist == null) return;
    if (radio && _index + 1 >= _queue.length) await _extendRadio();
    final ni = _nextIndex;
    if (ni == null) return;
    final t = _queue[ni];
    if (t.isVideo || t.previewOnly) return; // видео и превью — обычным путём
    _preloading = true;
    final cur = current;
    try {
      final info = await _stream(t);
      // пока ждали, могли переключить трек или поменять очередь
      if (current != cur || _playlist == null || _preloaded != null || _nextIndex != ni || _queue[ni] != t) return;
      await _playlist!.add(_source(info));
      _preloaded = t;
      _preloadedIndex = ni;
    } catch (e) {
      debugPrint('Не удалось заранее подготовить «${t.title}»: $e');
    } finally {
      _preloading = false;
    }
  }

  /// Убрать подготовленный следующий трек (очередь поменялась).
  void _dropPreload() {
    final pl = _playlist;
    if (pl != null && pl.length > 1) {
      unawaited(pl.removeRange(1, pl.length));
    }
    _preloaded = null;
    _preloadedIndex = -1;
  }

  /// Плеер сам перешёл на подготовленный следующий трек.
  Future<void> _onIndexChanged(int? idx) async {
    if (idx != 1 || _preloaded == null) return;
    final t = _preloaded!;
    _index = _preloadedIndex;
    _preloaded = null;
    _preloadedIndex = -1;
    error = null;
    explicitAlternative = null;
    // предыдущий трек из плейлиста убираем — текущий становится первым
    await _playlist?.removeAt(0);
    notifyListeners();

    // та же проверка на 30-секундный фрагмент, что и при обычном запуске
    final loaded = player.duration;
    final expected = t.duration ?? Duration.zero;
    if (loaded != null && loaded > Duration.zero && loaded <= const Duration(seconds: 45) && expected >= const Duration(seconds: 75)) {
      await _playAt(_index);
      return;
    }
    library.addHistory(t);
    if (radio && _queue.length - _index <= 2) unawaited(_extendRadio());
    unawaited(_lookForOriginal(t));
    _maybePreload();
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
    _dropPreload();
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
    _dropPreload();
    notifyListeners();
  }

  void addToQueue(Track t) {
    if (current == null) {
      playQueue([t], 0);
      return;
    }
    _queue.add(t);
    _dropPreload();
    notifyListeners();
  }

  Future<void> next() async {
    // следующий уже подготовлен — переключаемся мгновенно
    if (_preloaded != null && _preloadedIndex == _nextIndex && player.hasNext) {
      await player.seekToNext();
      return;
    }
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

  // ---------- громкость (на ПК и в браузере; на телефоне — кнопками телефона) ----------
  double volume = 1;
  bool get muted => volume == 0;
  double _beforeMute = 1;

  Future<void> loadVolume() async {
    final p = await SharedPreferences.getInstance();
    volume = (p.getDouble('volume') ?? 1).clamp(0.0, 1.0);
    await player.setVolume(volume);
  }

  Future<void> setVolume(double v) async {
    volume = v.clamp(0.0, 1.0);
    if (volume > 0) _beforeMute = volume;
    await player.setVolume(volume);
    notifyListeners();
    (await SharedPreferences.getInstance()).setDouble('volume', volume);
  }

  Future<void> toggleMute() => setVolume(muted ? (_beforeMute > 0 ? _beforeMute : 0.5) : 0);

  /// Свайп вправо: сразу предыдущий трек (а не перемотка в начало, как у кнопки ⏮).
  Future<void> previousTrack() async {
    if (hasPrev) {
      await _playAt(_index - 1);
    } else {
      await player.seek(Duration.zero);
    }
  }

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
    final info = await _stream(t);
    if (current != t) return;
    // уведомление в шторке ведёт audio_handler.dart — он следит за current.
    // Плейлист без «ленивой» подготовки: следующий трек, когда его добавим, сразу начнёт буферизоваться.
    _preloaded = null;
    _preloadedIndex = -1;
    _playlist = ConcatenatingAudioSource(useLazyPreparation: false, children: [_source(info)]);
    final Duration? loaded;
    try {
      loaded = await player.setAudioSource(_playlist!);
    } catch (e) {
      _urlCache.remove(t.key); // ссылка могла протухнуть — в следующий раз возьмём свежую
      rethrow;
    }
    // Площадка отдала ~30-секундный фрагмент вместо полного трека (например, гостевой доступ Звука):
    // не играем его, а ищем полную версию на других площадках.
    final expected = t.duration ?? Duration.zero;
    if (loaded != null &&
        loaded > Duration.zero &&
        loaded <= const Duration(seconds: 45) &&
        expected >= const Duration(seconds: 75)) {
      await player.stop();
      throw PreviewOnlyStream(search.sourceOf(t).id);
    }
    unawaited(player.play());
    unawaited(equalizer.attach()); // полосы эквалайзера доступны, только когда есть звук
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
    _preloadTimer?.cancel();
    _videoRequests.close();
    player.dispose();
    super.dispose();
  }
}
