import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const String backendDomain = 'bar-manager-back.onrender.com';
const String baseUrlHttp = 'https://$backendDomain';
const String urlWebSocket = 'wss://$backendDomain/ws/bar';

void main() {
  runApp(
    MaterialApp(
      title: 'Sistema de Pedidos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF5722),
          surface: Color(0xFF1E1E1E),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const TelaSelecao(),
        '/barman': (context) => const TelaBarman(),
        '/cozinha': (context) => const TelaCozinha(),
      },
    ),
  );
}

// ==========================================
// TELA DE SELEÇÃO
// ==========================================

class TelaSelecao extends StatelessWidget {
  const TelaSelecao({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sistema de Pedidos'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircleAvatar(
                radius: 36,
                backgroundColor: Color(0xFFFF5722),
                child: Icon(Icons.local_bar, size: 36, color: Colors.white),
              ),
              const SizedBox(height: 24),
              const Text(
                'Selecione o seu perfil',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF5722),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.local_bar),
                  label: const Text(
                    'Abrir Tela do Barman',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  onPressed: () {
                    Navigator.pushNamed(context, '/barman');
                  },
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2C2C2E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.kitchen, color: Color(0xFFFF6E40)),
                  label: const Text(
                    'Abrir Tela da Cozinha',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  onPressed: () {
                    Navigator.pushNamed(context, '/cozinha');
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// TELA DO BARMAN
// ==========================================

class TelaBarman extends StatefulWidget {
  const TelaBarman({super.key});

  @override
  State<TelaBarman> createState() => _TelaBarmanState();
}

class _TelaBarmanState extends State<TelaBarman> {
  WebSocketChannel? channel;
  List<Map<String, dynamic>> pedidos = [];

  final TextEditingController drinkController = TextEditingController();
  final TextEditingController clienteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    carregarHistoricoHTTP();
    conectarWebSocket();
  }

  Future<void> carregarHistoricoHTTP() async {
    try {
      final response = await http.get(Uri.parse('$baseUrlHttp/pedidos'));
      if (response.statusCode == 200) {
        final List<dynamic> dados = jsonDecode(response.body);
        setState(() {
          pedidos = dados.map((p) => Map<String, dynamic>.from(p)).toList();
        });
      }
    } catch (e) {
      print('Erro ao carregar histórico via HTTP: $e');
    }
  }

  void conectarWebSocket() {
    channel = WebSocketChannel.connect(
      Uri.parse(urlWebSocket),
    );

    channel!.stream.listen((mensagem) {
      final dados = jsonDecode(mensagem);
      String evento = dados['event'];

      setState(() {
        if (evento == 'NOVO_PEDIDO') {
          final novoPedido = Map<String, dynamic>.from(dados['pedido']);
          final jaExiste = pedidos.any((p) => p['id'] == novoPedido['id']);
          
          if (!jaExiste) {
            pedidos.insert(0, novoPedido);
          }
        } else if (evento == 'STATUS_ATUALIZADO') {
          final pedidoAtualizado = dados['pedido'];
          final index = pedidos.indexWhere(
            (p) => p['id'] == pedidoAtualizado['id'],
          );

          if (index != -1) {
            pedidos[index] = Map<String, dynamic>.from(pedidoAtualizado);
          }
        }
      });
    });
  }

  Future<void> criarPedido() async {
    if (drinkController.text.isEmpty || clienteController.text.isEmpty) {
      return;
    }

    final url = Uri.parse('$baseUrlHttp/pedidos');
    final body = jsonEncode({
      'cliente_nome': clienteController.text,
      'drink': drinkController.text,
    });

    try {
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      drinkController.clear();
      clienteController.clear();
    } catch (e) {
      print('Erro ao enviar pedido: $e');
    }
  }

  @override
  void dispose() {
    channel?.sink.close();
    drinkController.dispose();
    clienteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lançar Pedidos'),
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
                            fontSize: 16, fontWeight: FontWeight.bold),
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
                                color: pronto ? Colors.greenAccent : const Color(0xFFFF6E40),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        Icon(
                          pronto ? Icons.check_circle : Icons.hourglass_top,
                          color: pronto ? Colors.greenAccent : const Color(0xFFFF5722),
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

// ==========================================
// TELA DA COZINHA
// ==========================================

class TelaCozinha extends StatefulWidget {
  const TelaCozinha({super.key});

  @override
  State<TelaCozinha> createState() => _TelaCozinhaState();
}

class _TelaCozinhaState extends State<TelaCozinha> {
  WebSocketChannel? channel;
  List<Map<String, dynamic>> pedidos = [];

  @override
  void initState() {
    super.initState();
    carregarHistoricoHTTP();
    conectarWebSocket();
  }

  Future<void> carregarHistoricoHTTP() async {
    try {
      final response = await http.get(Uri.parse('$baseUrlHttp/pedidos'));
      if (response.statusCode == 200) {
        final List<dynamic> dados = jsonDecode(response.body);
        setState(() {
          pedidos = dados.map((p) => Map<String, dynamic>.from(p)).toList();
        });
      }
    } catch (e) {
      print('Erro ao carregar histórico via HTTP: $e');
    }
  }

  void conectarWebSocket() {
    channel = WebSocketChannel.connect(
      Uri.parse(urlWebSocket),
    );

    channel!.stream.listen((mensagem) {
      final dados = jsonDecode(mensagem);
      String evento = dados['event'];

      setState(() {
        if (evento == 'NOVO_PEDIDO') {
          final novoPedido = Map<String, dynamic>.from(dados['pedido']);
          final jaExiste = pedidos.any((p) => p['id'] == novoPedido['id']);
          
          if (!jaExiste) {
            pedidos.insert(0, novoPedido);
          }
        } else if (evento == 'STATUS_ATUALIZADO') {
          final pedidoAtualizado = dados['pedido'];
          final index = pedidos.indexWhere(
            (p) => p['id'] == pedidoAtualizado['id'],
          );

          if (index != -1) {
            pedidos[index] = Map<String, dynamic>.from(pedidoAtualizado);
          }
        }
      });
    });
  }

  void finalizarPedido(int pedidoId) {
    if (channel != null) {
      final payload = jsonEncode({
        'event': 'ATUALIZAR_STATUS',
        'pedido_id': pedidoId,
        'status': 'PRONTO',
      });

      channel!.sink.add(payload);
    }
  }

  @override
  void dispose() {
    channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitor de Preparo'),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: pedidos.length,
        itemBuilder: (context, index) {
          final p = pedidos[index];
          final bool pronto = p['status'] == 'PRONTO';

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
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
                          color: pronto ? Colors.greenAccent : const Color(0xFFFF6E40),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        pronto ? const Color(0xFF2C2C2E) : const Color(0xFFFF5722),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  onPressed: pronto ? null : () => finalizarPedido(p['id']),
                  child: Text(
                    pronto ? 'CONCLUÍDO' : 'MARCAR PRONTO',
                    style: TextStyle(
                      color: pronto ? Colors.grey : Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}