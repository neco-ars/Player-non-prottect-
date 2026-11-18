import 'dart:async';

import '../models/track.dart';
import '../sources/net.dart';
import '../sources/source.dart';

class SearchResult {
  final List<TrackGroup> groups;
  final Map<String, String> errors; // имя источника -> текст ошибки

  /// Ещё не ответившие площадки (пока поиск идёт).
  final List<String> pending;
  SearchResult(this.groups, this.errors, {this.pending = const []});

  bool get done => pending.isEmpty;
}

class SearchService {
  final List<MusicSource> sources;
  SearchService(this.sources);

  /// Сколько ждать одну площадку. Остальные результаты показываются, не дожидаясь её.
  static const timeout = Duration(seconds: 10);

  /// Последние результаты поиска: повторный запрос (вернулся на вкладку, «искать оригинал»,
  /// радио, переход к альбому) не идёт в сеть заново.
  final Map<String, (DateTime, SearchResult)> _cache = {};
  static const _cacheTtl = Duration(minutes: 10);

  MusicSource sourceOf(Track t) => sources.firstWhere((s) => s.id == t.source);

  /// Поиск с результатами по мере ответа площадок: каждое событие — уже объединённая выдача
  /// от тех, кто ответил. Последнее событие (pending пуст) — окончательный результат.
  /// [includeVideo] = false — без YouTube (для фоновых поисков, чтобы не тратить лимит ключа).
  Stream<SearchResult> searchStream(String query, {bool includeVideo = true}) {
    final key = '${includeVideo ? 1 : 0}|${query.trim().toLowerCase()}';
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _cacheTtl) return Stream.value(hit.$2);

    final active = sources.where((s) => s.isConfigured && (includeVideo || s.id != 'youtube')).toList();
    final ctrl = StreamController<SearchResult>();
    final lists = List<List<Track>?>.filled(active.length, null);
    final errors = <String, String>{};

    void emit() {
      final pending = [for (var i = 0; i < active.length; i++) if (lists[i] == null) active[i].name];
      ctrl.add(SearchResult(_group(lists.whereType<List<Track>>().toList()), Map.of(errors), pending: pending));
      if (pending.isEmpty) ctrl.close();
    }

    if (active.isEmpty) {
      ctrl.add(SearchResult(const [], const {}));
      ctrl.close();
      return ctrl.stream;
    }
    for (var i = 0; i < active.length; i++) {
      final s = active[i];
      s.search(query).timeout(timeout).then((r) => lists[i] = r, onError: (Object e) {
        errors[s.name] = Net.describe(e);
        lists[i] = const [];
      }).whenComplete(emit);
    }
    // окончательный результат без ошибок запоминаем
    return ctrl.stream.map((r) {
      if (r.done && r.errors.isEmpty) {
        _cache[key] = (DateTime.now(), r);
        if (_cache.length > 40) _cache.remove(_cache.keys.first);
      }
      return r;
    });
  }

  /// Окончательный результат (для фоновых поисков).
  Future<SearchResult> search(String query, {bool includeVideo = true}) =>
      searchStream(query, includeVideo: includeVideo).last;

  /// Объединяем версии одной песни из разных источников.
  /// Порядок групп: по первому появлению, источники чередуются, чтобы ни один не забивал выдачу.
  static List<TrackGroup> _group(List<List<Track>> lists) {
    final groups = <String, List<Track>>{};
    final maxLen = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < maxLen; i++) {
      for (final list in lists) {
        if (i < list.length) groups.putIfAbsent(list[i].matchKey, () => []).add(list[i]);
      }
    }
    return groups.values.map((v) => TrackGroup(v)).toList();
  }
}
