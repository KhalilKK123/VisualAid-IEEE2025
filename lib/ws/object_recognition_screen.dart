import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:visual_aid_ui/ws/backend_conn.dart';

class ObjectRecognitionScreen extends StatefulWidget {
  final CameraDescription camera;
  final Backend backend;
  const ObjectRecognitionScreen({
    super.key,
    required this.camera,
    required this.backend,
  });

  @override
  State<ObjectRecognitionScreen> createState() =>
      _ObjectRecognitionScreenState(backend: backend);
}

class _ObjectRecognitionScreenState extends State<ObjectRecognitionScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  String result = "LOADING";
  final Backend backend;
  late final Timer? timer;

  _ObjectRecognitionScreenState({required this.backend});

  @override
  void initState() {
    _controller = CameraController(widget.camera, ResolutionPreset.medium);
    _initializeControllerFuture = _controller.initialize();
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    backend.connectSocket();
    startTimer();
    await receiveObject();
  }

  // Future<void> receiveResult() async {
  //   backend.askTimeStream().listen(
  //     (String value) {
  //       setState(() {
  //         result = value;
  //       });
  //     },
  //     onError: (error) {
  //       setState(() {
  //         result = error.toString();
  //       });
  //       print("Error in receiveResult: $error");
  //     },
  //   );
  // }

  Future<void> receiveObject() async {
    backend.detectObjectStream().listen(
      (String value) {
        setState(() {
          result = value;
        });
      },
      onError: (error) {
        setState(() {
          result = error.toString();
        });
        print("Error in receiveObject: $error");
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
      backend.sendObjectImage(base64Image);
    } catch (e) {
      print("error taking photo: $e");
    }
  }

  void startTimer() {
    timer = Timer.periodic(Duration(seconds: 5), (Timer t) {
      captureAndProcessImage();
    });
  }

  void stopTimer() {
    if (timer != null && timer!.isActive) {
      timer!.cancel();
      timer = null;
      print("Timer cancelled");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Object Recognition')),
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
    stopTimer();
    super.dispose();
  }
}
