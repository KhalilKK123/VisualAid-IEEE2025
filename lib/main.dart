import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:visual_aid_ui/backend_conn.dart';
import 'package:visual_aid_ui/screens/object_recognition_screen.dart';
import 'package:visual_aid_ui/screens/scene_description_screen.dart';
import 'package:visual_aid_ui/screens/text_reading_screen.dart';
import 'package:visual_aid_ui/screens/tts_settings_screen.dart';
import 'package:visual_aid_ui/tts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final firstCamera = cameras.first;
  final backend = Backend();
  final tts = TTS();

  runApp(MyApp(camera: firstCamera, backend: backend, tts: tts));
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;
  final Backend backend;
  final TTS tts;

  const MyApp({
    super.key,
    required this.camera,
    required this.backend,
    required this.tts,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VisionAid',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: MyHomePage(camera: camera, backend: backend, tts: tts),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final CameraDescription camera;
  final Backend backend;
  final TTS tts;
  const MyHomePage({
    super.key,
    required this.camera,
    required this.backend,
    required this.tts,
  });
  @override
  _MyHomePageState createState() =>
      _MyHomePageState(camera: camera, backend: backend, tts: tts);
}

class _MyHomePageState extends State<MyHomePage> {
  final CameraDescription camera;
  final Backend backend;
  final TTS tts;

  _MyHomePageState({
    required this.camera,
    required this.backend,
    required this.tts,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('VisionAid')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (context) => ObjectRecognitionScreen(
                          camera: camera,
                          backend: backend,
                          tts: tts,
                        ),
                  ),
                );
              },
              child: Text('Detect Object'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (context) => SceneDescriptionScreen(
                          camera: camera,
                          backend: backend,
                          tts: tts,
                        ),
                  ),
                );
              },
              child: Text('Describe Scene'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (context) => TextReadingScreen(
                          camera: camera,
                          backend: backend,
                          tts: tts,
                        ),
                  ),
                );
              },
              child: Text('Read Text'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => TtsSettingsScreen(tts: tts),
                  ),
                );
              },
              child: Text('TTS Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
