import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/track.dart';
import '../platform.dart';
import '../services/app_services.dart';
import '../sources/youtube.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'mini_player.dart';
import 'search_page.dart';
import 'video_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  late final StreamSubscription<Track> _videoSub;

  // У каждой вкладки своя история переходов — мини-плеер и вкладки остаются видны.
  final _navKeys = List.generate(3, (_) => GlobalKey<NavigatorState>());
  static const _roots = [HomePage(), SearchPage(), LibraryPage()];

  @override
  void initState() {
    super.initState();
    _videoSub = app.player.videoRequests.listen(_openVideo);
  }

  @override
  void dispose() {
    _videoSub.cancel();
    super.dispose();
  }

  Future<void> _openVideo(Track t) async {
    if (isMobile || isWeb) {
      final nav = Navigator.of(context, rootNavigator: true);
      // закрываем предыдущий ролик, если он ещё открыт
      nav.popUntil((r) => r.settings.name != VideoPage.routeName);
      await nav.push(MaterialPageRoute(
        settings: const RouteSettings(name: VideoPage.routeName),
        builder: (_) => VideoPage(track: t),
      ));
    } else {
      // на Windows встроенного плеера YouTube нет — открываем в браузере
      await launchUrl(YouTubeSource.watchUrl(t.id), mode: LaunchMode.externalApplication);
    }
  }

  void _select(int i) {
    if (i == _tab) {
      // повторное нажатие на вкладку — вернуться к её началу
      _navKeys[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = _navKeys[_tab].currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        } else if (_tab != 0) {
          setState(() => _tab = 0);
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            for (var i = 0; i < 3; i++)
              Navigator(
                key: _navKeys[i],
                onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _roots[i]),
              ),
          ],
        ),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _select,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_filled), label: 'Главная'),
              NavigationDestination(icon: Icon(Icons.search), selectedIcon: Icon(Icons.manage_search), label: 'Поиск'),
              NavigationDestination(
                  icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Медиатека'),
            ],
          ),
        ]),
      ),
    );
  }
}
