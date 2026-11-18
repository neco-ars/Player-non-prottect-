import 'dart:async';

import '../models/track.dart';
import 'catalog.dart';
import 'search_service.dart';

/// Строка списка, разобранная на исполнителя и название.
class ImportLine {
  final String raw;
  final String artist;
  final String title;
  const ImportLine(this.raw, this.artist, this.title);
}

enum ImportStatus { waiting, searching, found, notFound }

class ImportItem {
  final ImportLine line;
  ImportStatus status = ImportStatus.waiting;
  Track? track;
  ImportItem(this.line);
}

/// Импорт плейлиста из текста: «Исполнитель — Песня» по строке, или таблица CSV.
class PlaylistImporter {
  final SearchService search;
  PlaylistImporter(this.search);

  static final _dash = RegExp(r'\s+[-–—]\s+|\s*[–—]\s*');

  /// Разбор текста. Понимает:
  /// - «Исполнитель - Песня», «Исполнитель — Песня», «Исполнитель – Песня»;
  /// - нумерацию «1.», «01)», «#3», маркеры «•», «-» в начале;
  /// - длительность в конце («3:45», «(03:45)»);
  /// - CSV с заголовком, где есть колонки названия и исполнителя (Track/Title/Name/Название, Artist/Исполнитель).
  static List<ImportLine> parse(String text) {
    final rows = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (rows.isEmpty) return [];
    final csv = _parseCsv(rows);
    if (csv != null) return csv;
    return rows.map(_parseLine).whereType<ImportLine>().toList();
  }

  static ImportLine? _parseLine(String raw) {
    var s = raw
        .replaceFirst(RegExp(r'^\s*(?:#?\d{1,4}[.)\]:]?\s+|[•·*\-–—]\s+)'), '') // нумерация и маркеры
        .replaceFirst(RegExp(r'\s*[\(\[]?\d{1,2}:\d{2}(?::\d{2})?[\)\]]?\s*$'), '') // длительность в конце
        .replaceAll(RegExp(r'^["«“]+|["»”]+$'), '')
        .trim();
    if (s.isEmpty) return null;
    final m = _dash.firstMatch(s);
    if (m == null || m.start == 0) return ImportLine(raw, '', s); // только название
    final artist = s.substring(0, m.start).trim();
    final title = s.substring(m.end).trim();
    if (title.isEmpty) return ImportLine(raw, '', artist);
    return ImportLine(raw, artist, title);
  }

  /// CSV с заголовком (как выгружают сервисы переноса плейлистов).
  static List<ImportLine>? _parseCsv(List<String> rows) {
    if (rows.length < 2) return null;
    final sep = rows.first.contains('\t') ? '\t' : (rows.first.contains(';') ? ';' : ',');
    final header = _splitCsv(rows.first, sep).map((h) => h.toLowerCase().trim()).toList();
    int col(List<String> names) => header.indexWhere((h) => names.any(h.contains));
    final ti = col(['track name', 'track', 'title', 'song', 'name', 'назван', 'трек', 'песня']);
    final ai = col(['artist', 'исполнит', 'артист']);
    if (ti < 0 || ai < 0 || ti == ai) return null;
    final out = <ImportLine>[];
    for (final r in rows.skip(1)) {
      final cells = _splitCsv(r, sep);
      if (cells.length <= ti || cells.length <= ai) continue;
      final title = cells[ti].trim(), artist = cells[ai].trim();
      if (title.isEmpty) continue;
      out.add(ImportLine(r, artist, title));
    }
    return out.isEmpty ? null : out;
  }

  /// Деление строки CSV с учётом кавычек.
  static List<String> _splitCsv(String line, String sep) {
    final out = <String>[];
    final cur = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          cur.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (c == sep && !quoted) {
        out.add(cur.toString());
        cur.clear();
      } else {
        cur.write(c);
      }
    }
    out.add(cur.toString());
    return out;
  }

  /// Найти лучшую версию песни. Нужно совпадение и названия, и исполнителя (если он указан),
  /// иначе лучше «не найдено», чем чужая песня в плейлисте.
  Future<Track?> find(ImportLine l) async {
    final probe = Track(source: 'import', id: '', title: l.title, artist: l.artist);
    final (artists, title) = CatalogService.matchKeys(probe);
    for (final withVideo in [false, true]) {
      // сначала аудиоплощадки; YouTube — только если больше негде
      final r = await search.search('${l.artist} ${l.title}'.trim(), includeVideo: withVideo);
      for (final g in r.groups) {
        final candidates = g.variants.where((v) =>
            artists.isEmpty ? Track.normalize(v.title) == title : CatalogService.sameSong(v, artists, title));
        if (candidates.isEmpty) continue;
        // лучшая версия группы (explicit, полная, не видео), но только из подходящих
        final best = TrackGroup(candidates.toList()).main;
        if (!best.previewOnly) return best;
      }
    }
    return null;
  }

  /// Ищем все строки, по [parallel] одновременно; [onUpdate] — после каждой строки.
  Future<void> run(List<ImportItem> items, {int parallel = 3, required void Function() onUpdate, bool Function()? cancelled}) async {
    var next = 0;
    Future<void> worker() async {
      while (next < items.length && !(cancelled?.call() ?? false)) {
        final item = items[next++];
        item.status = ImportStatus.searching;
        onUpdate();
        try {
          item.track = await find(item.line).timeout(const Duration(seconds: 40));
        } catch (_) {
          item.track = null;
        }
        item.status = item.track == null ? ImportStatus.notFound : ImportStatus.found;
        onUpdate();
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
  }
}
