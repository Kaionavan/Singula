import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AIService {
  static const _groqKey = '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';
  static const _models = [
    'llama-3.3-70b-versatile',
    'llama3-70b-8192',
    'llama-3.1-8b-instant',
    'gemma2-9b-it',
  ];

  final List<Map<String, String>> _history = [];

  static const Map<String, String> _offline = {
    'привет': 'Приветствую, господин. Работаю в офлайн режиме.',
    'как дела': 'Все системы работают нормально, господин.',
    'кто ты': 'Я Singula — ваш персональный AI-агент.',
    'что умеешь': 'Открываю приложения, ищу информацию. Сейчас офлайн режим.',
    'спасибо': 'Всегда к вашим услугам, господин.',
  };

  static const _system =
    'Ты Singula — персональный AI-агент. '
    'Обращайся: господин. Язык: русский. '
    'Отвечай коротко — 1-2 предложения. Без markdown.';

  Future<bool> hasInternet() async {
    final r = await Connectivity().checkConnectivity();
    return r != ConnectivityResult.none;
  }

  Future<String> ask(String text) async {
    _history.add({'role': 'user', 'content': text});
    if (_history.length > 20) _history.removeRange(0, _history.length - 20);

    if (!await hasInternet()) return _getOffline(text);

    for (final model in _models) {
      try {
        final r = await http.post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $_groqKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': _system},
              ..._history,
            ],
            'max_tokens': 200,
            'temperature': 0.75,
          }),
        ).timeout(const Duration(seconds: 8));

        if (r.statusCode == 200) {
          final d = jsonDecode(r.body);
          final reply = d['choices']?[0]?['message']?['content']?.toString().trim();
          if (reply != null && reply.isNotEmpty) {
            _history.add({'role': 'assistant', 'content': reply});
            return reply;
          }
        }
      } catch (_) { continue; }
    }
    return _getOffline(text);
  }

  String _getOffline(String text) {
    final t = text.toLowerCase();
    for (final k in _offline.keys) {
      if (t.contains(k)) return _offline[k]!;
    }
    return 'Нет интернета, господин. Могу открыть приложения или сказать время.';
  }

  void clearHistory() => _history.clear();
}
