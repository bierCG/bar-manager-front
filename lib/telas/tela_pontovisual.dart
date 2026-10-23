import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth.dart';
import '../config.dart';

import 'package:google_fonts/google_fonts.dart';

class PontoVisual extends StatefulWidget {
  const PontoVisual({super.key});

  @override
  State<PontoVisual> createState() => _PontoVisualState();
}

class _PontoVisualState extends State<PontoVisual> {
  WebSocketChannel? channel;
  StreamSubscription? _webSocketSubscription;

  List<Map<String, dynamic>> pedidos = [];

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  DateTime? _ultimoPong;

  bool _mostrandoDesconectado = false;
  bool conectado = false;
  bool _encerrando = false;

  @override
  void initState() {
    super.initState();
    carregarHistoricoHTTP();
    conectarWebSocket();
  }

  // ---------------------------------------------------------------------------
  // STATUS DE CONEXÃO
  // ---------------------------------------------------------------------------

  void statusConexao() {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);

    if (_mostrandoDesconectado) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Desconectado'),
            duration: Duration(days: 1),
          ),
        );
    } else {
      messenger.clearSnackBars();
    }
  }

  // ---------------------------------------------------------------------------
  // HEARTBEAT
  // ---------------------------------------------------------------------------

  void iniciarHeartbeat() {
    _heartbeatTimer?.cancel();

    _ultimoPong = DateTime.now();

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (channel == null) return;

        if (DateTime.now().difference(_ultimoPong!) > tempoLimitePong) {
          _conexaoPerdida();
          return;
        }

        try {
          channel!.sink.add(
            jsonEncode({
              'event': 'PING',
            }),
          );
        } catch (_) {
          _conexaoPerdida();
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // QUEDA E RECONEXÃO
  // ---------------------------------------------------------------------------

  void _conexaoPerdida() {
    if (_encerrando) return;

    _heartbeatTimer?.cancel();

    _webSocketSubscription?.cancel();
    _webSocketSubscription = null;

    channel?.sink.close();
    channel = null;

    if (mounted) {
      setState(() {
        conectado = false;
      });

      if (!_mostrandoDesconectado) {
        _mostrandoDesconectado = true;
        statusConexao();
      }
    }

    _tentarReconectar();
  }

  void _tentarReconectar() {
    if (_encerrando) return;

    _reconnectTimer?.cancel();

    _reconnectTimer = Timer(
      const Duration(seconds: 5),
      () {
        if (mounted && !conectado) {
          conectarWebSocket();
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------------

  Future<void> carregarHistoricoHTTP() async {
    try {
      final response = await http.get(
        Uri.parse('$urlHttp/pedidos/'),
        headers: {
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode != 200) return;

      final dados = jsonDecode(response.body);

      if (dados is! List) return;
      if (!mounted) return;

      setState(() {
        pedidos = dados
            .map((p) => Map<String, dynamic>.from(p))
            .toList();
      });
    } catch (e) {
      debugPrint('Erro ao carregar histórico via HTTP: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // WEBSOCKET
  // ---------------------------------------------------------------------------

  Future<void> conectarWebSocket() async {
    if (_encerrando) return;

    try {
      await _webSocketSubscription?.cancel();
      _webSocketSubscription = null;

      channel?.sink.close();

      final novoChannel = WebSocketChannel.connect(
        Uri.parse('$urlWsM/ws/bar?token=$token'),
      );

      channel = novoChannel;

      await novoChannel.ready;

      if (!mounted || channel != novoChannel) {
        novoChannel.sink.close();
        return;
      }

      // Assina o stream ANTES do pull, para não perder eventos no intervalo.
      _webSocketSubscription = novoChannel.stream.listen(
        (mensagem) {
          if (!mounted || channel != novoChannel) return;

          try {
            final dados = jsonDecode(mensagem);

            if (dados is! Map<String, dynamic>) return;

            final evento = dados['event'];

            if (evento == 'PONG') {
              _ultimoPong = DateTime.now();
              return;
            }

            if (evento != 'pedido.created' && evento != 'pedido.updated') {
              return;
            }

            final payload = dados['payload'];

            if (payload is! Map<String, dynamic>) return;

            setState(() {
              if (evento == 'pedido.created') {
                final jaExiste = pedidos.any(
                  (p) => p['id'] == payload['id'],
                );

                if (!jaExiste) {
                  pedidos.insert(0, payload);
                }
              } else if (evento == 'pedido.updated') {
                final index = pedidos.indexWhere(
                  (p) => p['id'] == payload['id'],
                );

                if (index != -1) {
                  pedidos[index]['status'] = payload['status'];
                }
              }
            });
          } catch (e) {
            debugPrint('Erro ao processar mensagem WebSocket: $e');
          }
        },
        onDone: () {
          if (channel == novoChannel) {
            _conexaoPerdida();
          }
        },
        onError: (_) {
          if (channel == novoChannel) {
            _conexaoPerdida();
          }
        },
        cancelOnError: true,
      );

      setState(() {
        conectado = true;
      });

      _mostrandoDesconectado = false;
      statusConexao();

      _reconnectTimer?.cancel();

      iniciarHeartbeat();

      // Pull de reconexão: substitui a lista pelo estado atual.
      await carregarHistoricoHTTP();
    } catch (e) {
      debugPrint('Erro ao conectar WebSocket: $e');
      _conexaoPerdida();
    }
  }

  // ---------------------------------------------------------------------------
  // CICLO DE VIDA
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _encerrando = true;

    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _webSocketSubscription?.cancel();

    channel?.sink.close();

    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  Widget _construirPainel({
    required String titulo,
    String? subtitulo,
    required IconData icone,
    required Color cor,
    required List<Map<String, dynamic>> lista,
    required bool compacto,
    bool destacarPrimeiro = false,
  }) {
    return Container(
      padding: EdgeInsets.all(compacto ? 10 : 16),
      decoration: BoxDecoration(
        color: const Color(0xFF151517),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cor.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Icon(icone, color: cor, size: compacto ? 24 : 38),
              SizedBox(width: compacto ? 6 : 10),
              Flexible(
                child: Text(
                  titulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.oswald(
                    color: cor,
                    fontSize: compacto ? 26 : 46,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ),
              if (subtitulo != null) ...[
                SizedBox(width: compacto ? 6 : 12),
                Flexible(
                  child: Text(
                    subtitulo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.oswald(
                      color: cor.withOpacity(0.9),
                      fontSize: compacto ? 12 : 20,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Divider(color: Colors.white.withOpacity(0.08), height: 1),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: lista.length,
              itemBuilder: (context, index) => _construirCardPedido(
                lista[index],
                cor,
                compacto,
                destaque: destacarPrimeiro && index == 0,
              ),
            ),
          ),
        ],
      ),
    );
  }


  Widget _construirCardPedido(
    Map<String, dynamic> p,
    Color cor,
    bool compacto, {
    bool destaque = false,
  }) {
    final String cliente = (p['cliente_nome'] ?? '').toString().toUpperCase();
    final String drink = (p['drink'] ?? '').toString().toUpperCase();

    final estilo = GoogleFonts.oswald(
      fontSize: compacto ? 17 : 28,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
    );

    return Container(
      margin: EdgeInsets.only(bottom: compacto ? 10 : 14),
      padding: EdgeInsets.symmetric(
        horizontal: compacto ? 12 : 18,
        vertical: compacto ? 12 : 16,
      ),
      decoration: BoxDecoration(
        color: destaque ? const Color(0xFF262628) : const Color(0xFF1E1E20),
        borderRadius: BorderRadius.circular(8),
        border: destaque ? Border.all(color: cor, width: 1.5) : null,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: cliente,
              style: estilo.copyWith(color: const Color(0xFFE6E6E6)),
            ),
            TextSpan(
              text: '  •  ',
              style: estilo.copyWith(color: cor.withOpacity(0.6)),
            ),
            TextSpan(
              text: drink,
              style: estilo.copyWith(color: cor),
            ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Pedidos entregues não aparecem para o cliente.
    final preparando = pedidos
        .where((p) => p['status'] != 'PRONTO' && p['status'] != 'ENTREGUE')
        .toList();
    final prontos = pedidos.where((p) => p['status'] == 'PRONTO').toList();

    final bool compacto = MediaQuery.of(context).size.width < 600;
    final double gap = compacto ? 8 : 16;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0F),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(gap),
          child: Column(
            children: [
              Image.asset(
                'assets/logo.png',
                height: compacto ? 80 : 150,
              ),
              SizedBox(height: gap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _construirPainel(
                        titulo: 'PREPARANDO',
                        icone: Icons.local_fire_department_outlined,
                        cor: const Color(0xFFFFB366),
                        lista: preparando,
                        compacto: compacto,
                      ),
                    ),
                    SizedBox(width: gap),
                    Expanded(
                      child: _construirPainel(
                        titulo: 'PRONTO',
                        subtitulo: '(RETIRAR NO BALCÃO)',
                        icone: Icons.verified_outlined,
                        cor: const Color(0xFF00E58A),
                        lista: prontos,
                        compacto: compacto,
                        destacarPrimeiro: true,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}