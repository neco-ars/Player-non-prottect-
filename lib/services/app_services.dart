import '../models/track.dart';
import '../sources/audiomack.dart';
import '../sources/local.dart';
import '../sources/net.dart';
import '../sources/soundcloud.dart';
import '../sources/zvuk.dart';
import '../sources/youtube.dart';
import 'catalog.dart';
import 'equalizer.dart';
import 'library.dart';
import 'genius.dart';
import 'keys.dart';
import 'lyrics.dart';
import 'player_service.dart';
import 'recommendations.dart';
import 'search_service.dart';
import 'settings.dart';
import 'sync.dart';
import 'tags.dart';

/// Все сервисы приложения в одном месте.
class AppServices {
  final Settings settings;
  final Library library;
  final YouTubeSource youtube;
  final AudiomackSource audiomack;
  final ZvukSource zvuk;
  final LocalSource local;
  final SearchService search;
  final Recommendations recs;
  final PlayerService player;
  final CatalogService catalog;
  final LyricsService lyrics = LyricsService();
  final GeniusService genius;
  final SyncService sync;
  TagService get tags => recs.tags;

  AppServices._(this.settings, this.library, this.youtube, this.audiomack, this.zvuk, this.local,
      this.search, this.recs, this.player, this.catalog, this.genius, this.sync);

  static Future<AppServices> init() async {
    final settings = await Settings.load();
    Net.userProxy = settings.proxyUrl;
    final library = await Library.load();
    final youtube = YouTubeSource(AppKeys.pick(settings.youtubeKey, AppKeys.youtube));
    final local = LocalSource();
    await local.load();
    final audiomack = AudiomackSource(
        consumerKey: AppKeys.pick(settings.audiomackKey, AppKeys.audiomackKey),
        consumerSecret: AppKeys.pick(settings.audiomackSecret, AppKeys.audiomackSecret));
    final zvuk = ZvukSource(settings.zvukToken);
    final search = SearchService([local, zvuk, SoundCloudSource(), audiomack, youtube]);
    final catalog = CatalogService(search);
    final recs = Recommendations(search, library, catalog, tags: TagService(zvuk: zvuk));
    final equalizer = EqualizerService();
    await equalizer.load();
    final player = PlayerService(search, library, recs, equalizer);
    await player.loadVolume();
    TrackGroup.preferExplicitDefault(settings.preferExplicit);
    player.findOriginal = settings.findOriginal;
    final sync = SyncService(library);
    await sync.init();
    return AppServices._(settings, library, youtube, audiomack, zvuk, local, search, recs, player, catalog,
        GeniusService(AppKeys.pick(settings.geniusToken, AppKeys.genius)), sync);
  }
}

late final AppServices app;
