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

class _TelaCozinhaState extends State<TelaCozinha> with WidgetsBindingObserver {
  static const Color _corAberto = Color(0xFFFF6E40);
  static const Color _corPronto = Colors.greenAccent;
  static const Color _corEntregue = Color(0xFF40C4FF);

  WebSocketChannel? channel;
  StreamSubscription? _webSocketSubscription;

  List<Map<String, dynamic>> pedidos = [];

  // IDs com ação em andamento (evita duplo toque).
  final Set<int> _processando = {};

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  DateTime? _ultimoPong;

  bool _mostrandoDesconectado = false;
  bool conectado = false;
  bool _encerrando = false;

  bool sincronizando = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    carregarHistoricoHTTP();
    conectarWebSocket();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      sincronizar();
    }
  }

  Future<void> sincronizar() async {
    setState(() => sincronizando = true);
    try {
      await conectarWebSocket();
    } finally {
      if (mounted) setState(() => sincronizando = false);
    }
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

    // Se o aviso cobriu o "Desconectado", reexibe depois.
    if (_mostrandoDesconectado) {
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted && _mostrandoDesconectado) statusConexao();
      });
    }
  }

  // ---------------------------------------------------------------------------
  // HEARTBEAT
  // ---------------------------------------------------------------------------

  void _mostrarReconectado() {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Reconectado',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Color(0xFF2E7D32),
          duration: Duration(seconds: 3),
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        ),
      );
  }

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
          // O pull do histórico já acontece dentro de conectarWebSocket.
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

  /// Substitui o pedido na lista local (usado com a resposta do PATCH,
  /// para a tela atualizar mesmo se o WebSocket estiver fora).
  void _atualizarLocal(Map<String, dynamic> pedido) {
    if (!mounted) return;

    setState(() {
      final index = pedidos.indexWhere((p) => p['id'] == pedido['id']);
      if (index != -1) {
        pedidos[index] = pedido;
      } else {
        pedidos.insert(0, pedido);
      }
    });
  }

  Future<void> _executarAcao(
    int pedidoId,
    String status,
    String nomeAcao,
  ) async {
    if (_processando.contains(pedidoId)) return;

    setState(() => _processando.add(pedidoId));

    try {
      final response = await http.patch(
        Uri.parse('$urlHttp/pedidos/$pedidoId/status'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'status': status,
        })
      );

      if (response.statusCode == 200) {
        final dados = jsonDecode(response.body);
        if (dados is Map) {
          _atualizarLocal(Map<String, dynamic>.from(dados));
        }
      } else {
        debugPrint('$nomeAcao pedido: ${response.statusCode}');
        _avisar('Não foi possível $nomeAcao o pedido (${response.statusCode})');
      }
    } catch (e) {
      debugPrint('Erro ao $nomeAcao pedido: $e');
      _avisar('Falha de conexão. Ação NÃO realizada.');
    } finally {
      if (mounted) {
        setState(() => _processando.remove(pedidoId));
      }
    }
  }

  Future<void> finalizarPedido(int pedidoId) =>
      _executarAcao(pedidoId, 'PRONTO', 'finalizar');

  Future<void> entregarPedido(int pedidoId) =>
      _executarAcao(pedidoId, 'ENTREGUE', 'entregar');

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
                  pedidos[index] = payload;
                }
              }
            });
          } catch (e) {
            debugPrint('Erro ao processar mensagem WebSocket: $e');
          }
        },
        onDone: () {
          if (novoChannel.closeCode == 4009){
            _avisar('Já existe uma conexão ativa.');
          } else if (channel == novoChannel) {
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

      final eraDesconectado = _mostrandoDesconectado;
      _mostrandoDesconectado = false;
      statusConexao();
      if (eraDesconectado) _mostrarReconectado();

      _reconnectTimer?.cancel();

      iniciarHeartbeat();

      // Pull de reconexão: traz tudo que mudou durante a queda.
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

    WidgetsBinding.instance.removeObserver(this);

    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final largura = MediaQuery.of(context).size.width;
    final bool mobile = largura < 700;

    final pedidosAbertos = pedidos
        .where((p) => p['status'] != 'PRONTO' && p['status'] != 'ENTREGUE')
        .toList();
    final pedidosProntos =
        pedidos.where((p) => p['status'] == 'PRONTO').toList();
    final pedidosEntregues =
        pedidos.where((p) => p['status'] == 'ENTREGUE').toList();

    final colAbertos = _construirColunaPedidos(
      titulo: 'Em Aberto (${pedidosAbertos.length})',
      corTitulo: _corAberto,
      pedidosLista: pedidosAbertos,
      mostrarTitulo: !mobile,
    );
    final colProntos = _construirColunaPedidos(
      titulo: 'Prontos (${pedidosProntos.length})',
      corTitulo: _corPronto,
      pedidosLista: pedidosProntos,
      mostrarTitulo: !mobile,
    );

    final scaffold = Scaffold(
      appBar: AppBar(
        title: Image.asset(
          'assets/logo.png',
          height: 82,
        ),
        centerTitle: false,
        actions: [
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Pedidos entregues',
              icon: Badge(
                label: Text('${pedidosEntregues.length}'),
                isLabelVisible: pedidosEntregues.isNotEmpty,
                child: const Icon(Icons.inventory_2_outlined),
              ),
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
        ]
      ),
      endDrawer: Drawer(
        width: mobile ? largura * 0.85 : 380,
        backgroundColor: const Color(0xFF121212),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Entregues (${pedidosEntregues.length})',
                  style: const TextStyle(
                    color: _corEntregue,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: pedidosEntregues.isEmpty
                    ? const Center(
                        child: Text(
                          'Nenhum pedido entregue',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: pedidosEntregues.length,
                        itemBuilder: (context, index) =>
                            _construirCard(pedidosEntregues[index]),
                      ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (sincronizando) const LinearProgressIndicator(),
          if (mobile)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                dividerColor: Colors.transparent,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: const Color(0xFF2C2C2E),
                  borderRadius: BorderRadius.circular(12),
                ),
                labelColor: Colors.white,
                unselectedLabelColor: Colors.grey,
                tabs: [
                  Tab(text: 'Abertos  •  ${pedidosAbertos.length}'),
                  Tab(text: 'Prontos  •  ${pedidosProntos.length}'),
                ],
              ),
            ),
          Expanded(
            child: mobile
                ? TabBarView(children: [colAbertos, colProntos])
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: colAbertos),
                      const VerticalDivider(width: 1, color: Colors.grey),
                      Expanded(child: colProntos),
                    ],
                  ),
          ),
        ],
      ),
    );

    return mobile
        ? DefaultTabController(length: 2, child: scaffold)
        : scaffold;
  }

  Widget _construirColunaPedidos({
    required String titulo,
    required Color corTitulo,
    required List<Map<String, dynamic>> pedidosLista,
    bool mostrarTitulo = true,
  }) {
    return Column(
      children: [
        if (mostrarTitulo)
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
            padding: const EdgeInsets.all(12),
            itemCount: pedidosLista.length,
            itemBuilder: (context, index) =>
                _construirCard(pedidosLista[index]),
          ),
        ),
      ],
    );
  }

  Widget _construirCard(Map<String, dynamic> p) {
    final String status = (p['status'] ?? 'ABERTO').toString();
    final bool pronto = status == 'PRONTO';
    final bool entregue = status == 'ENTREGUE';

    final Color corStatus = entregue
        ? _corEntregue
        : pronto
            ? _corPronto
            : _corAberto;

    final int id = p['id'] as int;
    final bool ocupado = _processando.contains(id);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: entregue
            ? Border.all(color: _corEntregue.withOpacity(0.4))
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${p['drink']}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Garcom: ${p['cliente_nome']}',
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          if (entregue)
            const Icon(Icons.done_all, color: _corEntregue)
          else
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    pronto ? const Color(0xFF0288D1) : const Color(0xFFFF5722),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF2C2C2E),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onPressed: ocupado
                  ? null
                  : () => pronto ? entregarPedido(id) : finalizarPedido(id),
              child: ocupado
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      pronto ? 'ENTREGAR' : 'FINALIZAR',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
