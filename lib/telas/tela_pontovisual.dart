import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth.dart';
import '../config.dart';

import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:google_fonts/google_fonts.dart';

class PontoVisual extends StatefulWidget {
  const PontoVisual({super.key});

  @override
  State<PontoVisual> createState() => _PontoVisualState();
}

class _PontoVisualState extends State<PontoVisual> {
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
      final response = await http.get(
        Uri.parse('$urlHttp/pedidos/'),
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
    });
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
        title: const Text('Ponto Visual'),
      ),
      body: ListView.builder(
        itemCount: pedidos.length,
        itemBuilder: (context, index) {
          final p = pedidos[index];
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
                  pronto
                      ? Icons.check_circle
                      : Icons.hourglass_top,
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