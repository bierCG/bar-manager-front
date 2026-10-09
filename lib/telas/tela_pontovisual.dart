import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth.dart';
import '../config.dart';

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

        if (DateTime.now().difference(_ultimoPong!) >
            const Duration(seconds: 10)) {
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
        Uri.parse('$urlWs/ws/bar?token=$token'),
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

  @override
  Widget build(BuildContext context) {
    // Pedidos entregues não aparecem para o cliente.
    final pedidosVisiveis =
        pedidos.where((p) => p['status'] != 'ENTREGUE').toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ponto Visual'),
        actions: [
          IconButton(
            tooltip: 'Simular desconexão',
            icon: const Icon(Icons.wifi_off),
            onPressed: () {
              debugPrint('>>> TESTE: fechando canal manualmente');
              channel?.sink.close();
            },
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: pedidosVisiveis.length,
        itemBuilder: (context, index) {
          final p = pedidosVisiveis[index];
          final bool pronto = p['status'] == 'PRONTO';

          return Container(
            margin: const EdgeInsets.only(
              bottom: 10,
              left: 16,
              right: 16,
            ),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${p['cliente_nome']} • ${p['drink']}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      pronto ? 'PRONTO' : 'AGUARDANDO',
                      style: TextStyle(
                        color: pronto
                            ? Colors.greenAccent
                            : const Color(0xFFFF6E40),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Icon(
                  pronto ? Icons.check_circle : Icons.hourglass_top,
                  color: pronto
                      ? Colors.greenAccent
                      : const Color(0xFFFF5722),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}