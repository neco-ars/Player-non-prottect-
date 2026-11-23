import 'dart:convert';

import '../models/track.dart';
import '../sources/net.dart';

/// Исполнитель в «графе вкусов».
class TasteArtist {
  final int id;
  final String name;
  final String? picture;
  const TasteArtist(this.id, this.name, this.picture);
}

/// «Граф вкусов»: кто на кого похож и что играет в радио исполнителя.
///
/// Большие сервисы (Spotify, Яндекс Музыка) строят рекомендации по прослушиваниям миллионов людей.
/// Своих таких данных у нас нет, поэтому берём их из открытого API Deezer (без ключа и входа):
/// похожие исполнители, радио исполнителя, популярные треки и чарт. Отсюда приходят только
/// названия песен — играет трек всегда с наших площадок (см. [Recommendations.resolve]).
class TasteGraph {
  static const _base = 'https://api.deezer.com';

  /// Ответы держим час: похожие исполнители меняются редко, а радио дёргается часто.
  final Map<String, (DateTime, dynamic)> _cache = {};
  static const _ttl = Duration(hours: 1);

  /// Если Deezer недоступен (например, прокси веб-версии его не пропускает) —
  /// не дёргаем его на каждый трек, а 10 минут работаем без него.
  DateTime? _downUntil;
  bool get available => _downUntil == null || DateTime.now().isAfter(_downUntil!);

  Future<dynamic> _get(String path, [Map<String, String>? query]) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: query);
    final key = uri.toString();
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _ttl) return hit.$2;
    if (!available) throw Exception('Deezer недоступен');
    try {
      final r = await Net.client.get(Net.wrap(uri)).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) throw Exception('Deezer HTTP ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map && j['error'] != null) {
        // «нет данных» — обычный ответ, а не поломка
        final code = (j['error'] as Map)['code'];
        if (code == 800) return {'data': []};
        throw Exception('Deezer: ${(j['error'] as Map)['message']}');
      }
      _cache[key] = (DateTime.now(), j);
      if (_cache.length > 300) _cache.remove(_cache.keys.first);
      return j;
    } catch (e) {
      if (Net.isTransient(e) || '$e'.contains('Failed to fetch') || '$e'.contains('Load failed')) {
        _downUntil = DateTime.now().add(const Duration(minutes: 10));
      }
      rethrow;
    }
  }

  static String _compact(String s) => Track.normalize(s).replaceAll(' ', '');

  /// Исполнитель по имени. Берём только точное совпадение имени (без пробелов и регистра):
  /// иначе радио «Кино» превратилось бы в радио «Киноманов».
  Future<TasteArtist?> findArtist(String name) async {
    final want = _compact(name.split(RegExp(r',|&| feat\.? | ft\.? | x ', caseSensitive: false)).first);
    if (want.isEmpty) return null;
    final j = await _get('/search/artist', {'q': name, 'limit': '10'});
    for (final a in (j['data'] as List? ?? const [])) {
      if (_compact(a['name'] ?? '') == want) return _artist(a);
    }
    return null;
  }

  Future<List<TasteArtist>> related(int artistId) async {
    final j = await _get('/artist/$artistId/related', {'limit': '25'});
    return [for (final a in (j['data'] as List? ?? const [])) _artist(a)];
  }

  /// Радио исполнителя по версии Deezer: его песни вперемешку с похожими.
  Future<List<Track>> artistRadio(int artistId) async {
    final j = await _get('/artist/$artistId/radio', {'limit': '50'});
    return _tracks(j);
  }

  Future<List<Track>> artistTop(int artistId, {int limit = 10}) async {
    final j = await _get('/artist/$artistId/top', {'limit': '$limit'});
    return _tracks(j);
  }

  /// Популярное сейчас — для тех, у кого ещё нет истории.
  Future<List<Track>> chart() async => _tracks(await _get('/chart/0/tracks', {'limit': '50'}));

  static TasteArtist _artist(dynamic a) =>
      TasteArtist(a['id'] as int, a['name'] ?? '', a['picture_medium'] as String?);

  static List<Track> _tracks(dynamic j) => [
        for (final t in (j['data'] as List? ?? const []))
          if (t['readable'] != false && t['title'] != null && t['artist'] != null) hint(t),
      ];

  /// Трек-«подсказка»: только что за песня. Играет её версия с наших площадок.
  static Track hint(dynamic t) => Track(
        source: Track.pickSource,
        id: 'dz${t['id']}',
        title: t['title'] ?? '',
        artist: t['artist']['name'] ?? '',
        album: t['album']?['title'],
        coverUrl: t['album']?['cover_medium'] ?? t['album']?['cover'],
        duration: t['duration'] is int ? Duration(seconds: t['duration']) : null,
        explicit: t['explicit_lyrics'] == true,
        extra: {'artistDz': t['artist']['id']},
      );
}
