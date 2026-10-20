WebSocketChannel? channel;

Future<void> conectarWebSoket(){
    channel = WebSocketChannel.connect(Uri.parse('$urlWs/ws/bar?token=$token'));

    try {
        await channel.ready;
    } on WebSocketChaneelException catch (e) {
        return
    }

    channel.stream.listen(
        (mensagem){},
        if channel.closeCode == 4009 {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Usuário já possui uma conexão aberta'),
                ),
            );
        }
    )

    return channel
}