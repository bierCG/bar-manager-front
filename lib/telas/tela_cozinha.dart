import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth.dart';
import '../config.dart';

class TelaCozinha extends StatefulWidget {
  const TelaCozinha({super.key});

  @override
  State<TelaCozinha> createState() => _TelaCozinhaState();
}

class _TelaCozinhaState extends State<TelaCozinha> {
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

  void statusConexao() {
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

  Future<void> carregarHistoricoHTTP() async {
    try {
      final response = await http.get(
        Uri.parse('$urlHttp/pedidos/'),
        headers: {
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode != 200) {
        return;
      }

      final dados = jsonDecode(response.body);

      if (dados is! List) return;

      if (!mounted) return;

      setState(() {
        pedidos = dados
            .map(
              (p) => Map<String, dynamic>.from(p),
            )
            .toList();
      });
    } catch (e) {
      debugPrint('Erro ao carregar histórico via HTTP: $e');
    }
  }

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

      setState(() {
        conectado = true;
      });

      _mostrandoDesconectado = false;
      statusConexao();

      _reconnectTimer?.cancel();

      iniciarHeartbeat();

      await carregarHistoricoHTTP();

      if (!mounted || channel != novoChannel) {
        novoChannel.sink.close();
        return;
      }

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

            if (evento != 'pedido.created' &&
                evento != 'pedido.updated') {
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
                  pedidos[index] = payload;
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
    } catch (e) {
      debugPrint('Erro ao conectar WebSocket: $e');
      _conexaoPerdida();
    }
  }

  Future<void> finalizarPedido(int pedidoId) async {
    try {
      final url = Uri.parse(
        '$urlHttp/pedidos/$pedidoId/finish',
      );

      final response = await http.patch(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      debugPrint('Finalizar pedido: ${response.statusCode}');
    } catch (e) {
      debugPrint('Erro ao finalizar pedido: $e');
    }
  }

  @override
  void dispose() {
    _encerrando = true;

    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _webSocketSubscription?.cancel();

    channel?.sink.close();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pedidosAbertos =
        pedidos.where((p) => p['status'] != 'PRONTO').toList();

    final pedidosProntos =
        pedidos.where((p) => p['status'] == 'PRONTO').toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitor de Preparo'),
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
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _construirColunaPedidos(
              titulo: 'Em Aberto (${pedidosAbertos.length})',
              corTitulo: const Color(0xFFFF6E40),
              pedidosLista: pedidosAbertos,
            ),
          ),
          const VerticalDivider(
            width: 1,
            color: Colors.grey,
          ),
          Expanded(
            child: _construirColunaPedidos(
              titulo: 'Prontos (${pedidosProntos.length})',
              corTitulo: Colors.greenAccent,
              pedidosLista: pedidosProntos,
            ),
          ),
        ],
      ),
    );
  }

  Widget _construirColunaPedidos({
    required String titulo,
    required Color corTitulo,
    required List<Map<String, dynamic>> pedidosLista,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            titulo,
            style: TextStyle(
              color: corTitulo,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
            ),
            itemCount: pedidosLista.length,
            itemBuilder: (context, index) {
              final p = pedidosLista[index];
              final bool pronto = p['status'] == 'PRONTO';

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(
                            '#${p['id']} - ${p['drink']}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Cliente: ${p['cliente_nome']}',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Status: ${p['status'] ?? "ABERTO"}',
                            style: TextStyle(
                              color: pronto
                                  ? Colors.greenAccent
                                  : const Color(0xFFFF6E40),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: pronto
                            ? const Color(0xFF2C2C2E)
                            : const Color(0xFFFF5722),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onPressed: pronto
                          ? null
                          : () => finalizarPedido(p['id']),
                      child: Text(
                        pronto
                            ? 'CONCLUÍDO'
                            : 'MARCAR PRONTO',
                        style: TextStyle(
                          color: pronto
                              ? Colors.grey
                              : Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}