import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as IO;

class Backend {
  late IO.Socket socket;

  Backend() {
    socket = IO.io('PLACEHOLDER', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });
  }
  void connectSocket() {
    socket.connect();
    socket.onConnect((data) {
      print('Socket connected');
    });
    socket.onDisconnect((_) => print('socket disconnected'));
    socket.onConnectError((err) => print(err));
    socket.onError((err) => print(err));
  }

  // Stream<String> askTimeStream() {
  //   var counter = 0;
  //   String outputString = "Count: $counter";
  //   final controller = StreamController<String>();

  //   try {
  //     var timer = Timer.periodic(Duration(seconds: 1), (Timer t) {
  //       counter++;
  //       outputString = 'Count: $counter';
  //       socket.emit("what-time", outputString);
  //     });
  //   } catch (e) {
  //     print("error, couldn't emit: $e");
  //   }
  //   try {
  //     socket.on("time-is", (data) {
  //       print("Yoooo $data");
  //       controller.add(data.toString());
  //     });
  //   } catch (e) {
  //     print(e);
  //     controller.add(e.toString());
  //   }
  //   return controller.stream;
  // }

  sendObjectImage(String base64Image) async {
    try {
      socket.emit("detect-object", {
        'image': 'data:image/jpeg;base64,$base64Image',
      });
    } catch (e) {
      print("error, couldn't emit: $e");
    }
  }

  Stream<String> detectObjectStream() {
    final controller = StreamController<String>();

    try {
      socket.on("object-detection-result", (data) {
        print("YOOOOOO $data");
        controller.add(data.toString());
      });
    } catch (e) {
      print(e);
      controller.add(e.toString());
    }
    return controller.stream;
  }

  sendSceneImage(String base64Image) async {
    try {
      socket.emit("describe-scene", {
        'image': 'data:image/jpeg;base64,$base64Image',
      });
    } catch (e) {
      print("error, couldn't emit: $e");
    }
  }

  Stream<String> describeSceneStream() {
    final controller = StreamController<String>();

    try {
      socket.on("scene-description-result", (data) {
        print("YOOOOOO $data");
        controller.add(data.toString());
      });
    } catch (e) {
      print(e);
      controller.add(e.toString());
    }
    return controller.stream;
  }

  sendTextImage(String base64Image) async {
    try {
      socket.emit("read-text", {
        'image': 'data:image/jpeg;base64,$base64Image',
      });
    } catch (e) {
      print("error, couldn't emit: $e");
    }
  }

  Stream<String> readTextStream() {
    final controller = StreamController<String>();

    try {
      socket.on("text-reading-result", (data) {
        print("YOOOOOO $data");
        controller.add(data.toString());
      });
    } catch (e) {
      print(e);
      controller.add(e.toString());
    }
    return controller.stream;
  }

  void disposeSocket() {
    socket.dispose();
  }
}
