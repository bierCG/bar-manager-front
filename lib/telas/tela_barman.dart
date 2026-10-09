import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth.dart';
import '../config.dart';

class TelaBarman extends StatefulWidget {
  const TelaBarman({super.key});

  @override
  State<TelaBarman> createState() => _TelaBarmanState();
}

class _TelaBarmanState extends State<TelaBarman> {
  WebSocketChannel? channel;
  StreamSubscription? _webSocketSubscription;

  List<Map<String, dynamic>> pedidos = [];

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  DateTime? _ultimoPong;

  bool _mostrandoDesconectado = false;
  bool conectado = false;
  bool _encerrando = false;

  final TextEditingController drinkController = TextEditingController();
  final TextEditingController clienteController = TextEditingController();

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
        Uri.parse('$urlHttp/pedidos/bartender'),
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

  Future<void> criarPedido() async {
    if (drinkController.text.isEmpty || clienteController.text.isEmpty) {
      return;
    }

    final url = Uri.parse('$urlHttp/pedidos/');
    final body = jsonEncode({
      'cliente_nome': clienteController.text,
      'drink': drinkController.text,
    });

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: body,
      );

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        final dados = jsonDecode(response.body);

        if (dados is Map) {
          final pedido = Map<String, dynamic>.from(dados);

          setState(() {
            final jaExiste = pedidos.any((p) => p['id'] == pedido['id']);
            if (!jaExiste) {
              pedidos.insert(0, pedido);
            }
          });
        }

        drinkController.clear();
        clienteController.clear();
      } else {
        _avisar('Não foi possível enviar o pedido (${response.statusCode})');
      }
    } catch (e) {
      debugPrint('Erro ao enviar pedido: $e');
      _avisar('Falha de conexão. O pedido NÃO foi enviado.');
    }
  }

  void _avisar(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(texto),
          duration: const Duration(seconds: 4),
        ),
      );
    // Se o aviso substituiu o "Desconectado", reexibe depois.
    if (_mostrandoDesconectado) {
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted && _mostrandoDesconectado) statusConexao();
      });
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

            if (evento != 'pedido.updated') return;

            final payload = dados['payload'];

            if (payload is! Map<String, dynamic>) return;

            setState(() {
              final index = pedidos.indexWhere(
                (p) => p['id'] == payload['id'],
              );

              if (index != -1) {
                pedidos[index]['status'] = payload['status'];
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

      // Pull de reconexão: atualiza o que mudou durante a queda.
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

    drinkController.dispose();
    clienteController.dispose();

    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lançar Pedidos'),
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
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // FORMULÁRIO DE PEDIDO
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Text(
                    '$username',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  TextField(
                    controller: clienteController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Nome do cliente',
                      labelStyle: const TextStyle(color: Colors.grey),
                      filled: true,
                      fillColor: const Color(0xFF2C2C2E),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: drinkController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Drink',
                      labelStyle: const TextStyle(color: Colors.grey),
                      filled: true,
                      fillColor: const Color(0xFF2C2C2E),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF5722),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      onPressed: criarPedido,
                      child: const Text(
                        'Enviar Pedido',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Status dos Pedidos',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: pedidos.length,
                itemBuilder: (context, index) {
                  final p = pedidos[index];
                  final bool pronto = p['status'] == 'PRONTO';
                  final bool entregue = p['status'] == 'ENTREGUE';

                  final Color corStatus = entregue
                      ? const Color(0xFF40C4FF)
                      : pronto
                          ? Colors.greenAccent
                          : const Color(0xFFFF6E40);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
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
                              'Status: ${p['status'] ?? "ABERTO"}',
                              style: TextStyle(
                                color: corStatus,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        Icon(
                          entregue
                              ? Icons.done_all
                              : pronto
                                  ? Icons.check_circle
                                  : Icons.hourglass_top,
                          color: entregue
                              ? const Color(0xFF40C4FF)
                              : pronto
                                  ? Colors.greenAccent
                                  : const Color(0xFFFF5722),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}