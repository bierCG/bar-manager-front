import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth.dart';
import '../config.dart';

import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:google_fonts/google_fonts.dart';

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
    conectarWebSocket();
    carregarHistoricoHTTP();
  }

  Future<void> carregarHistoricoHTTP() async {
    try {
      final response = await http.get(
        Uri.parse('$urlHttp/pedidos/bartender'),
        headers: {
          'Authorization': 'Bearer $token',
        },
      );
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
      Uri.parse('$urlWs/ws/bar?token=$token'),
    );

    channel!.stream.listen((mensagem) {
      final Map<String, dynamic> dados = jsonDecode(mensagem);
      final String evento = dados['event'];
      final Map<String, dynamic> payload = dados['payload'];

      setState(() {
        if (evento == 'pedido.updated') {
          final index = pedidos.indexWhere(
            (p) => p['id'] == payload['id'],
          );

          if (index != -1) {
            pedidos[index]['status'] = payload['status'];
          }
        }
      });
    });
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
          'Authorization': 'Bearer $token'
        },
        body: body,
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> pedido = jsonDecode(response.body);
        
        setState(() {
          pedidos.insert(0, pedido);
        });
      }

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
                  Text(
                    '$username',
                    style: TextStyle(
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