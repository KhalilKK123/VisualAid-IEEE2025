import 'package:flutter/material.dart';
import 'package:visual_aid_ui/tts.dart';

class TtsSettingsScreen extends StatefulWidget {
  final TTS tts;
  const TtsSettingsScreen({super.key, required this.tts});

  @override
  State<TtsSettingsScreen> createState() => _TtsSettingsScreenState(tts: tts);
}

class _TtsSettingsScreenState extends State<TtsSettingsScreen> {
  final TTS tts;
  _TtsSettingsScreenState({required this.tts});

  @override
  void initState() {
    tts.initTts();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Column(
          children: [
            Slider(
              value: tts.volume,
              onChanged: (newVolume) {
                setState(() {
                  tts.volume = newVolume;
                  // tts.speak("hello, this is the new volume");
                });
              },
              onChangeEnd: (newVolume) {
                tts.speak("hello, this is the new volume");
              },
              min: 0.0,
              max: 1.0,
              divisions: 10,
              label: "Volume: ${tts.volume.toStringAsFixed(1)}",
            ),
            Slider(
              value: tts.pitch,
              onChanged: (newPitch) {
                setState(() {
                  tts.pitch = newPitch;
                });
              },
              onChangeEnd: (newPitch) {
                tts.speak("hello, this is the new pitch");
              },
              min: 0.5,
              max: 2.0,
              divisions: 15,
              label: "Pitch: ${tts.pitch.toStringAsFixed(1)}",
              activeColor: Colors.red,
            ),
            Slider(
              value: tts.rate,
              onChanged: (newRate) {
                setState(() {
                  tts.rate = newRate;
                  tts.speak("hello, this is the new speed");
                });
              },
              onChangeEnd: (newRate) {
                tts.speak("hello, this is the new speed");
              },
              min: 0.0,
              max: 1.0,
              divisions: 10,
              label: "Rate: ${tts.rate.toStringAsFixed(1)}",
              activeColor: Colors.green,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    tts.stop();
    super.dispose();
  }
}
