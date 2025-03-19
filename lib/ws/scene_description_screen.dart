import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:visual_aid_ui/tts.dart';
import 'package:visual_aid_ui/ws/backend_conn.dart';

class SceneDescriptionScreen extends StatefulWidget {
  final CameraDescription camera;
  final Backend backend;
  const SceneDescriptionScreen({
    super.key,
    required this.camera,
    required this.backend,
  });

  @override
  State<SceneDescriptionScreen> createState() =>
      _SceneDescriptionScreenState(backend: backend);
}

class _SceneDescriptionScreenState extends State<SceneDescriptionScreen> {
  final Backend backend;
  _SceneDescriptionScreenState({required this.backend});

  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  String result = "LOADING";
  // late final Timer? timer;

  late TTS tts;

  @override
  void initState() {
    _controller = CameraController(widget.camera, ResolutionPreset.medium);
    _initializeControllerFuture = _controller.initialize();
    tts = TTS();
    tts.initTts();
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    backend.connectSocket();
    // startTimer();
    await receiveScene();
  }

  Future<void> receiveScene() async {
    backend.describeSceneStream().listen(
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
        print("Error in receiveScene: $error");
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
      backend.sendSceneImage(base64Image);
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
      appBar: AppBar(title: Text('Scene Description')),
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
