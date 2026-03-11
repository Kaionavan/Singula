'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';

Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'singula_channel',
      initialNotificationTitle: 'Singula',
      initialNotificationContent: '● Активен — говори команду',
      foregroundServiceNotificationId: 777,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  service.on('stop').listen((_) => service.stopSelf());
  Timer.periodic(const Duration(seconds: 30), (_) {
    service.invoke('heartbeat', {'time': DateTime.now().toIso8601String()});
  });
}
