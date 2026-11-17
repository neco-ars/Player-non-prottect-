import 'package:shared_preferences/shared_preferences.dart';

class Settings {
  final SharedPreferences _prefs;
  Settings._(this._prefs);

  static Future<Settings> load() async => Settings._(await SharedPreferences.getInstance());

  String? _str(String k) => _prefs.getString(k);
  void _setStr(String k, String? v) => v == null || v.isEmpty ? _prefs.remove(k) : _prefs.setString(k, v);

  String? get yandexToken => _str('yandex_token');
  set yandexToken(String? v) => _setStr('yandex_token', v);

  String? get youtubeKey => _str('youtube_key');
  set youtubeKey(String? v) => _setStr('youtube_key', v);

  /// Токен своего аккаунта Звука (необязательно: без него работает гостевой доступ).
  String? get zvukToken => _str('zvuk_token');
  set zvukToken(String? v) => _setStr('zvuk_token', v);

  /// Ключи Audiomack Data API (выдаёт Audiomack по запросу).
  String? get audiomackKey => _str('audiomack_key');
  set audiomackKey(String? v) => _setStr('audiomack_key', v);
  String? get audiomackSecret => _str('audiomack_secret');
  set audiomackSecret(String? v) => _setStr('audiomack_secret', v);

  /// Выбирать версию без цензуры, когда она есть.
  bool get preferExplicit => _prefs.getBool('prefer_explicit') ?? true;
  set preferExplicit(bool v) => _prefs.setBool('prefer_explicit', v);

  /// Искать в фоне версию без цензуры для «чистых» треков.
  bool get findOriginal => _prefs.getBool('find_original') ?? true;
  set findOriginal(bool v) => _prefs.setBool('find_original', v);

  /// Адрес прокси для веб-версии (если не вшит при сборке).
  String? get proxyUrl => _str('proxy_url');
  set proxyUrl(String? v) => _setStr('proxy_url', v);
}
