import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'platform.dart';
import 'services/app_services.dart';
import 'services/audio_handler.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) JustAudioMediaKit.ensureInitialized(windows: true, linux: true);

  app = await AppServices.init();
  // свайпы по обложке и мини-плееру
  skipHandlers
    ..next = app.player.next
    ..previous = app.player.previousTrack;

  if (isMobile || isWeb) {
    // плеер в шторке уведомлений / на экране блокировки с кнопками ⏮ ⏯ ⏭
    try {
      await AudioService.init(
        builder: () => PlayerAudioHandler(app.player),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'music_player.playback',
          androidNotificationChannelName: 'Воспроизведение',
          androidNotificationIcon: 'mipmap/ic_launcher',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
    } catch (e) {
      debugPrint('Системный плеер недоступен: $e');
    }
  }
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Player',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: buildTheme(),
      theme: buildTheme(),
      home: const HomeShell(),
    );
  }
}
