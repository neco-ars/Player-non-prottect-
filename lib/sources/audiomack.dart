import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/track.dart';
import 'net.dart';
import 'source.dart';

/// Audiomack — площадка, куда артисты сами загружают музыку; много рэпа в оригинальных версиях.
/// Официальный Data API (https://audiomack.com/data-api/docs) работает по OAuth 1.0a:
/// нужны consumer key и secret, которые Audiomack выдаёт разработчикам по запросу.
/// Для поиска и воспроизведения вход пользователя не нужен — подписываем запросы ключами приложения.
class AudiomackSource extends MusicSource {
  static const _base = 'https://api.audiomack.com/v1';

  String? consumerKey;
  String? consumerSecret;
  AudiomackSource({this.consumerKey, this.consumerSecret});

  @override
  String get id => 'audiomack';
  @override
  String get name => 'Audiomack';
  @override
  bool get isConfigured =>
      (consumerKey?.isNotEmpty ?? false) && (consumerSecret?.isNotEmpty ?? false) && !Net.proxyMissing;

  // ---------- OAuth 1.0a (подпись HMAC-SHA1 только ключами приложения) ----------

  /// Процентное кодирование по RFC 3986 (Uri.encodeComponent оставляет !'()* как есть).
  static String pct(String s) => Uri.encodeComponent(s)
      .replaceAll('!', '%21')
      .replaceAll("'", '%27')
      .replaceAll('(', '%28')
      .replaceAll(')', '%29')
      .replaceAll('*', '%2A');

  /// Заголовок Authorization для запроса. [params] — параметры запроса и тела (form).
  static String oauthHeader({
    required String method,
    required String url,
    required Map<String, String> params,
    required String consumerKey,
    required String consumerSecret,
    String? nonce,
    String? timestamp,
  }) {
    final oauth = {
      'oauth_consumer_key': consumerKey,
      'oauth_nonce': nonce ?? _nonce(),
      'oauth_signature_method': 'HMAC-SHA1',
      'oauth_timestamp': timestamp ?? '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'oauth_version': '1.0',
    };
    final all = {...params, ...oauth}.entries.map((e) => MapEntry(pct(e.key), pct(e.value))).toList()
      ..sort((a, b) => a.key == b.key ? a.value.compareTo(b.value) : a.key.compareTo(b.key));
    final paramString = all.map((e) => '${e.key}=${e.value}').join('&');
    final baseString = '${method.toUpperCase()}&${pct(url)}&${pct(paramString)}';
    final key = '${pct(consumerSecret)}&'; // токена пользователя нет — вторая часть ключа пустая
    final sig = base64.encode(Hmac(sha1, utf8.encode(key)).convert(utf8.encode(baseString)).bytes);
    final header = {...oauth, 'oauth_signature': sig};
    return 'OAuth ${header.entries.map((e) => '${pct(e.key)}="${pct(e.value)}"').join(', ')}';
  }

  static String _nonce() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<http.Response> _request(String method, String path, Map<String, String> params) async {
    final url = '$_base$path';
    final auth = oauthHeader(
      method: method,
      url: url,
      params: params,
      consumerKey: consumerKey!,
      consumerSecret: consumerSecret!,
    );
    final headers = {'Authorization': auth};
    final res = method == 'GET'
        ? await http.get(Net.wrap(Uri.parse(url).replace(queryParameters: params.isEmpty ? null : params)),
            headers: headers)
        : await http.post(Net.wrap(Uri.parse(url)),
            headers: {...headers, 'Content-Type': 'application/x-www-form-urlencoded'}, body: params);
    if (res.statusCode == 401) throw Exception('Audiomack: ключи не подошли (401)');
    if (res.statusCode == 429) throw Exception('Audiomack: слишком много запросов, попробуй позже');
    if (res.statusCode >= 400) throw Exception('Audiomack: HTTP ${res.statusCode}');
    return res;
  }

  // ---------- поиск и воспроизведение ----------

  Track? _parse(Map j) {
    if (j['type'] != null && j['type'] != 'song') return null;
    if (j['status'] != null && j['status'] != 'complete') return null;
    final title = '${j['title'] ?? ''}';
    final featuring = '${j['featuring'] ?? ''}'.trim();
    final secs = int.tryParse('${j['duration'] ?? ''}');
    final uploaded = int.tryParse('${j['released'] ?? j['uploaded'] ?? ''}');
    return Track(
      source: id,
      id: '${j['id']}',
      title: featuring.isEmpty ? title : '$title (feat. $featuring)',
      artist: '${j['artist'] ?? (j['uploader'] as Map?)?['name'] ?? ''}',
      album: (j['album'] as String?)?.isNotEmpty == true ? j['album'] : null,
      genre: (j['genre'] as String?)?.isNotEmpty == true ? j['genre'] : null,
      year: uploaded == null ? null : DateTime.fromMillisecondsSinceEpoch(uploaded * 1000).year,
      coverUrl: j['image'] as String?,
      duration: secs == null ? null : Duration(seconds: secs),
      explicit: j['explicit'] == true || '${j['explicit']}' == '1' || Track.explicitTags.hasMatch('$title ${j['description'] ?? ''}'),
      extra: {if (j['url_slug'] != null) 'slug': j['url_slug']},
    );
  }

  @override
  Future<List<Track>> search(String query) async {
    final res = await _request('GET', '/search', {'q': query, 'show': 'songs', 'limit': '20'});
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final list = body is Map ? (body['results'] ?? body['songs'] ?? []) : body;
    return (list as List).whereType<Map>().map(_parse).whereType<Track>().toList();
  }

  @override
  Future<StreamInfo> streamUrl(Track track) async {
    final res = await _request('POST', '/music/${track.id}/play', {'hq': 'true'});
    final text = utf8.decode(res.bodyBytes).trim();
    // по документации возвращается ссылка на поток; на всякий случай понимаем и JSON
    if (text.startsWith('http')) return StreamInfo(Uri.parse(text));
    final j = jsonDecode(text);
    final url = j is Map ? (j['signedUrl'] ?? j['url'] ?? j['streaming_url']) : (j is String ? j : null);
    if (url is! String || !url.startsWith('http')) throw Exception('Audiomack: не удалось получить поток');
    return StreamInfo(Uri.parse(url));
  }
}
