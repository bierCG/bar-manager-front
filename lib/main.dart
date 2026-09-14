import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const String backendDomain = 'https://bar-manager-back.onrender.com'; 

const String baseUrlHttp = 'https://$backendDomain';
const String urlWebSocket = 'wss://$backendDomain/ws/bar';

void main() {
  runApp(MaterialApp(
    title: 'Sistema de Pedidos',
    debugShowCheckedModeBanner: false,
    // Definimos por qual rota o app começa se ninguém digitar caminho na URL
    initialRoute: '/',
    // Mapeamos as URLs para cada tela correspondente
    routes: {
      '/': (context) => const TelaSelecao(),
      '/barman': (context) => const TelaBarman(),
      '/cozinha': (context) => const TelaCozinha(),
    },
  ));
}

// --- TELA DE SELEÇÃO ---
class TelaSelecao extends StatelessWidget {
  const TelaSelecao({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sistema de Pedidos - Bar'), backgroundColor: Colors.indigo),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
              icon: const Icon(Icons.local_bar),
              label: const Text('Abrir Tela do Barman (Atendimento)', style: TextStyle(fontSize: 16)),
              onPressed: () {
                    Navigator.pushNamed(context, '/barman');
                },
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                backgroundColor: Colors.orange,
              ),
              icon: const Icon(Icons.kitchen),
              label: const Text('Abrir Tela da Cozinha (Monitor)', style: TextStyle(fontSize: 16, color: Colors.white)),
              onPressed: () {
                    Navigator.pushNamed(context, '/cozinha');
                },
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// TELA 1: BARMAN (CRIA PEDIDOS E ACOMPANHA)
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
  final TextEditingController mesaController = TextEditingController();

  @override
  void initState() {
    super.initState();
    conectarWebSocket();
  }

  void conectarWebSocket() {
    channel = WebSocketChannel.connect(Uri.parse(urlWebSocket));
    channel!.stream.listen((mensagem) {
      final dados = jsonDecode(mensagem);
      String evento = dados['event'];

      setState(() {
        if (evento == 'NOVO_PEDIDO') {
          pedidos.add(Map<String, dynamic>.from(dados['pedido']));
        } else if (evento == 'STATUS_ATUALIZADO') {
          final pedidoAtualizado = dados['pedido'];
          final index = pedidos.indexWhere((p) => p['id'] == pedidoAtualizado['id']);
          if (index != -1) {
            pedidos[index] = Map<String, dynamic>.from(pedidoAtualizado);
          }
        }
      });
    });
  }

  Future<void> criarPedido() async {
    if (drinkController.text.isEmpty || mesaController.text.isEmpty) return;

    final url = Uri.parse('$baseUrlHttp/pedidos');
    final body = jsonEncode({
      'cliente_id': 'atendimento_1',
      'drink': drinkController.text,
      'mesa': int.tryParse(mesaController.text) ?? 1,
    });

    try {
      await http.post(url, headers: {'Content-Type': 'application/json'}, body: body);
      drinkController.clear();
      mesaController.clear();
    } catch (e) {
      print('Erro ao enviar pedido: $e');
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
      appBar: AppBar(title: const Text('Barman - Lançar Pedidos'), backgroundColor: Colors.indigo),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // FORMULÁRIO DE ENVIO DE PEDIDO
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: drinkController,
                    decoration: const InputDecoration(labelText: 'Drink (ex: Gin Tônica)', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: mesaController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Mesa', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 20)),
                  onPressed: criarPedido,
                  child: const Text('Enviar'),
                ),
              ],
            ),
            const Divider(height: 32),
            const Text('Status dos Pedidos Enviados', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: pedidos.length,
                itemBuilder: (context, index) {
                  final p = pedidos[index];
                  final bool pronto = p['status'] == 'PRONTO';

                  return Card(
                    color: pronto ? Colors.green.shade50 : Colors.amber.shade50,
                    child: ListTile(
                      title: Text('${p['drink']} - Mesa ${p['mesa']}'),
                      subtitle: Text('Status: ${p['status']}'),
                      trailing: Icon(
                        pronto ? Icons.check_circle : Icons.hourglass_top,
                        color: pronto ? Colors.green : Colors.orange,
                      ),
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
// TELA 2: COZINHA / MONITOR (FINALIZA PEDIDOS)
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
    conectarWebSocket();
  }

  void conectarWebSocket() {
    channel = WebSocketChannel.connect(Uri.parse(urlWebSocket));
    channel!.stream.listen((mensagem) {
      final dados = jsonDecode(mensagem);
      String evento = dados['event'];

      setState(() {
        if (evento == 'NOVO_PEDIDO') {
          pedidos.add(Map<String, dynamic>.from(dados['pedido']));
        } else if (evento == 'STATUS_ATUALIZADO') {
          final pedidoAtualizado = dados['pedido'];
          final index = pedidos.indexWhere((p) => p['id'] == pedidoAtualizado['id']);
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
      appBar: AppBar(title: const Text('Cozinha / Bar - Monitor de Preparo'), backgroundColor: Colors.orange),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: pedidos.length,
        itemBuilder: (context, index) {
          final p = pedidos[index];
          final bool pronto = p['status'] == 'PRONTO';

          return Card(
            elevation: 4,
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              title: Text('#${p['id']} - ${p['drink']}', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Mesa: ${p['mesa']} | Status: ${p['status']}'),
              trailing: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: pronto ? Colors.grey : Colors.green,
                ),
                onPressed: pronto ? null : () => finalizarPedido(p['id']),
                child: Text(pronto ? 'CONCLUÍDO' : 'MARCAR PRONTO', style: const TextStyle(color: Colors.white)),
              ),
            ),
          );
        },
      ),
    );
  }
}