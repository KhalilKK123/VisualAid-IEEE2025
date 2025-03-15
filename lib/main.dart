import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:visual_aid_ui/ws/backend_conn.dart';
import 'package:visual_aid_ui/ws/object_recognition_screen.dart';
import 'package:visual_aid_ui/ws/scene_description_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final firstCamera = cameras.first;
  final backend = Backend();

  runApp(MyApp(camera: firstCamera, backend: backend));
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;
  final Backend backend;

  const MyApp({super.key, required this.camera, required this.backend});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VisionAid',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: MyHomePage(camera: camera, backend: backend),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final CameraDescription camera;
  final Backend backend;
  const MyHomePage({super.key, required this.camera, required this.backend});
  @override
  _MyHomePageState createState() =>
      _MyHomePageState(camera: camera, backend: backend);
}

class _MyHomePageState extends State<MyHomePage> {
  final CameraDescription camera;
  final Backend backend;

  _MyHomePageState({required this.camera, required this.backend});

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
                        ),
                  ),
                );
              },
              child: Text('Describe Scene'),
            ),
            // ElevatedButton(
            //   onPressed: () {
            //     Navigator.push(
            //       context,
            //       MaterialPageRoute(
            //         builder:
            //             (context) =>
            //                 TextReadingScreen(camera: camera, backend: backend),
            //       ),
            //     );
            //   },
            //   child: Text('Read Text'),
            // ),
          ],
        ),
      ),
    );
  }
}
