import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';

sealed class RiverMonitorException implements Exception {
  final String message;
  const RiverMonitorException(this.message);

  @override
  String toString() => message;
}

class NetworkException extends RiverMonitorException {
  const NetworkException(super.message);
}

class SpreadsheetParseException extends RiverMonitorException {
  const SpreadsheetParseException(super.message);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MonitorRioApp());
}

class AppConfig {
  static const spreadsheetId = '1DlWp0zrszRLPP-QOvbn8hFX2LlvqIn6MYHR0Nbkg_qw';
  static const sheetGid = '0';
  static const refreshInterval = Duration(seconds: 60);

  static const defaultAttentionLevelCm = 180.0;
  static const defaultAlertLevelCm = 240.0;
  static const alertReminderInterval = Duration(minutes: 2);
  static const attentionReminderInterval = Duration(minutes: 15);
  static const attentionPreferenceKey = 'river_attention_level_cm';
  static const alertPreferenceKey = 'river_alert_level_cm';
  static const notificationsPreferenceKey = 'river_notifications_enabled';

  static const ink = Color(0xFF2B2726);
  static const deepWater = Color(0xFF0A516D);
  static const water = Color(0xFF018790);
  static const sage = Color(0xFF7DAD93);
  static const mist = Color(0xFFDFECE6);
  static const paper = Color(0xFFFAFCFA);
  static const mutedInk = Color(0xFF64716D);
  static const alert = Color(0xFFB84F43);
}

class Medicao {
  const Medicao({
    required this.data,
    required this.nivel,
    required this.distancia,
    required this.status,
    required this.sensor,
  });

  final DateTime? data;
  final double nivel;
  final double? distancia;
  final String status;
  final String sensor;

  bool get isAlerta => normalizar(status) == 'alerta';
  bool get isAtencao => normalizar(status) == 'atencao';
  bool get isNormal => !isAlerta && !isAtencao;

  Medicao comStatus(String novoStatus) => Medicao(
        data: data,
        nivel: nivel,
        distancia: distancia,
        status: novoStatus,
        sensor: sensor,
      );

  bool get sensorLigado {
    final s = normalizar(sensor);
    return s.contains('ligado') && !s.contains('desligado');
  }
}

String statusPorNivel(
  double nivel, {
  double nivelAtencao = AppConfig.defaultAttentionLevelCm,
  double nivelAlerta = AppConfig.defaultAlertLevelCm,
}) {
  if (nivel >= nivelAlerta) return 'ALERTA';
  if (nivel >= nivelAtencao) return 'ATENÇÃO';
  return 'NORMAL';
}

Color corDoStatus(String status) {
  switch (normalizar(status)) {
    case 'alerta':
      return AppConfig.alert;
    case 'atencao':
      return AppConfig.sage;
    default:
      return AppConfig.water;
  }
}

String formatarLimite(double valor) {
  return valor == valor.roundToDouble()
      ? valor.toStringAsFixed(0)
      : valor.toString();
}

Future<List<Medicao>> carregarMedicoes({
  required double nivelAtencao,
  required double nivelAlerta,
}) async {
  final uri = Uri.https(
    'docs.google.com',
    '/spreadsheets/d/${AppConfig.spreadsheetId}/gviz/tq',
    {'tqx': 'out:csv', 'gid': AppConfig.sheetGid},
  );

  final resposta = await http
      .get(uri, headers: const {'Accept': 'text/csv'})
      .timeout(const Duration(seconds: 20));

  if (resposta.statusCode != 200) {
    throw NetworkException(
      'A planilha respondeu com HTTP ${resposta.statusCode}. '
      'Verifique se ela permite leitura pelo link.',
    );
  }

  final bodyBytes = resposta.bodyBytes;

  return Isolate.run(() => _processarCsvBytes(
        bodyBytes,
        nivelAtencao: nivelAtencao,
        nivelAlerta: nivelAlerta,
      ));
}

List<Medicao> _processarCsvBytes(
  Uint8List bodyBytes, {
  required double nivelAtencao,
  required double nivelAlerta,
}) {
  final csv = utf8.decode(bodyBytes, allowMalformed: true);
  if (csv.trimLeft().startsWith('<')) {
    throw const SpreadsheetParseException(
      'O Google retornou uma página HTML em vez dos dados CSV. '
      'Confirme se a planilha está compartilhada para leitura.',
    );
  }

  final linhas = parseCsv(csv.replaceFirst('\uFEFF', ''))
      .where((linha) => linha.any((celula) => celula.trim().isNotEmpty))
      .toList();
  if (linhas.isEmpty) return const [];

  final cabecalhos = linhas.first.map(normalizar).toList();
  final temCabecalho = cabecalhos.any(
    (item) =>
        item.contains('nivel') ||
        item.contains('data') ||
        item.contains('hora') ||
        item.contains('distancia') ||
        item.contains('perigo'),
  );

  int coluna(List<String> nomes, int alternativa) {
    for (final nome in nomes) {
      final exata = cabecalhos.indexOf(nome);
      if (exata >= 0) return exata;
    }
    final encontrada = cabecalhos.indexWhere(
      (titulo) => nomes.any((nome) => titulo.contains(nome)),
    );
    return encontrada >= 0 ? encontrada : alternativa;
  }

  final idxData = coluna(const ['data'], 0);
  final idxHora = coluna(const ['hora'], 1);
  final idxNivel = coluna(const ['nivel'], 2);
  final idxDistancia = coluna(const ['distancia'], 3);
  final idxSensor = coluna(const ['ultrassonico', 'sensor'], 5);

  String celula(List<String> linha, int indice) =>
      indice >= 0 && indice < linha.length ? linha[indice].trim() : '';

  final resultado = <Medicao>[];
  for (final linha in linhas.skip(temCabecalho ? 1 : 0)) {
    final nivel = parseNumero(celula(linha, idxNivel));
    if (nivel == null) continue;

    final dataTexto = celula(linha, idxData);
    final horaTexto = celula(linha, idxHora);
    resultado.add(
      Medicao(
        data: parseData('$dataTexto $horaTexto'.trim()),
        nivel: nivel,
        distancia: parseNumero(celula(linha, idxDistancia)),
        status: statusPorNivel(
          nivel,
          nivelAtencao: nivelAtencao,
          nivelAlerta: nivelAlerta,
        ),
        sensor: celula(linha, idxSensor),
      ),
    );
  }

  if (resultado.length > 1 && resultado.every((item) => item.data != null)) {
    resultado.sort((a, b) => a.data!.compareTo(b.data!));
  }
  return resultado;
}

const _mapAcentos = <String, String>{
  'á': 'a', 'à': 'a', 'ã': 'a', 'â': 'a', 'ä': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'õ': 'o', 'ô': 'o', 'ö': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ç': 'c',
};

String normalizar(String texto) {
  final valor = texto.trim().toLowerCase();
  final buffer = StringBuffer();
  for (var i = 0; i < valor.length; i++) {
    final char = valor[i];
    buffer.write(_mapAcentos[char] ?? char);
  }
  return buffer.toString();
}

final _numeroRegex = RegExp(r'[^0-9,.\-+]');

double? parseNumero(String texto) {
  var valor = texto.trim().replaceAll(_numeroRegex, '');
  if (valor.isEmpty) return null;
  if (valor.contains(',') && valor.contains('.')) {
    if (valor.lastIndexOf(',') > valor.lastIndexOf('.')) {
      valor = valor.replaceAll('.', '').replaceAll(',', '.');
    } else {
      valor = valor.replaceAll(',', '');
    }
  } else if (valor.contains(',')) {
    valor = valor.replaceAll(',', '.');
  }
  return double.tryParse(valor);
}

final _dataBrasileiraRegex = RegExp(
  r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})'
  r'(?:[ ,T]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?',
);

DateTime? parseData(String texto) {
  final valor = texto.trim();
  if (valor.isEmpty) return null;

  final iso = DateTime.tryParse(valor);
  if (iso != null) return iso;

  final brasileira = _dataBrasileiraRegex.firstMatch(valor);
  if (brasileira != null) {
    return DateTime(
      int.parse(brasileira[3]!),
      int.parse(brasileira[2]!),
      int.parse(brasileira[1]!),
      int.tryParse(brasileira[4] ?? '') ?? 0,
      int.tryParse(brasileira[5] ?? '') ?? 0,
      int.tryParse(brasileira[6] ?? '') ?? 0,
    );
  }

  return DateTime.tryParse(valor.replaceFirst(' ', 'T'));
}

String formatarData(DateTime? data, {bool completa = false}) {
  if (data == null) return 'Data indisponível';
  String dois(int numero) => numero.toString().padLeft(2, '0');
  final dataHora =
      '${dois(data.day)}/${dois(data.month)}/${data.year} '
      '${dois(data.hour)}:${dois(data.minute)}';
  return completa ? '$dataHora:${dois(data.second)}' : dataHora;
}

List<List<String>> parseCsv(String texto) {
  final linhas = <List<String>>[];
  var linha = <String>[];
  final campo = StringBuffer();
  var entreAspas = false;

  for (var i = 0; i < texto.length; i++) {
    final caractere = texto[i];
    if (entreAspas) {
      if (caractere == '"') {
        if (i + 1 < texto.length && texto[i + 1] == '"') {
          campo.write('"');
          i++;
        } else {
          entreAspas = false;
        }
      } else {
        campo.write(caractere);
      }
    } else if (caractere == '"') {
      entreAspas = true;
    } else if (caractere == ',') {
      linha.add(campo.toString());
      campo.clear();
    } else if (caractere == '\n' || caractere == '\r') {
      if (caractere == '\r' &&
          i + 1 < texto.length &&
          texto[i + 1] == '\n') {
        i++;
      }
      linha.add(campo.toString());
      campo.clear();
      linhas.add(linha);
      linha = <String>[];
    } else {
      campo.write(caractere);
    }
  }

  if (campo.isNotEmpty || linha.isNotEmpty) {
    linha.add(campo.toString());
    linhas.add(linha);
  }
  return linhas;
}

class MonitorRioApp extends StatelessWidget {
  const MonitorRioApp({super.key});

  @override
  Widget build(BuildContext context) {
    final esquema = ColorScheme.fromSeed(
      seedColor: AppConfig.deepWater,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppConfig.deepWater,
      secondary: AppConfig.water,
      error: AppConfig.alert,
      surface: AppConfig.paper,
      onSurface: AppConfig.ink,
    );

    return MaterialApp(
      title: 'Monitor do Rio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: esquema,
        scaffoldBackgroundColor: AppConfig.mist,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppConfig.mist,
          foregroundColor: AppConfig.ink,
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: CardThemeData(
          color: AppConfig.paper,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: AppConfig.deepWater.withValues(alpha: 0.07)),
          ),
        ),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: AppConfig.ink,
          displayColor: AppConfig.ink,
        ),
      ),
      home: const PaginaMonitor(),
    );
  }
}

class PaginaMonitor extends StatefulWidget {
  const PaginaMonitor({super.key});

  @override
  State<PaginaMonitor> createState() => _PaginaMonitorState();
}

class _PaginaMonitorState extends State<PaginaMonitor>
    with WidgetsBindingObserver {
  List<Medicao> _medicoes = const [];
  bool _carregando = true;
  bool _atualizando = false;
  bool _preferenciasCarregadas = false;
  bool _notificacoesAtivas = true;
  bool _notificacoesInicializadas = false;
  bool? _permissaoNotificacoes;
  double _nivelAtencao = AppConfig.defaultAttentionLevelCm;
  double _nivelAlerta = AppConfig.defaultAlertLevelCm;
  String? _erro;
  String? _erroNotificacao;
  DateTime? _ultimaAtualizacao;
  DateTime? _ultimaNotificacao;
  String? _ultimoStatusNotificado;
  int _limiteGrafico = 50;
  Timer? _timer;
  final NotificationService _notificationService = NotificationService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inicializar();
    _timer = Timer.periodic(AppConfig.refreshInterval, (_) {
      if (_preferenciasCarregadas) _atualizar();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _preferenciasCarregadas) {
      _atualizar();
    }
  }

  Future<void> _inicializar() async {
    var nivelAtencao = AppConfig.defaultAttentionLevelCm;
    var nivelAlerta = AppConfig.defaultAlertLevelCm;
    var notificacoesAtivas = true;

    try {
      final preferencias = await SharedPreferences.getInstance();
      final salvoAtencao =
          preferencias.getDouble(AppConfig.attentionPreferenceKey);
      final salvoAlerta = preferencias.getDouble(AppConfig.alertPreferenceKey);
      if (salvoAtencao != null &&
          salvoAlerta != null &&
          salvoAtencao.isFinite &&
          salvoAlerta.isFinite &&
          salvoAtencao > 0 &&
          salvoAlerta > salvoAtencao) {
        nivelAtencao = salvoAtencao;
        nivelAlerta = salvoAlerta;
      }
      notificacoesAtivas =
          preferencias.getBool(AppConfig.notificationsPreferenceKey) ?? true;
    } catch (_) {
      // Usa os limites padrão se o armazenamento local não estiver disponível.
    }

    if (!mounted) return;
    setState(() {
      _nivelAtencao = nivelAtencao;
      _nivelAlerta = nivelAlerta;
      _notificacoesAtivas = notificacoesAtivas;
      _preferenciasCarregadas = true;
    });

    await _inicializarNotificacoes();
    await _atualizar();
  }

  Future<void> _inicializarNotificacoes() async {
    try {
      await _notificationService.initialize();
      final permissao = _notificacoesAtivas
          ? await _notificationService.requestPermission()
          : null;
      if (!mounted) return;
      setState(() {
        _notificacoesInicializadas = true;
        _permissaoNotificacoes = permissao;
        _erroNotificacao = null;
      });
      if (!_notificacoesAtivas) await _limparNotificacoes();
    } catch (erro) {
      if (!mounted) return;
      setState(() {
        _notificacoesInicializadas = false;
        _permissaoNotificacoes = _notificacoesAtivas ? false : null;
        _erroNotificacao = _notificacoesAtivas
            ? 'Não foi possível iniciar as notificações: $erro'
            : null;
      });
    }
  }

  Future<void> _atualizar() async {
    if (_atualizando || !_preferenciasCarregadas) return;
    setState(() => _atualizando = true);
    try {
      final dados = await carregarMedicoes(
        nivelAtencao: _nivelAtencao,
        nivelAlerta: _nivelAlerta,
      );
      if (!mounted) return;
      setState(() {
        _medicoes = dados;
        _erro = null;
        _carregando = false;
        _ultimaAtualizacao = DateTime.now();
      });
      if (dados.isNotEmpty) await _avaliarNotificacao(dados.last);
    } catch (erro) {
      if (!mounted) return;
      setState(() {
        _erro = erro is RiverMonitorException
            ? erro.message
            : erro.toString().replaceFirst(RegExp(r'^(Exception|Error):\s*'), '');
        _carregando = false;
      });
    } finally {
      if (mounted) {
        setState(() => _atualizando = false);
      } else {
        _atualizando = false;
      }
    }
  }

  Future<void> _avaliarNotificacao(
    Medicao medicao, {
    bool forcar = false,
  }) async {
    if (!_notificacoesInicializadas) return;
    if (!_notificacoesAtivas) return;
    if (_permissaoNotificacoes != true) return;

    if (medicao.isNormal) {
      await _limparNotificacoes();
      _ultimoStatusNotificado = null;
      _ultimaNotificacao = null;
      return;
    }

    final agora = DateTime.now();
    final intervalo = medicao.isAlerta
        ? AppConfig.alertReminderInterval
        : AppConfig.attentionReminderInterval;
    final mudouDeFaixa = _ultimoStatusNotificado != medicao.status;
    final lembreteVencido = _ultimaNotificacao == null ||
        agora.difference(_ultimaNotificacao!) >= intervalo;
    if (!forcar && !mudouDeFaixa && !lembreteVencido) return;

    try {
      if (medicao.isAlerta) {
        await _notificationService.showAlert(medicao.nivel);
      } else {
        await _notificationService.showAttention(medicao.nivel);
      }
      _ultimoStatusNotificado = medicao.status;
      _ultimaNotificacao = agora;
      _erroNotificacao = null;
    } catch (erro) {
      _erroNotificacao = 'Falha ao emitir notificação: $erro';
    }
    if (mounted) setState(() {});
  }

  Future<void> _limparNotificacoes() async {
    try {
      await _notificationService.clear();
      _erroNotificacao = null;
    } catch (erro) {
      _erroNotificacao = 'Falha ao remover notificações: $erro';
    }
    if (mounted) setState(() {});
  }

  Future<void> _solicitarPermissaoNotificacoes({
    bool emitirAvisoAtual = true,
  }) async {
    try {
      if (!_notificacoesInicializadas) {
        await _notificationService.initialize();
        _notificacoesInicializadas = true;
      }
      final permitidas = await _notificationService.requestPermission();
      if (!mounted) return;
      setState(() {
        _permissaoNotificacoes = permitidas;
        _erroNotificacao = null;
      });
      if (emitirAvisoAtual && permitidas && _medicoes.isNotEmpty) {
        await _avaliarNotificacao(_medicoes.last, forcar: true);
      }
    } catch (erro) {
      if (!mounted) return;
      setState(() => _erroNotificacao = 'Falha ao pedir permissão: $erro');
    }
  }

  Future<void> _abrirConfiguracoes() async {
    final novaConfiguracao =
        await showModalBottomSheet<_ConfiguracaoMonitoramento>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppConfig.paper,
      builder: (context) => _ConfiguracoesSheet(
        nivelAtencao: _nivelAtencao,
        nivelAlerta: _nivelAlerta,
        notificacoesAtivas: _notificacoesAtivas,
      ),
    );
    if (novaConfiguracao == null || !mounted) return;

    try {
      final preferencias = await SharedPreferences.getInstance();
      await preferencias.setDouble(
        AppConfig.attentionPreferenceKey,
        novaConfiguracao.nivelAtencao,
      );
      await preferencias.setDouble(
        AppConfig.alertPreferenceKey,
        novaConfiguracao.nivelAlerta,
      );
      await preferencias.setBool(
        AppConfig.notificationsPreferenceKey,
        novaConfiguracao.notificacoesAtivas,
      );
    } catch (erro) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Não foi possível salvar as configurações: $erro'),
        ),
      );
      return;
    }

    final classificadas = _medicoes
        .map(
          (medicao) => medicao.comStatus(
            statusPorNivel(
              medicao.nivel,
              nivelAtencao: novaConfiguracao.nivelAtencao,
              nivelAlerta: novaConfiguracao.nivelAlerta,
            ),
          ),
        )
        .toList();
    setState(() {
      _nivelAtencao = novaConfiguracao.nivelAtencao;
      _nivelAlerta = novaConfiguracao.nivelAlerta;
      _notificacoesAtivas = novaConfiguracao.notificacoesAtivas;
      _medicoes = classificadas;
    });

    if (_notificacoesAtivas) {
      await _solicitarPermissaoNotificacoes(emitirAvisoAtual: false);
    } else {
      await _limparNotificacoes();
      _ultimoStatusNotificado = null;
      _ultimaNotificacao = null;
      if (mounted) {
        setState(() {
          _permissaoNotificacoes = null;
          _erroNotificacao = null;
        });
      }
    }
    if (_medicoes.isNotEmpty) {
      await _avaliarNotificacao(_medicoes.last, forcar: true);
    }
  }

  List<Medicao> get _medicoesDoGrafico {
    if (_limiteGrafico == 0 || _medicoes.length <= _limiteGrafico) {
      return _medicoes;
    }
    return _medicoes.sublist(_medicoes.length - _limiteGrafico);
  }

  @override
  Widget build(BuildContext context) {
    final atual = _medicoes.isEmpty ? null : _medicoes.last;
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(
            child: ColoredBox(color: AppConfig.mist),
          ),
          if (atual != null)
            Positioned.fill(
              child: PainelAgua(
                status: atual.status,
                nivel: atual.nivel,
                nivelAtencao: _nivelAtencao,
                nivelAlerta: _nivelAlerta,
              ),
            ),
          SafeArea(
            child: _carregando && _medicoes.isEmpty
                ? const _CarregandoInicial()
                : RefreshIndicator(
                    color: AppConfig.water,
                    onRefresh: _atualizar,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                      children: [
                        _Cabecalho(
                          atualizando: _atualizando,
                          onRefresh: _atualizar,
                          onSettings: _abrirConfiguracoes,
                        ),
                        const SizedBox(height: 20),
                        if (_notificacoesAtivas &&
                            _permissaoNotificacoes == false) ...[
                          _AvisoPermissaoNotificacoes(
                            aoSolicitar: _solicitarPermissaoNotificacoes,
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (_erroNotificacao != null) ...[
                          _AvisoErro(
                            mensagem: _erroNotificacao!,
                            aoTentar: _solicitarPermissaoNotificacoes,
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (_erro != null) ...[
                          _AvisoErro(mensagem: _erro!, aoTentar: _atualizar),
                          const SizedBox(height: 14),
                        ],
                        if (_medicoes.isEmpty)
                          _SemDados(
                            carregando: _carregando,
                            aoTentar: _atualizar,
                          )
                        else ...[
                          CartaoMedicaoAtual(
                            medicao: atual!,
                            nivelAtencao: _nivelAtencao,
                            nivelAlerta: _nivelAlerta,
                          ),
                          const SizedBox(height: 16),
                          CartaoResumo(medicoes: _medicoesDoGrafico),
                          const SizedBox(height: 16),
                          CartaoGrafico(
                            medicoes: _medicoesDoGrafico,
                            limite: _limiteGrafico,
                            nivelAtencao: _nivelAtencao,
                            nivelAlerta: _nivelAlerta,
                            aoMudarLimite: (valor) =>
                                setState(() => _limiteGrafico = valor),
                          ),
                          const SizedBox(height: 16),
                          CartaoHistorico(medicoes: _medicoes),
                          const SizedBox(height: 18),
                          Text(
                            '${_medicoes.length} medições • atualizado '
                            '${formatarData(_ultimaAtualizacao, completa: true)}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppConfig.mutedInk,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Cabecalho extends StatelessWidget {
  const _Cabecalho({
    required this.atualizando,
    required this.onRefresh,
    required this.onSettings,
  });

  final bool atualizando;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: AppConfig.deepWater,
            borderRadius: BorderRadius.circular(15),
          ),
          child: const Icon(Icons.water_drop_rounded, color: Colors.white),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Monitor do rio',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 2),
              Text(
                'Acompanhamento do nível da água',
                style: TextStyle(fontSize: 12, color: AppConfig.mutedInk),
              ),
            ],
          ),
        ),
        IconButton.filledTonal(
          tooltip: 'Configurar limites e notificações',
          onPressed: onSettings,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.8),
            foregroundColor: AppConfig.deepWater,
          ),
          icon: const Icon(Icons.tune_rounded),
        ),
        IconButton.filledTonal(
          tooltip: 'Atualizar medições',
          onPressed: atualizando ? null : onRefresh,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.8),
            foregroundColor: AppConfig.deepWater,
          ),
          icon: atualizando
              ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
              : const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }
}

class _CarregandoInicial extends StatelessWidget {
  const _CarregandoInicial();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppConfig.water),
          SizedBox(height: 14),
          Text('Buscando as medições…'),
        ],
      ),
    );
  }
}

class _SemDados extends StatelessWidget {
  const _SemDados({required this.carregando, required this.aoTentar});

  final bool carregando;
  final VoidCallback aoTentar;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 42,
              color: AppConfig.deepWater,
            ),
            const SizedBox(height: 12),
            const Text(
              'Ainda não há medições disponíveis',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Verifique o acesso de leitura à planilha e tente novamente.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppConfig.mutedInk),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: carregando ? null : aoTentar,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvisoErro extends StatelessWidget {
  const _AvisoErro({required this.mensagem, required this.aoTentar});

  final String mensagem;
  final VoidCallback aoTentar;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppConfig.alert.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppConfig.alert),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                mensagem,
                style: const TextStyle(color: AppConfig.ink, fontSize: 13),
              ),
            ),
            IconButton(
              onPressed: aoTentar,
              tooltip: 'Tentar novamente',
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvisoPermissaoNotificacoes extends StatelessWidget {
  const _AvisoPermissaoNotificacoes({required this.aoSolicitar});

  final VoidCallback aoSolicitar;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppConfig.sage.withValues(alpha: 0.2),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.notifications_off_outlined,
              color: AppConfig.deepWater,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Permita notificações nas configurações do Android para receber os avisos.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: aoSolicitar,
              child: const Text('Tentar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfiguracaoMonitoramento {
  const _ConfiguracaoMonitoramento({
    required this.nivelAtencao,
    required this.nivelAlerta,
    required this.notificacoesAtivas,
  });

  final double nivelAtencao;
  final double nivelAlerta;
  final bool notificacoesAtivas;
}

class _ConfiguracoesSheet extends StatefulWidget {
  const _ConfiguracoesSheet({
    required this.nivelAtencao,
    required this.nivelAlerta,
    required this.notificacoesAtivas,
  });

  final double nivelAtencao;
  final double nivelAlerta;
  final bool notificacoesAtivas;

  @override
  State<_ConfiguracoesSheet> createState() => _ConfiguracoesSheetState();
}

class _ConfiguracoesSheetState extends State<_ConfiguracoesSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _atencaoController;
  late final TextEditingController _alertaController;
  late bool _notificacoesAtivas;
  String? _erroLimites;

  @override
  void initState() {
    super.initState();
    _atencaoController = TextEditingController(
      text: formatarLimite(widget.nivelAtencao),
    );
    _alertaController = TextEditingController(
      text: formatarLimite(widget.nivelAlerta),
    );
    _notificacoesAtivas = widget.notificacoesAtivas;
  }

  @override
  void dispose() {
    _atencaoController.dispose();
    _alertaController.dispose();
    super.dispose();
  }

  String? _validarNumero(String? texto) {
    final valor = parseNumero(texto ?? '');
    if (valor == null || !valor.isFinite || valor <= 0 || valor > 100000) {
      return 'Informe um valor entre 0 e 100.000 cm.';
    }
    return null;
  }

  void _salvar() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final nivelAtencao = parseNumero(_atencaoController.text)!;
    final nivelAlerta = parseNumero(_alertaController.text)!;
    if (nivelAlerta <= nivelAtencao) {
      setState(() {
        _erroLimites = 'O início do alerta deve ser maior que o da atenção.';
      });
      return;
    }

    Navigator.of(context).pop(
      _ConfiguracaoMonitoramento(
        nivelAtencao: nivelAtencao,
        nivelAlerta: nivelAlerta,
        notificacoesAtivas: _notificacoesAtivas,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final atencao =
        parseNumero(_atencaoController.text) ?? widget.nivelAtencao;
    final alerta = parseNumero(_alertaController.text) ?? widget.nivelAlerta;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppConfig.mist,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Row(
                  children: [
                    Icon(Icons.tune_rounded, color: AppConfig.deepWater),
                    SizedBox(width: 10),
                    Text(
                      'Configurações do monitor',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Os limites ficam salvos somente neste aparelho.',
                  style: TextStyle(color: AppConfig.mutedInk, fontSize: 12),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _atencaoController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.next,
                  validator: _validarNumero,
                  onChanged: (_) => setState(() => _erroLimites = null),
                  decoration: const InputDecoration(
                    labelText: 'Atenção começa em',
                    suffixText: 'cm',
                    border: OutlineInputBorder(),
                    helperText: 'Abaixo deste valor, o nível é normal.',
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _alertaController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  validator: _validarNumero,
                  onChanged: (_) => setState(() => _erroLimites = null),
                  onFieldSubmitted: (_) => _salvar(),
                  decoration: const InputDecoration(
                    labelText: 'Alerta começa em',
                    suffixText: 'cm',
                    border: OutlineInputBorder(),
                    helperText: 'De atenção até este ponto, o estado é atenção.',
                  ),
                ),
                if (_erroLimites != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _erroLimites!,
                    style: const TextStyle(
                      color: AppConfig.alert,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: AppConfig.mist,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'NORMAL  < ${formatarLimite(atencao)} cm\n'
                    'ATENÇÃO  ${formatarLimite(atencao)}–'
                    '< ${formatarLimite(alerta)} cm\n'
                    'ALERTA  ≥ ${formatarLimite(alerta)} cm',
                    style: const TextStyle(
                      color: AppConfig.deepWater,
                      fontSize: 12,
                      height: 1.6,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _notificacoesAtivas,
                  onChanged: (valor) =>
                      setState(() => _notificacoesAtivas = valor),
                  activeThumbColor: AppConfig.water,
                  title: const Text(
                    'Notificações no celular',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'Alerta: som e vibração a cada 2 min. '
                    'Atenção: silenciosa a cada 15 min.',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Os lembretes dependem do app estar aberto e atualizando as medições.',
                  style: TextStyle(color: AppConfig.mutedInk, fontSize: 11),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _salvar,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Salvar configurações'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CartaoMedicaoAtual extends StatelessWidget {
  const CartaoMedicaoAtual({
    super.key,
    required this.medicao,
    required this.nivelAtencao,
    required this.nivelAlerta,
  });

  final Medicao medicao;
  final double nivelAtencao;
  final double nivelAlerta;

  @override
  Widget build(BuildContext context) {
    final progresso =
        (medicao.nivel / nivelAlerta).clamp(0.0, 1.0).toDouble();

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppConfig.deepWater, AppConfig.water],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: AppConfig.deepWater.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'LEITURA MAIS RECENTE',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _SeloStatus(medicao: medicao),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  medicao.nivel.toStringAsFixed(1),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 52,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.5,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 8, bottom: 5),
                child: Text(
                  'cm',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Nível da água',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 19),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: progresso,
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.22),
              valueColor: const AlwaysStoppedAnimation<Color>(AppConfig.mist),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Atenção ${formatarLimite(nivelAtencao)} cm',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              Text(
                'Alerta ${formatarLimite(nivelAlerta)} cm',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              _InfoAtual(
                icone: Icons.straighten_rounded,
                texto: 'Distância  ${medicao.distancia?.toStringAsFixed(1) ?? '--'} cm',
              ),
              _InfoAtual(
                icone: medicao.sensorLigado
                    ? Icons.sensors_rounded
                    : Icons.sensors_off_rounded,
                texto: 'Sensor  ${medicao.sensor.isEmpty ? '—' : medicao.sensor}',
              ),
            ],
          ),
          const SizedBox(height: 11),
          Text(
            formatarData(medicao.data, completa: true),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SeloStatus extends StatelessWidget {
  const _SeloStatus({required this.medicao});

  final Medicao medicao;

  @override
  Widget build(BuildContext context) {
    final badgeColor = medicao.isAlerta
        ? AppConfig.alert
        : medicao.isAtencao
        ? AppConfig.sage
        : AppConfig.water;
    final foreground = medicao.isAtencao ? AppConfig.ink : Colors.white;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: badgeColor,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            medicao.isAlerta ? Icons.warning_rounded : Icons.water_drop_rounded,
            size: 14,
            color: foreground,
          ),
          const SizedBox(width: 5),
          Text(
            medicao.status,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoAtual extends StatelessWidget {
  const _InfoAtual({required this.icone, required this.texto});

  final IconData icone;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icone, size: 15, color: Colors.white70),
        const SizedBox(width: 5),
        Text(
          texto,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ],
    );
  }
}

class CartaoResumo extends StatelessWidget {
  const CartaoResumo({super.key, required this.medicoes});

  final List<Medicao> medicoes;

  @override
  Widget build(BuildContext context) {
    if (medicoes.isEmpty) return const SizedBox.shrink();

    double minimo = medicoes.first.nivel;
    double maximo = medicoes.first.nivel;
    double soma = 0.0;

    for (final item in medicoes) {
      final n = item.nivel;
      if (n < minimo) minimo = n;
      if (n > maximo) maximo = n;
      soma += n;
    }
    final media = soma / medicoes.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 10),
        child: Row(
          children: [
            Expanded(
              child: _ResumoItem(
                titulo: 'MÍNIMO',
                valor: minimo.toStringAsFixed(1),
              ),
            ),
            const _Divisor(),
            Expanded(
              child: _ResumoItem(
                titulo: 'MÉDIA',
                valor: media.toStringAsFixed(1),
              ),
            ),
            const _Divisor(),
            Expanded(
              child: _ResumoItem(
                titulo: 'MÁXIMO',
                valor: maximo.toStringAsFixed(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResumoItem extends StatelessWidget {
  const _ResumoItem({required this.titulo, required this.valor});

  final String titulo;
  final String valor;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          titulo,
          style: const TextStyle(
            color: AppConfig.mutedInk,
            fontSize: 10,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$valor cm',
          maxLines: 1,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class _Divisor extends StatelessWidget {
  const _Divisor();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 34, color: AppConfig.mist);
  }
}

class CartaoGrafico extends StatelessWidget {
  const CartaoGrafico({
    super.key,
    required this.medicoes,
    required this.limite,
    required this.nivelAtencao,
    required this.nivelAlerta,
    required this.aoMudarLimite,
  });

  final List<Medicao> medicoes;
  final int limite;
  final double nivelAtencao;
  final double nivelAlerta;
  final ValueChanged<int> aoMudarLimite;

  @override
  Widget build(BuildContext context) {
    if (medicoes.isEmpty) return const SizedBox.shrink();

    final pontos = <FlSpot>[];
    double maiorNivel = 0.0;

    for (var i = 0; i < medicoes.length; i++) {
      final nivel = medicoes[i].nivel;
      pontos.add(FlSpot(i.toDouble(), nivel));
      if (nivel > maiorNivel) maiorNivel = nivel;
    }

    final maxY = math.max(
      maiorNivel * 1.15,
      nivelAlerta * 1.15,
    ).toDouble();
    final maxX = math.max(1.0, (medicoes.length - 1).toDouble()).toDouble();
    final intervaloX = math.max(1.0, medicoes.length / 4).toDouble();
    final intervaloY = math.max(1.0, maxY / 4).toDouble();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 17, 16, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Variação do nível',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Medições ao longo do tempo',
                        style: TextStyle(
                          color: AppConfig.mutedInk,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<int>(
                  tooltip: 'Período do gráfico',
                  onSelected: aoMudarLimite,
                  initialValue: limite,
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 50, child: Text('Últimas 50')),
                    PopupMenuItem(value: 200, child: Text('Últimas 200')),
                    PopupMenuItem(value: 0, child: Text('Todas')),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppConfig.mist,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          limite == 0 ? 'Todas' : '$limite',
                          style: const TextStyle(
                            color: AppConfig.deepWater,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 3),
                        const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 17,
                          color: AppConfig.deepWater,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 225,
              child: LineChart(
                LineChartData(
                  minY: 0,
                  maxY: maxY,
                  minX: 0,
                  maxX: maxX,
                  borderData: FlBorderData(show: false),
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    horizontalInterval: intervaloY,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: AppConfig.deepWater.withValues(alpha: 0.08),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 37,
                        interval: intervaloY,
                        getTitlesWidget: (value, meta) => Text(
                          value.toStringAsFixed(0),
                          style: const TextStyle(
                            color: AppConfig.mutedInk,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 32,
                        interval: intervaloX,
                        getTitlesWidget: (value, meta) {
                          final indice = value.round();
                          if (indice < 0 || indice >= medicoes.length) {
                            return const SizedBox.shrink();
                          }
                          final data = medicoes[indice].data;
                          if (data == null) return const SizedBox.shrink();
                          final rotulo =
                              '${data.day.toString().padLeft(2, '0')}/'
                              '${data.month.toString().padLeft(2, '0')}';
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              rotulo,
                              style: const TextStyle(
                                color: AppConfig.mutedInk,
                                fontSize: 9,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (itens) => itens.map((item) {
                        final indice = item.x.round();
                        if (indice < 0 || indice >= medicoes.length) {
                          return null;
                        }
                        final medida = medicoes[indice];
                        return LineTooltipItem(
                          '${medida.nivel.toStringAsFixed(1)} cm\n'
                              '${formatarData(medida.data, completa: true)}',
                          const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  extraLinesData: ExtraLinesData(
                    horizontalLines: [
                      _linhaLimite(
                        nivelAtencao,
                        AppConfig.sage,
                        'Atenção',
                      ),
                      _linhaLimite(
                        nivelAlerta,
                        AppConfig.alert,
                        'Alerta',
                      ),
                    ],
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: pontos,
                      isCurved: true,
                      curveSmoothness: 0.18,
                      barWidth: 3,
                      color: AppConfig.water,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            AppConfig.water.withValues(alpha: 0.22),
                            AppConfig.water.withValues(alpha: 0.01),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  HorizontalLine _linhaLimite(double nivel, Color cor, String rotulo) {
    return HorizontalLine(
      y: nivel,
      color: cor,
      strokeWidth: 1.2,
      dashArray: const [6, 4],
      label: HorizontalLineLabel(
        show: true,
        alignment: Alignment.topRight,
        style: TextStyle(
          color: cor,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
        labelResolver: (_) => rotulo,
      ),
    );
  }
}

class CartaoHistorico extends StatelessWidget {
  const CartaoHistorico({super.key, required this.medicoes});

  final List<Medicao> medicoes;

  @override
  Widget build(BuildContext context) {
    final ultimas = medicoes.reversed.take(10).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 15, 15, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 2, bottom: 7),
              child: Text(
                'Últimas medições',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            for (var i = 0; i < ultimas.length; i++) ...[
              _LinhaHistorico(medicao: ultimas[i]),
              if (i != ultimas.length - 1)
                Divider(
                  height: 1,
                  color: AppConfig.deepWater.withValues(alpha: 0.08),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LinhaHistorico extends StatelessWidget {
  const _LinhaHistorico({required this.medicao});

  final Medicao medicao;

  @override
  Widget build(BuildContext context) {
    final cor = corDoStatus(medicao.status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: cor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${medicao.nivel.toStringAsFixed(1)} cm  •  ${medicao.status}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  formatarData(medicao.data, completa: true),
                  style: const TextStyle(
                    color: AppConfig.mutedInk,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (medicao.distancia != null)
            Text(
              '${medicao.distancia!.toStringAsFixed(1)} cm',
              style: const TextStyle(
                color: AppConfig.mutedInk,
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }
}

class PainelAgua extends StatefulWidget {
  const PainelAgua({
    super.key,
    required this.status,
    required this.nivel,
    required this.nivelAtencao,
    required this.nivelAlerta,
  });

  final String status;
  final double nivel;
  final double nivelAtencao;
  final double nivelAlerta;

  @override
  State<PainelAgua> createState() => _PainelAguaState();
}

class _PainelAguaState extends State<PainelAgua>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animacao;

  @override
  void initState() {
    super.initState();
    _animacao = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    )..repeat();
  }

  @override
  void dispose() {
    _animacao.dispose();
    super.dispose();
  }

  double get _alturaRelativa {
    final status = normalizar(widget.status);
    if (status == 'alerta') {
      final progresso =
          ((widget.nivel - widget.nivelAlerta) / widget.nivelAlerta)
          .clamp(0.0, 1.0)
          .toDouble();
      return 0.40 + progresso * 0.25;
    }
    if (status == 'atencao') {
      final progresso = ((widget.nivel - widget.nivelAtencao) /
              (widget.nivelAlerta - widget.nivelAtencao))
          .clamp(0.0, 1.0)
          .toDouble();
      return 0.16 + progresso * 0.18;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final relacao = _alturaRelativa;
    if (relacao <= 0) return const SizedBox.shrink();

    final alerta = normalizar(widget.status) == 'alerta';
    final altura = MediaQuery.sizeOf(context).height * relacao;
    return Align(
      alignment: Alignment.bottomCenter,
      child: IgnorePointer(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 1100),
          curve: Curves.easeInOutCubic,
          height: altura,
          width: double.infinity,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _animacao,
              builder: (context, child) => CustomPaint(
                painter: _OndasAguaPainter(
                  deslocamento: _animacao.value,
                  cor: alerta ? AppConfig.deepWater : AppConfig.water,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OndasAguaPainter extends CustomPainter {
  const _OndasAguaPainter({required this.deslocamento, required this.cor});

  final double deslocamento;
  final Color cor;

  @override
  void paint(Canvas canvas, Size size) {
    final tinta = Paint()..color = cor.withValues(alpha: 0.13);
    final tintaClara = Paint()..color = AppConfig.sage.withValues(alpha: 0.16);
    _desenharOnda(
      canvas,
      size,
      tintaClara,
      deslocamento,
      amplitude: 9,
      base: 15,
    );
    _desenharOnda(
      canvas,
      size,
      tinta,
      (deslocamento + 0.36) % 1,
      amplitude: 12,
      base: 23,
    );
  }

  void _desenharOnda(
      Canvas canvas,
      Size size,
      Paint tinta,
      double fase, {
        required double amplitude,
        required double base,
      }) {
    final caminho = Path()..moveTo(0, base);
    const twoPi = 2 * math.pi;
    final faseAngle = fase * twoPi;
    final width = size.width;

    for (var x = 0.0; x <= width; x += 3) {
      final angulo = (x / width * twoPi) + faseAngle;
      final y = base + math.sin(angulo) * amplitude;
      caminho.lineTo(x, y);
    }
    caminho
      ..lineTo(width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(caminho, tinta);
  }

  @override
  bool shouldRepaint(covariant _OndasAguaPainter oldDelegate) =>
      oldDelegate.deslocamento != deslocamento || oldDelegate.cor != cor;
}
