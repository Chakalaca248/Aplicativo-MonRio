import 'dart:typed_data';

import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static const _attentionChannelId = 'river_attention_v2';
  static const _alertChannelId = 'river_alert_v2';
  static const _attentionNotificationId = 241;
  static const _alertNotificationId = 242;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    final android = _androidPlugin;
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _attentionChannelId,
        'Atenção: nível do rio',
        description: 'Avisos discretos quando o nível entra na faixa de atenção.',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    );
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        _alertChannelId,
        'Alerta crítico do rio',
        description: 'Avisos sonoros e vibratórios para níveis críticos.',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 800, 250, 800, 250, 800]),
      ),
    );
  }

  AndroidFlutterLocalNotificationsPlugin? get _androidPlugin =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  Future<bool> requestPermission() async {
    final android = _androidPlugin;
    final enabled = await android?.areNotificationsEnabled();
    if (enabled == true) return true;

    final granted = await android?.requestNotificationsPermission();
    if (granted != null) return granted;
    return await android?.areNotificationsEnabled() ?? true;
  }

  Future<void> showAttention(double levelCm) async {
    await _plugin.cancel(_alertNotificationId);
    await _plugin.cancel(_attentionNotificationId);
    await _plugin.show(
      _attentionNotificationId,
      'Atenção: nível do rio elevado',
      'Medição atual: ${levelCm.toStringAsFixed(1)} cm.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _attentionChannelId,
          'Atenção: nível do rio',
          channelDescription:
              'Avisos discretos quando o nível entra na faixa de atenção.',
          importance: Importance.low,
          priority: Priority.low,
          playSound: false,
          enableVibration: false,
          onlyAlertOnce: false,
          color: Color(0xFF7DAD93),
        ),
      ),
    );
  }

  Future<void> showAlert(double levelCm) async {
    await _plugin.cancel(_attentionNotificationId);
    await _plugin.cancel(_alertNotificationId);
    await _plugin.show(
      _alertNotificationId,
      'ALERTA CRÍTICO DO RIO',
      'Nível em ${levelCm.toStringAsFixed(1)} cm. Verifique a situação agora.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _alertChannelId,
          'Alerta crítico do rio',
          channelDescription:
              'Avisos sonoros e vibratórios para níveis críticos.',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 800, 250, 800, 250, 800]),
          onlyAlertOnce: false,
          category: AndroidNotificationCategory.alarm,
          color: const Color(0xFFB84F43),
        ),
      ),
    );
  }

  Future<void> clear() async {
    await _plugin.cancel(_attentionNotificationId);
    await _plugin.cancel(_alertNotificationId);
  }
}

