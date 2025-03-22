import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:visual_aid_ui/tts.dart';
import 'package:visual_aid_ui/backend_conn.dart';

class TextReadingScreen extends StatefulWidget {
  final CameraDescription camera;
  final Backend backend;
  final TTS tts;
  const TextReadingScreen({
    super.key,
    required this.camera,
    required this.backend,
    required this.tts,
  });

  @override
  State<TextReadingScreen> createState() =>
      _TextReadingScreenState(backend: backend, tts: tts);
}

class _TextReadingScreenState extends State<TextReadingScreen> {
  final Backend backend;
  final TTS tts;
  _TextReadingScreenState({required this.backend, required this.tts});

  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  String result = "LOADING";
  // late final Timer? timer;

  @override
  void initState() {
    _controller = CameraController(widget.camera, ResolutionPreset.medium);
    _initializeControllerFuture = _controller.initialize();
    tts.initTts();
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    backend.connectSocket();
    // startTimer();
    await receiveText();
  }

  Future<void> receiveText() async {
    backend.readTextStream().listen(
      (String value) {
        setState(() {
          result = value;
        });
        tts.speak(value);
      },
      onError: (error) {
        setState(() {
          result = error.toString();
        });
        print("Error in receiveText: $error");
      },
    );
  }

  Future<void> captureAndProcessImage() async {
    try {
      await _initializeControllerFuture;

      final image = await _controller.takePicture();
      File imageFile = File(image.path);

      List<int> imageBytes = await imageFile.readAsBytes();
      String base64Image = base64Encode(imageBytes);
      backend.sendTextImage(base64Image);
    } catch (e) {
      print("error taking photo: $e");
    }
  }

  // void startTimer() {
  //   timer = Timer.periodic(Duration(seconds: 5), (Timer t) {
  //     captureAndProcessImage();
  //   });
  // }

  // void stopTimer() {
  //   if (timer != null && timer!.isActive) {
  //     timer!.cancel();
  //     timer = null;
  //     print("Timer cancelled");
  //   }
  // }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Text Reading')),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            children: [
              FutureBuilder<void>(
                future: _initializeControllerFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done) {
                    return CameraPreview(_controller);
                  } else {
                    return Center(child: CircularProgressIndicator());
                  }
                },
              ),
              ElevatedButton(
                onPressed: captureAndProcessImage,
                child: Text("click"),
              ),
              Padding(padding: const EdgeInsets.all(8.0), child: Text(result)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    backend.disposeSocket();
    _controller.dispose();
    tts.stop();
    // stopTimer();
    super.dispose();
  }
}
