import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform.dart';

/// Готовая настройка эквалайзера: усиление (дБ) в зависимости от частоты полосы.
class EqPreset {
  final String name;
  final double Function(double hz) curve;
  const EqPreset(this.name, this.curve);
}

/// Эквалайзер — системный эквалайзер Android (через just_audio).
/// На iPhone, в браузере и на Windows недоступен: там плеер не даёт к нему доступа.
class EqualizerService extends ChangeNotifier {
  final AndroidEqualizer? android = isAndroid ? AndroidEqualizer() : null;

  bool get supported => android != null;

  bool enabled = false;
  AndroidEqualizerParameters? params;
  String preset = 'Ровно';
  List<double> _savedGains = const [];

  static final presets = <EqPreset>[
    EqPreset('Ровно', (_) => 0),
    EqPreset('Бас', (hz) => hz < 150 ? 6 : hz < 400 ? 4 : hz < 1000 ? 1 : 0),
    EqPreset('Супер-бас', (hz) => hz < 150 ? 9 : hz < 400 ? 6 : hz < 1000 ? 1 : -1),
    EqPreset('Рэп', (hz) => hz < 150 ? 5 : hz < 400 ? 3 : hz < 2000 ? 0 : hz < 6000 ? 2 : 3),
    EqPreset('Вокал', (hz) => hz < 150 ? -2 : hz < 400 ? 0 : hz < 4000 ? 4 : 1),
    EqPreset('Высокие', (hz) => hz < 1000 ? 0 : hz < 6000 ? 3 : 5),
    EqPreset('Рок', (hz) => hz < 150 ? 5 : hz < 400 ? 2 : hz < 2000 ? -1 : hz < 6000 ? 3 : 5),
    EqPreset('Электроника', (hz) => hz < 150 ? 6 : hz < 400 ? 2 : hz < 2000 ? 0 : hz < 6000 ? 2 : 5),
  ];

  /// Для плеера: подключить эквалайзер к его звуковому тракту.
  AudioPipeline? get pipeline => android == null ? null : AudioPipeline(androidAudioEffects: [android!]);

  Future<void> load() async {
    if (!supported) return;
    final p = await SharedPreferences.getInstance();
    enabled = p.getBool('eq_on') ?? false;
    preset = p.getString('eq_preset') ?? 'Ровно';
    _savedGains = (p.getString('eq_gains') ?? '').split(',').map(double.tryParse).whereType<double>().toList();
  }

  /// Параметры полос появляются, только когда у плеера есть звук. Вызывается после запуска трека.
  Future<void> attach() async {
    final eq = android;
    if (eq == null || params != null) return;
    try {
      params = await eq.parameters;
      final bands = params!.bands;
      for (var i = 0; i < bands.length && i < _savedGains.length; i++) {
        await bands[i].setGain(_clamp(_savedGains[i]));
      }
      await eq.setEnabled(enabled);
      notifyListeners();
    } catch (e) {
      debugPrint('Эквалайзер недоступен: $e');
    }
  }

  double _clamp(double v) => params == null ? v : min(params!.maxDecibels, max(params!.minDecibels, v));

  Future<void> setEnabled(bool v) async {
    enabled = v;
    await android?.setEnabled(v);
    await _save();
    notifyListeners();
  }

  Future<void> setGain(int band, double db) async {
    final b = params?.bands[band];
    if (b == null) return;
    await b.setGain(_clamp(db));
    preset = 'Своя';
    await _save();
    notifyListeners();
  }

  Future<void> applyPreset(EqPreset p) async {
    final bands = params?.bands;
    if (bands == null) return;
    for (final b in bands) {
      await b.setGain(_clamp(p.curve(hz(b))));
    }
    preset = p.name;
    if (!enabled) await setEnabled(true);
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('eq_on', enabled);
    await p.setString('eq_preset', preset);
    final gains = params?.bands.map((b) => b.gain.toStringAsFixed(1)).join(',');
    if (gains != null) await p.setString('eq_gains', gains);
  }

  /// Частота полосы в герцах (Android на некоторых устройствах отдаёт миллигерцы).
  static double hz(AndroidEqualizerBand b) => b.centerFrequency > 50000 ? b.centerFrequency / 1000 : b.centerFrequency;

  static String formatHz(double hz) =>
      hz >= 1000 ? '${(hz / 1000).toStringAsFixed(hz >= 10000 ? 0 : 1)} кГц' : '${hz.round()} Гц';
}
