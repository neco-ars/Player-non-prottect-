import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// Позиция воспроизведения для интерфейса — экономно для батареи:
/// - обновляется не чаще [period] (а не ~5 раз в секунду, как по умолчанию);
/// - когда приложение свёрнуто или экран выключен, подписка снимается полностью,
///   и таймер плеера перестаёт будить телефон.
class PositionBuilder extends StatefulWidget {
  final AudioPlayer player;
  final Duration period;
  final Widget Function(BuildContext context, Duration position, Duration total) builder;
  const PositionBuilder({super.key, required this.player, required this.period, required this.builder});

  @override
  State<PositionBuilder> createState() => _PositionBuilderState();
}

class _PositionBuilderState extends State<PositionBuilder> {
  StreamSubscription<Duration>? _sub;
  late final AppLifecycleListener _lifecycle;
  Duration _pos = Duration.zero;

  @override
  void initState() {
    super.initState();
    _pos = widget.player.position;
    _lifecycle = AppLifecycleListener(onShow: _start, onResume: _start, onHide: _stop, onPause: _stop);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) _start();
  }

  void _start() {
    _sub ??= widget.player
        .createPositionStream(minPeriod: widget.period, maxPeriod: widget.period, steps: 1 << 20)
        .listen((p) {
      if (mounted && p != _pos) setState(() => _pos = p);
    });
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    _stop();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _pos, widget.player.duration ?? Duration.zero);
}
