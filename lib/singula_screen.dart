import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'ai_service.dart';
import 'command_parser.dart';

// Состояния Singula
enum SingulaState { 
  idle,        // ждёт "Сингула"
  waking,      // услышал wake word — ждёт команду
  listening,   // собирает команду
  executing,   // услышал "выполняй" — думает
  speaking,    // говорит ответ
}

class ChatMessage {
  final String role, text;
  final DateTime time;
  ChatMessage({required this.role, required this.text, required this.time});
}

class SingulaScreen extends StatefulWidget {
  const SingulaScreen({super.key});
  @override
  State<SingulaScreen> createState() => _SingulaScreenState();
}

class _SingulaScreenState extends State<SingulaScreen> with TickerProviderStateMixin {
  final _stt = SpeechToText();
  final _tts = FlutterTts();
  final _ai = AIService();
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  bool _sttReady = false;
  SingulaState _state = SingulaState.idle;
  String _transcript = '';
  String _commandBuffer = '';   // накапливает команду после wake word
  bool _continuous = false;
  bool _voiceOn = true;
  bool _online = true;
  final List<ChatMessage> _msgs = [];
  Timer? _silenceTimer;
  Timer? _wakeTimer;            // таймаут ожидания команды

  // Wake words — слова пробуждения
  static const _wakeWords = ['сингула', 'singula', 'эй сингула', 'слушай'];
  // Execute words — слова выполнения
  static const _execWords = ['выполняй', 'исполняй', 'давай', 'сделай', 'ок выполняй', 'готово'];
  // Cancel words — отмена
  static const _cancelWords = ['отмена', 'отменить', 'нет', 'стоп'];

  // Анимации
  late AnimationController _orbCtrl;
  late AnimationController _ringCtrl;
  late AnimationController _waveCtrl;
  late Animation<double> _orbScale;
  late Animation<double> _ringRot;

  // Цвета темы Singula
  static const _bg = Color(0xFF080810);
  static const _surface = Color(0xFF0F0F1A);
  static const _card = Color(0xFF141424);
  static const _purple = Color(0xFF6C5CE7);
  static const _purple2 = Color(0xFFA855F7);
  static const _green = Color(0xFF00D4AA);
  static const _red = Color(0xFFEF4444);

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _setupTts();
    _initStt();
    _requestPermissions();
    _checkConnectivity();
    WidgetsBinding.instance.addPostFrameCallback((_) => _greet());
  }

  void _setupAnimations() {
    _orbCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat(reverse: true);
    _ringCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))
      ..repeat();
    _waveCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500))
      ..repeat(reverse: true);
    _orbScale = Tween(begin: 1.0, end: 1.08).animate(CurvedAnimation(parent: _orbCtrl, curve: Curves.easeInOut));
    _ringRot = Tween(begin: 0.0, end: 2 * pi).animate(_ringCtrl);
  }

  Future<void> _setupTts() async {
    await _tts.setLanguage('ru-RU');
    await _tts.setSpeechRate(0.92);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() {
      if (mounted) {
        _setS(SingulaState.idle);
        if (_continuous) _startListening();
      }
    });
  }

  Future<void> _initStt() async {
    _sttReady = await _stt.initialize(
      onError: (_) { if (mounted) _setS(SingulaState.idle); },
      onStatus: (s) { if ((s == 'done' || s == 'notListening') && mounted) _onSpeechDone(); },
    );
    if (mounted) setState(() {});
  }

  Future<void> _requestPermissions() async {
    await [Permission.microphone, Permission.phone].request();
  }

  Future<void> _checkConnectivity() async {
    final r = await Connectivity().checkConnectivity();
    setState(() => _online = r != ConnectivityResult.none);
    Connectivity().onConnectivityChanged.listen((r) {
      if (mounted) setState(() => _online = r != ConnectivityResult.none);
    });
  }

  Future<void> _greet() async {
    final h = DateTime.now().hour;
    final greet = h < 6 ? 'Доброй ночи' : h < 12 ? 'Доброе утро' : h < 17 ? 'Добрый день' : 'Добрый вечер';
    final status = _online ? 'Онлайн режим активен.' : 'Офлайн режим — базовые команды доступны.';
    final msg = '$greet, господин. Singula активирован. $status Нажмите орб чтобы говорить.';
    _addMsg('singula', msg);
    await Future.delayed(const Duration(milliseconds: 500));
    await _speak(msg);
  }

  // ── ГОЛОС ──
  void _handleOrb() {
    if (_state == SingulaState.speaking) {
      _tts.stop();
      _setS(SingulaState.idle);
    } else if (_state == SingulaState.waking) {
      // В режиме ожидания команды — нажатие = "выполняй"
      if (_commandBuffer.isNotEmpty) {
        _onExecuteCommand(_commandBuffer);
      } else {
        _cancelWake();
      }
    } else if (_state == SingulaState.idle) {
      _startListening();
    }
  }

  // ── ЗАПУСК ПРОСЛУШИВАНИЯ ──
  Future<void> _startListening() async {
    if (!_sttReady) { await _speak('Микрофон недоступен, господин.'); return; }
    await _tts.stop();
    setState(() => _transcript = '');
    
    // Определяем режим по текущему состоянию
    final isWakeMode = _state == SingulaState.idle;
    if (isWakeMode) {
      _setS(SingulaState.idle); // ждём wake word
    }

    await _stt.listen(
      onResult: (r) {
        if (!mounted) return;
        final words = r.recognizedWords.trim().toLowerCase();
        setState(() => _transcript = r.recognizedWords);
        
        if (!r.finalResult) return; // ждём финальный результат
        
        _handleSpeechResult(r.recognizedWords);
      },
      localeId: 'ru_RU',
      listenMode: ListenMode.dictation,  // dictation — слушает дольше
      pauseFor: const Duration(seconds: 2),
      partialResults: true,
    );

    _silenceTimer = Timer(const Duration(seconds: 30), _stopListening);
  }

  // ── ОБРАБОТКА РАСПОЗНАННОЙ РЕЧИ ──
  void _handleSpeechResult(String words) {
    final t = words.toLowerCase().trim();
    if (t.isEmpty) return;
    
    // 1. Проверяем wake word (в любом состоянии)
    for (final wake in _wakeWords) {
      if (t.contains(wake)) {
        _onWakeWordDetected(words);
        return;
      }
    }
    
    // 2. Если уже активны — проверяем execute word
    if (_state == SingulaState.waking) {
      // Проверяем слово выполнения
      for (final exec in _execWords) {
        if (t.contains(exec)) {
          // Убираем exec word из команды
          final cmd = _commandBuffer
            .replaceAll(RegExp(exec, caseSensitive: false), '')
            .trim();
          if (cmd.isNotEmpty) {
            _onExecuteCommand(cmd);
          } else {
            _speak('Господин, вы не дали команду.');
            _cancelWake();
          }
          return;
        }
      }
      
      // Проверяем отмену
      for (final cancel in _cancelWords) {
        if (t == cancel) {
          _cancelWake();
          return;
        }
      }
      
      // Накапливаем команду
      _wakeTimer?.cancel();
      setState(() {
        _commandBuffer = _commandBuffer.isEmpty ? words : '$_commandBuffer $words';
      });
      _addMsg('singula', '📝 Записал: $_commandBuffer\nСкажи "выполняй" или продолжи команду.');
      
      // Таймаут 15 секунд — если молчит, отменяем
      _wakeTimer = Timer(const Duration(seconds: 15), () {
        if (_state == SingulaState.waking) {
          _speak('Господин, команда не получена. Отмена.');
          _cancelWake();
        }
      });
      
      // Продолжаем слушать
      _startListening();
    }
  }

  // ── WAKE WORD ОБНАРУЖЕН ──
  void _onWakeWordDetected(String words) {
    _wakeTimer?.cancel();
    
    // Проверяем — может в той же фразе уже есть команда и exec word
    final t = words.toLowerCase();
    String? inlineCmd;
    String? execFound;
    
    for (final exec in _execWords) {
      if (t.contains(exec)) { execFound = exec; break; }
    }
    
    // Убираем wake word из фразы
    var cleaned = words;
    for (final wake in _wakeWords) {
      cleaned = cleaned.replaceAll(RegExp(wake, caseSensitive: false), '').trim();
    }
    
    if (execFound != null) {
      // Фраза типа "Сингула открой ютуб выполняй" — всё в одном
      inlineCmd = cleaned.replaceAll(RegExp(execFound, caseSensitive: false), '').trim();
      if (inlineCmd.isNotEmpty) {
        _setS(SingulaState.waking);
        setState(() => _commandBuffer = inlineCmd!);
        _onExecuteCommand(inlineCmd);
        return;
      }
    }
    
    // Только wake word — ждём команду
    _setS(SingulaState.waking);
    setState(() => _commandBuffer = cleaned.isNotEmpty ? cleaned : '');
    
    // Короткий звук подтверждения
    _tts.speak('Слушаю.');
    
    _addMsg('singula', '⚡ Активирован. Говорите команду, затем скажите "выполняй".');
    
    // Таймаут ожидания команды
    _wakeTimer = Timer(const Duration(seconds: 20), () {
      if (_state == SingulaState.waking) {
        _speak('Господин, команда не получена.');
        _cancelWake();
      }
    });
    
    _startListening();
  }

  // ── ВЫПОЛНИТЬ КОМАНДУ ──
  void _onExecuteCommand(String cmd) {
    _wakeTimer?.cancel();
    _stt.stop();
    setState(() { _commandBuffer = ''; _transcript = ''; });
    _processCommand(cmd);
  }

  // ── ОТМЕНА ──
  void _cancelWake() {
    _wakeTimer?.cancel();
    _stt.stop();
    setState(() { _commandBuffer = ''; _transcript = ''; });
    _setS(SingulaState.idle);
    _addMsg('singula', 'Команда отменена. Жду "Сингула".');
    if (_continuous) _startListening();
  }

  void _stopListening() {
    _silenceTimer?.cancel();
    _stt.stop();
    if (_state == SingulaState.listening) _setS(SingulaState.idle);
    if (_continuous && _state == SingulaState.idle) _startListening();
  }

  void _onSpeechDone() {
    if (_state == SingulaState.idle && _continuous) _startListening();
  }

  // ── ОБРАБОТКА КОМАНДЫ ──
  Future<void> _processCommand(String text) async {
    if (text.trim().isEmpty) return;
    _silenceTimer?.cancel();
    _stopListening();
    _addMsg('user', text);
    _setS(SingulaState.executing);

    final cmd = CommandParser.parse(text);

    switch (cmd.type) {
      case CommandType.openApp:
        await _openApp(cmd.payload, cmd.label);

      case CommandType.openUrl:
        await _openUrl(cmd.payload);

      case CommandType.search:
        await _search(cmd.payload);

      case CommandType.time:
        final n = DateTime.now();
        await _reply('Сейчас ${n.hour} часов ${n.minute} минут, господин.');

      case CommandType.date:
        final n = DateTime.now();
        final days = ['понедельник','вторник','среда','четверг','пятница','суббота','воскресенье'];
        final months = ['января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря'];
        await _reply('Сегодня ${days[n.weekday-1]}, ${n.day} ${months[n.month-1]} ${n.year} года, господин.');

      case CommandType.timer:
        final secs = int.tryParse(cmd.payload) ?? 60;
        await _reply('Таймер на ${cmd.label} установлен, господин.');
        Timer(Duration(seconds: secs), () => _speak('Господин, время вышло! Таймер ${cmd.label} сработал.'));

      case CommandType.alarm:
        await _reply('Открываю часы для будильника на ${cmd.payload}, господин.');
        await _openApp('com.android.deskclock', 'часы');

      case CommandType.weather:
        final reply = await _ai.ask('Какая сейчас погода в ${cmd.payload}? Одно предложение.');
        await _reply(reply);

      case CommandType.sendTelegram:
        await _reply('Открываю Telegram, господин. Текст сообщения: ${cmd.payload}');
        await _openApp('org.telegram.messenger', 'Telegram');

      case CommandType.sendWhatsapp:
        await _reply('Открываю WhatsApp, господин.');
        await _openApp('com.whatsapp', 'WhatsApp');

      case CommandType.call:
        await _reply('Звоню ${cmd.payload}, господин.');
        final uri = Uri.parse('tel:${cmd.payload}');
        await launchUrl(uri);

      case CommandType.stop:
        await _tts.stop();
        setState(() => _continuous = false);
        _setS(SingulaState.idle);
        _addMsg('singula', 'Хорошо, господин. Жду команды.');

      case CommandType.clear:
        setState(() => _msgs.clear());
        _ai.clearHistory();
        await _reply('История очищена, господин. Начинаем с чистого листа.');

      case CommandType.aiQuestion:
      default:
        final reply = await _ai.ask(text);
        await _reply(reply);
    }
  }

  Future<void> _openApp(String package, String label) async {
    await _reply('Открываю $label, господин.');
    try {
      final intent = AndroidIntent(action: 'android.intent.action.MAIN', package: package);
      await intent.launch();
    } catch (_) {
      await _speak('Приложение $label не найдено на устройстве.');
    }
  }

  Future<void> _openUrl(String url) async {
    await _reply('Открываю $url, господин.');
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _search(String query) async {
    await _reply('Ищу: $query.');
    final url = Uri.parse('https://www.google.com/search?q=${Uri.encodeComponent(query)}');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _reply(String text) async {
    _addMsg('singula', text);
    _setS(SingulaState.speaking);
    await _speak(text);
    _setS(SingulaState.idle);
  }

  Future<void> _speak(String text) async {
    if (!_voiceOn) return;
    await _tts.speak(text);
    await Future.delayed(Duration(milliseconds: (text.length * 55 + 400).clamp(400, 8000)));
  }

  void _addMsg(String role, String text) {
    if (!mounted) return;
    setState(() => _msgs.add(ChatMessage(role: role, text: text, time: DateTime.now())));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  void _setS(SingulaState s) { if (mounted) setState(() => _state = s); }

  Color get _orbColor1 => switch (_state) {
    SingulaState.idle      => _purple,
    SingulaState.waking    => Colors.orange,
    SingulaState.listening => _red,
    SingulaState.executing => _purple,
    SingulaState.speaking  => _green,
  };
  Color get _orbColor2 => switch (_state) {
    SingulaState.idle      => _purple2,
    SingulaState.waking    => const Color(0xFFFF6B00),
    SingulaState.listening => Colors.deepOrange,
    SingulaState.executing => _purple2,
    SingulaState.speaking  => const Color(0xFF059669),
  };

  String get _stateHint => switch (_state) {
    SingulaState.idle      => 'скажи "Сингула" чтобы активировать',
    SingulaState.waking    => 'говори команду... потом "выполняй"',
    SingulaState.listening => 'слушаю...',
    SingulaState.executing => 'выполняю...',
    SingulaState.speaking  => 'говорю...',
  };

  @override
  void dispose() {
    _orbCtrl.dispose(); _ringCtrl.dispose(); _waveCtrl.dispose();
    _silenceTimer?.cancel();
    _stt.stop(); _tts.stop();
    _textCtrl.dispose(); _scrollCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.8, -0.8),
            radius: 1.2,
            colors: [Color(0xFF1A1040), _bg],
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            _buildHeader(),
            Expanded(child: _buildChat()),
            if (_transcript.isNotEmpty) _buildLiveTranscript(),
            _buildControls(),
          ]),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        // Лого
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [_purple, _purple2]),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: _purple.withOpacity(0.4), blurRadius: 12)],
          ),
          child: const Center(child: Text('S', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18))),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('SINGULA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: 1.5)),
              const SizedBox(width: 8),
              Container(width: 7, height: 7, decoration: BoxDecoration(
                color: _orbColor1,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: _orbColor1.withOpacity(0.6), blurRadius: 6)],
              )),
            ]),
            Text(
              switch (_state) {
                SingulaState.idle      => _online ? 'жду команды' : 'офлайн',
                SingulaState.waking    => 'активирован — говори команду',
                SingulaState.listening => 'слушаю...',
                SingulaState.executing => 'выполняю...',
                SingulaState.speaking  => 'говорю...',
              },
              style: TextStyle(
                color: _orbColor1.withOpacity(0.8),
                fontSize: 11, fontWeight: FontWeight.w500,
              ),
            ),
          ],
        )),
        // Голос вкл/выкл
        GestureDetector(
          onTap: () async {
            setState(() => _voiceOn = !_voiceOn);
            if (!_voiceOn) await _tts.stop();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _voiceOn ? _purple.withOpacity(0.2) : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _voiceOn ? _purple.withOpacity(0.5) : Colors.white.withOpacity(0.1)),
            ),
            child: Text(
              _voiceOn ? '🔊' : '🔇',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildChat() {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      itemCount: _msgs.length,
      itemBuilder: (_, i) => _buildMsg(_msgs[i]),
    );
  }

  Widget _buildMsg(ChatMessage m) {
    final isUser = m.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            Container(
              width: 30, height: 30,
              margin: const EdgeInsets.only(right: 8, bottom: 2),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [_purple, _purple2]),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Center(child: Text('S', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
            ),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: isUser ? const LinearGradient(colors: [_purple, _purple2]) : null,
                color: isUser ? null : _surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                border: isUser ? null : Border.all(color: Colors.white.withOpacity(0.06)),
                boxShadow: isUser ? [BoxShadow(color: _purple.withOpacity(0.25), blurRadius: 10, offset: const Offset(0,3))] : null,
              ),
              child: Text(m.text, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5)),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildLiveTranscript() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: _red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _red.withOpacity(0.3)),
      ),
      child: Row(children: [
        Container(width: 7, height: 7, decoration: const BoxDecoration(color: _red, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(_transcript, style: const TextStyle(color: Colors.white70, fontSize: 13))),
      ]),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      decoration: BoxDecoration(
        color: _surface.withOpacity(0.9),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06))),
      ),
      child: Column(children: [
        // Баннер накопленной команды
        if (_state == SingulaState.waking && _commandBuffer.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.withOpacity(0.35)),
            ),
            child: Row(children: [
              const Text('📝 ', style: TextStyle(fontSize: 14)),
              Expanded(child: Text(
                _commandBuffer,
                style: const TextStyle(color: Colors.orange, fontSize: 13, fontWeight: FontWeight.w500),
              )),
            ]),
          ),

        // Волна при записи
        if (_state == SingulaState.waking || _state == SingulaState.listening)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _buildWave(),
          ),

        // ORB
        GestureDetector(
          onTap: _handleOrb,
          child: AnimatedBuilder(
            animation: Listenable.merge([_orbCtrl, _ringCtrl]),
            builder: (_, __) {
              return SizedBox(
                width: 96, height: 96,
                child: Stack(alignment: Alignment.center, children: [
                  // Вращающееся кольцо
                  Transform.rotate(
                    angle: _ringRot.value,
                    child: Container(
                      width: 96, height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _orbColor1.withOpacity(0.3),
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                  // Орб
                  Transform.scale(
                    scale: _state == SingulaState.executing ? _orbScale.value : 1.0,
                    child: Container(
                      width: 76, height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [_orbColor1, _orbColor2],
                        ),
                        boxShadow: [
                          BoxShadow(color: _orbColor1.withOpacity(0.5), blurRadius: 24, spreadRadius: 2),
                        ],
                      ),
                      child: Icon(
                        switch (_state) {
                          SingulaState.idle      => Icons.mic_none_rounded,
                          SingulaState.waking    => Icons.hearing_rounded,
                          SingulaState.listening => Icons.mic_rounded,
                          SingulaState.executing => Icons.psychology_rounded,
                          SingulaState.speaking  => Icons.volume_up_rounded,
                        },
                        color: Colors.white, size: 34,
                      ),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),

        const SizedBox(height: 8),
        Text(_stateHint, style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 11, letterSpacing: 0.5)),
        const SizedBox(height: 12),

        // Кнопки
        Row(children: [
          Expanded(child: _SingulaButton(
            label: _continuous ? '🔴 Стоп' : '🔄 Режим',
            active: _continuous,
            onTap: () {
              setState(() => _continuous = !_continuous);
              if (_continuous && _state == SingulaState.idle) _startListening();
            },
          )),
          const SizedBox(width: 8),
          Expanded(child: _SingulaButton(
            label: '🗑 Очистить',
            onTap: () {
              setState(() => _msgs.clear());
              _ai.clearHistory();
              _addMsg('singula', 'Готов к работе, господин.');
            },
          )),
        ]),

        const SizedBox(height: 10),

        // Текстовый ввод
        Row(children: [
          Expanded(
            child: TextField(
              controller: _textCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'или напиши команду...',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                filled: true,
                fillColor: const Color(0xFF0F0F1A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _purple),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              ),
              onSubmitted: (t) {
                if (t.trim().isEmpty) return;
                _textCtrl.clear();
                _processCommand(t);
              },
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              final t = _textCtrl.text.trim();
              if (t.isEmpty) return;
              _textCtrl.clear();
              _processCommand(t);
            },
            child: Container(
              width: 46, height: 46,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [_purple, _purple2]),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: _purple.withOpacity(0.35), blurRadius: 10)],
              ),
              child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _buildWave() {
    return AnimatedBuilder(
      animation: _waveCtrl,
      builder: (_, __) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(10, (i) {
            final h = 4.0 + sin(_waveCtrl.value * pi + i * 0.5) * 14 + (i % 3) * 4;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 50),
              width: 3, height: h.abs().clamp(4.0, 28.0),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: _red.withOpacity(0.8),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}

class _SingulaButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool active;
  const _SingulaButton({required this.label, required this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFEF4444).withOpacity(0.12) : const Color(0xFF0F0F1A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? const Color(0xFFEF4444).withOpacity(0.4) : Colors.white.withOpacity(0.07),
          ),
        ),
        child: Center(child: Text(label, style: TextStyle(
          color: active ? Colors.orange : Colors.white.withOpacity(0.55),
          fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3,
        ))),
      ),
    );
  }
}
