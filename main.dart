\
import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Strategy: 현금대기 EMA60 (U2/D5, B0, C0)
/// - Signal on QQQ close vs EMA60 (no band)
/// - Confirm: Up 2 days / Down 5 days
/// - Execution: next trading day's open (D+1)
/// - Position is user-selected (TQQQ or CASH) because app can't read brokerage.
const String kStrategyName = '현금대기 EMA60 (U2/D5, B0, C0)';
const int kEmaLen = 60;
const int kUpConfirm = 2;
const int kDownConfirm = 5;

/// Data source (CSV):
/// Stooq provides a simple CSV endpoint:
/// https://stooq.com/q/d/l/?s=qqq.us&i=d
/// Columns: Date,Open,High,Low,Close,Volume
const String kQqqCsvUrl = 'https://stooq.com/q/d/l/?s=qqq.us&i=d';
const String kTqqqCsvUrl = 'https://stooq.com/q/d/l/?s=tqqq.us&i=d'; // optional display only

enum Position { tqqq, cash }
enum Regime { up, down, neutral }
enum ActionType { buyTqqq, sellTqqq, holdTqqq, holdCash }

class Bar {
  final DateTime date;
  final double close;
  Bar(this.date, this.close);
}

class SignalState {
  final DateTime asOf;
  final double qqqClose;
  final double ema;
  final int upStreak;
  final int downStreak;
  final Regime regime;
  final double? tqqqClose;

  SignalState({
    required this.asOf,
    required this.qqqClose,
    required this.ema,
    required this.upStreak,
    required this.downStreak,
    required this.regime,
    this.tqqqClose,
  });
}

Future<List<List<dynamic>>> _parseCsv(String raw) async {
  return const CsvToListConverter(eol: '\n').convert(raw);
}

double _toDouble(dynamic v) {
  if (v == null) return double.nan;
  final s = v.toString().trim();
  if (s.isEmpty) return double.nan;
  return double.tryParse(s) ?? double.nan;
}

DateTime _parseDate(dynamic v) => DateTime.parse(v.toString());

List<Bar> _extractBars(List<List<dynamic>> rows) {
  if (rows.isEmpty) return [];
  final header = rows.first.map((e) => e.toString().toLowerCase()).toList();
  final dateIdx = header.indexOf('date');
  final closeIdx = header.indexOf('close');
  if (dateIdx < 0 || closeIdx < 0) return [];

  final bars = <Bar>[];
  for (int i = 1; i < rows.length; i++) {
    final r = rows[i];
    if (r.length <= closeIdx || r.length <= dateIdx) continue;
    final d = _parseDate(r[dateIdx]);
    final c = _toDouble(r[closeIdx]);
    if (c.isNaN) continue;
    bars.add(Bar(d, c));
  }
  bars.sort((a, b) => a.date.compareTo(b.date));
  return bars;
}

List<double> _emaSeries(List<double> closes, int len) {
  if (closes.length < len) return [];
  final alpha = 2.0 / (len + 1.0);

  final out = List<double>.filled(closes.length, double.nan);
  double sma = 0.0;
  for (int i = 0; i < len; i++) {
    sma += closes[i];
  }
  sma /= len;
  out[len - 1] = sma;

  double prev = sma;
  for (int i = len; i < closes.length; i++) {
    final ema = alpha * closes[i] + (1 - alpha) * prev;
    out[i] = ema;
    prev = ema;
  }
  return out;
}

int _countStreak(List<double> closes, List<double> ema, bool above) {
  int n = 0;
  for (int i = closes.length - 1; i >= 0; i--) {
    final c = closes[i];
    final e = ema[i];
    if (e.isNaN) continue;
    final ok = above ? (c > e) : (c < e);
    if (ok) {
      n += 1;
    } else {
      break;
    }
  }
  return n;
}

Regime _regimeFromStreaks(int up, int down) {
  if (up >= kUpConfirm) return Regime.up;
  if (down >= kDownConfirm) return Regime.down;
  return Regime.neutral;
}

ActionType _actionFrom(Position pos, Regime reg) {
  if (pos == Position.cash) {
    if (reg == Regime.up) return ActionType.buyTqqq;
    return ActionType.holdCash;
  } else {
    if (reg == Regime.down) return ActionType.sellTqqq;
    return ActionType.holdTqqq;
  }
}

String actionLabel(ActionType a) {
  switch (a) {
    case ActionType.buyTqqq:
      return '🟢 BUY TQQQ / 매수(신규진입)';
    case ActionType.sellTqqq:
      return '🔴 SELL TQQQ / 매도(현금전환)';
    case ActionType.holdTqqq:
      return '🔵 HOLD TQQQ / 대기(보유 유지)';
    case ActionType.holdCash:
      return '⚪ HOLD CASH / 대기(현금 유지)';
  }
}

String regimeLabel(Regime r) {
  switch (r) {
    case Regime.up:
      return '상승 확정';
    case Regime.down:
      return '하락 확정';
    case Regime.neutral:
      return '중립(대기구간)';
  }
}

String positionLabel(Position p) {
  switch (p) {
    case Position.tqqq:
      return 'Position: TQQQ 보유';
    case Position.cash:
      return 'Position: 현금(CASH) 보유';
  }
}

Future<SignalState> fetchSignal() async {
  final qRes = await http.get(Uri.parse(kQqqCsvUrl));
  if (qRes.statusCode != 200) {
    throw Exception('QQQ 데이터 다운로드 실패 (HTTP ${qRes.statusCode})');
  }
  final qRows = await _parseCsv(utf8.decode(qRes.bodyBytes));
  final qBars = _extractBars(qRows);
  if (qBars.length < kEmaLen + 5) {
    throw Exception('QQQ 데이터가 너무 짧습니다. (${qBars.length} rows)');
  }

  final closes = qBars.map((b) => b.close).toList();
  final ema = _emaSeries(closes, kEmaLen);
  if (ema.isEmpty) throw Exception('EMA 계산 실패');

  final upStreak = _countStreak(closes, ema, true);
  final downStreak = _countStreak(closes, ema, false);
  final reg = _regimeFromStreaks(upStreak, downStreak);

  final lastIdx = closes.length - 1;
  final asOf = qBars[lastIdx].date;
  final qqqClose = closes[lastIdx];
  final lastEma = ema[lastIdx];

  double? tqqqClose;
  try {
    final tRes = await http.get(Uri.parse(kTqqqCsvUrl));
    if (tRes.statusCode == 200) {
      final tRows = await _parseCsv(utf8.decode(tRes.bodyBytes));
      final tBars = _extractBars(tRows);
      if (tBars.isNotEmpty) tqqqClose = tBars.last.close;
    }
  } catch (_) {}

  return SignalState(
    asOf: asOf,
    qqqClose: qqqClose,
    ema: lastEma,
    upStreak: upStreak,
    downStreak: downStreak,
    regime: reg,
    tqqqClose: tqqqClose,
  );
}

Future<Position> loadPosition() async {
  final prefs = await SharedPreferences.getInstance();
  final s = prefs.getString('position') ?? 'tqqq';
  return s == 'cash' ? Position.cash : Position.tqqq;
}

Future<void> savePosition(Position p) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('position', p == Position.cash ? 'cash' : 'tqqq');
}

void main() => runApp(const CashWaitApp());

class CashWaitApp extends StatelessWidget {
  const CashWaitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kStrategyName,
      theme: ThemeData(useMaterial3: true),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Position _pos = Position.tqqq;
  SignalState? _sig;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await loadPosition();
    setState(() => _pos = p);
    await _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await fetchSignal();
      setState(() => _sig = s);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _setPos(Position p) async {
    setState(() => _pos = p);
    await savePosition(p);
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('yyyy-MM-dd');
    final action = _sig == null ? null : _actionFrom(_pos, _sig!.regime);

    return Scaffold(
      appBar: AppBar(
        title: const Text(kStrategyName),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          )
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('한 화면 요약', style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text('데이터 기준: ${_sig == null ? '-' : df.format(_sig!.asOf)} (전일 종가 기준)'),
                            if (_sig?.tqqqClose != null)
                              Text('참고: TQQQ 종가(최근): ${_sig!.tqqqClose!.toStringAsFixed(2)}'),
                          ],
                        ),
                      ),
                      if (_loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Expanded(child: Text(positionLabel(_pos), style: Theme.of(context).textTheme.titleMedium)),
                      SegmentedButton<Position>(
                        segments: const [
                          ButtonSegment(value: Position.tqqq, label: Text('TQQQ')),
                          ButtonSegment(value: Position.cash, label: Text('CASH')),
                        ],
                        selected: {_pos},
                        onSelectionChanged: (s) => _setPos(s.first),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              if (_error != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      '오류: $_error\n\n네트워크 연결 확인 후 새로고침 눌러줘.',
                      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                    ),
                  ),
                ),

              if (_sig != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('내일 액션', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                        const SizedBox(height: 10),
                        Text(actionLabel(action!), style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        Divider(color: Theme.of(context).colorScheme.outlineVariant),
                        const SizedBox(height: 8),
                        Text('현재 시장 판정: ${regimeLabel(_sig!.regime)}'),
                        const SizedBox(height: 6),
                        Text(
                          '근거: ${_sig!.qqqClose > _sig!.ema ? '종가 > EMA60' : (_sig!.qqqClose < _sig!.ema ? '종가 < EMA60' : '종가 = EMA60')}'
                          '  |  QQQ 종가 ${_sig!.qqqClose.toStringAsFixed(2)} / EMA60 ${_sig!.ema.toStringAsFixed(2)}',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('조건 진행상황', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 10),
                        Text('위(Up) 연속일수: ${_sig!.upStreak} / $kUpConfirm'),
                        const SizedBox(height: 6),
                        Text('아래(Down) 연속일수: ${_sig!.downStreak} / $kDownConfirm'),
                      ],
                    ),
                  ),
                ),
              ] else if (_error == null) ...[
                const Expanded(child: Center(child: Text('데이터를 불러오는 중…'))),
              ],

              const SizedBox(height: 12),
              const Text(
                '체결 규칙: 신호 확정 → 다음 거래일 시가(D+1 Open)',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
