import '../models/track.dart';
import '../sources/source.dart';

class SearchResult {
  final List<TrackGroup> groups;
  final Map<String, String> errors; // имя источника -> текст ошибки
  SearchResult(this.groups, this.errors);
}

class SearchService {
  final List<MusicSource> sources;
  SearchService(this.sources);

  MusicSource sourceOf(Track t) => sources.firstWhere((s) => s.id == t.source);

  /// [includeVideo] = false — без YouTube (для фоновых поисков, чтобы не тратить лимит ключа).
  Future<SearchResult> search(String query, {bool includeVideo = true}) async {
    final errors = <String, String>{};
    final active = sources.where((s) => s.isConfigured && (includeVideo || s.id != 'youtube')).toList();
    final lists = await Future.wait(active.map((s) async {
      try {
        return await s.search(query).timeout(const Duration(seconds: 15));
      } catch (e) {
        errors[s.name] = '$e'.replaceFirst('Exception: ', '');
        return <Track>[];
      }
    }));

    // Объединяем версии одной песни из разных источников.
    // Порядок групп: по первому появлению, источники чередуются, чтобы ни один не забивал выдачу.
    final groups = <String, List<Track>>{};
    final maxLen = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < maxLen; i++) {
      for (final list in lists) {
        if (i < list.length) groups.putIfAbsent(list[i].matchKey, () => []).add(list[i]);
      }
    }
    return SearchResult(groups.values.map((v) => TrackGroup(v)).toList(), errors);
  }
}
