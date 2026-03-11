class CommandParser {
  static Command parse(String text) {
    final t = text.toLowerCase().trim();

    final appMap = {
      'телеграм': 'org.telegram.messenger',
      'telegram': 'org.telegram.messenger',
      'ватсап': 'com.whatsapp',
      'whatsapp': 'com.whatsapp',
      'ютуб': 'com.google.android.youtube',
      'youtube': 'com.google.android.youtube',
      'инстаграм': 'com.instagram.android',
      'тикток': 'com.zhiliaoapp.musically',
      'spotify': 'com.spotify.music',
      'спотифай': 'com.spotify.music',
      'карты': 'com.google.android.apps.maps',
      'яндекс карты': 'ru.yandex.yandexmaps',
      'яндекс такси': 'ru.yandex.taxi',
      'камера': 'android.media.action.IMAGE_CAPTURE',
      'настройки': 'com.android.settings',
      'калькулятор': 'com.android.calculator2',
      'часы': 'com.android.deskclock',
      'календарь': 'com.google.android.calendar',
      'галерея': 'com.google.android.apps.photos',
      'хром': 'com.android.chrome',
      'gmail': 'com.google.android.gm',
      'озон': 'ru.ozon.app.android',
    };

    final openWords = ['открой','запусти','включи','зайди в'];
    for (final w in openWords) {
      if (t.contains(w)) {
        for (final k in appMap.keys) {
          if (t.contains(k)) {
            return Command(type: CommandType.openApp, payload: appMap[k]!, label: k);
          }
        }
      }
    }

    final searchMatch = RegExp(r'(?:найди|поищи|погугли|ищи)\s+(.+)').firstMatch(t);
    if (searchMatch != null) {
      return Command(type: CommandType.search, payload: searchMatch.group(1)!, label: 'поиск');
    }

    final urlMatch = RegExp(r'(?:открой|зайди на)\s+(?:сайт\s+)?([\w.-]+\.[\w]{2,})').firstMatch(t);
    if (urlMatch != null) {
      var url = urlMatch.group(1)!;
      if (!url.startsWith('http')) url = 'https://$url';
      return Command(type: CommandType.openUrl, payload: url, label: url);
    }

    final callMatch = RegExp(r'(?:позвони|набери)\s+(.+)').firstMatch(t);
    if (callMatch != null) {
      return Command(type: CommandType.call, payload: callMatch.group(1)!.trim(), label: callMatch.group(1)!.trim());
    }

    if (t.contains('который час') || t.contains('сколько время')) {
      return Command(type: CommandType.time, payload: '', label: 'время');
    }
    if (t.contains('какое число') || t.contains('день недели') || t.contains('какой сегодня')) {
      return Command(type: CommandType.date, payload: '', label: 'дата');
    }

    final timerMatch = RegExp(r'таймер\s+(\d+)\s*(минут|секунд|час)').firstMatch(t);
    if (timerMatch != null) {
      final n = int.parse(timerMatch.group(1)!);
      final unit = timerMatch.group(2)!;
      final secs = unit.startsWith('минут') ? n * 60 : unit.startsWith('час') ? n * 3600 : n;
      return Command(type: CommandType.timer, payload: secs.toString(), label: '$n $unit');
    }

    if (t.contains('стоп') || t.contains('тихо') || t.contains('замолчи')) {
      return Command(type: CommandType.stop, payload: '', label: 'стоп');
    }
    if (t.contains('очисти') || t.contains('забудь всё')) {
      return Command(type: CommandType.clear, payload: '', label: 'очистить');
    }

    return Command(type: CommandType.aiQuestion, payload: text, label: 'вопрос');
  }
}

enum CommandType {
  openApp, openUrl, search, call,
  time, date, timer, stop, clear,
  aiQuestion,
}

class Command {
  final CommandType type;
  final String payload;
  final String label;
  const Command({required this.type, required this.payload, required this.label});
}
