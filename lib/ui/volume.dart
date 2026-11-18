import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../platform.dart';
import '../services/app_services.dart';
import 'theme.dart';

/// Громкость нужна на ПК и в браузере; на телефоне её регулируют кнопки телефона.
bool get showVolume => isDesktop || isWeb;

/// 🔇 + ползунок громкости. Колесо мыши над ползунком тоже меняет громкость.
class VolumeControl extends StatelessWidget {
  final double? width;
  const VolumeControl({super.key, this.width});

  @override
  Widget build(BuildContext context) {
    final p = app.player;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final v = p.volume;
        final icon = v == 0
            ? Icons.volume_off
            : v < 0.4
                ? Icons.volume_mute
                : v < 0.75
                    ? Icons.volume_down
                    : Icons.volume_up;
        final slider = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: SliderComponentShape.noOverlay,
            activeTrackColor: AppColors.text,
          ),
          child: Listener(
            // колесо мыши: шаг 5%
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) p.setVolume(p.volume + (e.scrollDelta.dy < 0 ? 0.05 : -0.05));
            },
            child: Slider(value: v, onChanged: p.setVolume),
          ),
        );
        return Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: v == 0 ? 'Включить звук' : 'Выключить звук',
            icon: Icon(icon, size: 20, color: AppColors.textDim),
            onPressed: p.toggleMute,
          ),
          if (width != null) SizedBox(width: width, child: slider) else Expanded(child: slider),
        ]);
      },
    );
  }
}
