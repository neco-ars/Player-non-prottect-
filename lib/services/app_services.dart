import '../models/track.dart';
import '../sources/audiomack.dart';
import '../sources/audius.dart';
import '../sources/local.dart';
import '../sources/net.dart';
import '../sources/soundcloud.dart';
import '../sources/yandex.dart';
import '../sources/zvuk.dart';
import '../sources/youtube.dart';
import 'catalog.dart';
import 'equalizer.dart';
import 'library.dart';
import 'lyrics.dart';
import 'player_service.dart';
import 'recommendations.dart';
import 'search_service.dart';
import 'settings.dart';

/// Все сервисы приложения в одном месте.
class AppServices {
  final Settings settings;
  final Library library;
  final YandexSource yandex;
  final YouTubeSource youtube;
  final AudiusSource audius;
  final AudiomackSource audiomack;
  final ZvukSource zvuk;
  final LocalSource local;
  final SearchService search;
  final Recommendations recs;
  final PlayerService player;
  final CatalogService catalog;
  final LyricsService lyrics = LyricsService();

  AppServices._(this.settings, this.library, this.yandex, this.youtube, this.audius, this.audiomack, this.zvuk, this.local,
      this.search, this.recs, this.player, this.catalog);

  static Future<AppServices> init() async {
    final settings = await Settings.load();
    Net.userProxy = settings.proxyUrl;
    final library = await Library.load();
    final yandex = YandexSource(settings.yandexToken);
    final youtube = YouTubeSource(settings.youtubeKey);
    final audius = AudiusSource();
    final local = LocalSource();
    await local.load();
    final audiomack = AudiomackSource(consumerKey: settings.audiomackKey, consumerSecret: settings.audiomackSecret);
    final zvuk = ZvukSource(settings.zvukToken);
    final search = SearchService([local, yandex, zvuk, SoundCloudSource(), audiomack, audius, youtube]);
    final catalog = CatalogService(search);
    final recs = Recommendations(search, library, yandex, audius, catalog);
    final equalizer = EqualizerService();
    await equalizer.load();
    final player = PlayerService(search, library, recs, equalizer);
    TrackGroup.preferExplicitDefault(settings.preferExplicit);
    player.findOriginal = settings.findOriginal;
    return AppServices._(
        settings, library, yandex, youtube, audius, audiomack, zvuk, local, search, recs, player, catalog);
  }
}

late final AppServices app;
