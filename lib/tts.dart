import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_tts/flutter_tts.dart';

class TTS {
  late FlutterTts flutterTts;
  String? language;
  String? engine;
  double volume = 0.5;
  double pitch = 1.0;
  double rate = 0.5;
  bool isCurrentLanguageInstalled = false;

  // String? _newVoiceText;

  TtsState ttsState = TtsState.stopped;

  bool get isPlaying => ttsState == TtsState.playing;
  bool get isStopped => ttsState == TtsState.stopped;
  bool get isPaused => ttsState == TtsState.paused;
  bool get isContinued => ttsState == TtsState.continued;

  bool get isIOS => !kIsWeb && Platform.isIOS;
  bool get isAndroid => !kIsWeb && Platform.isAndroid;

  Future<void> _setAwaitOptions() async {
    await flutterTts.awaitSpeakCompletion(true);
  }

  Future<void> _getDefaultEngine() async {
    var engine = await flutterTts.getDefaultEngine;
    if (engine != null) {
      print(engine);
    }
  }

  Future<void> _getDefaultVoice() async {
    var voice = await flutterTts.getDefaultVoice;
    if (voice != null) {
      print(voice);
    }
  }

  Future<void> stop() async {
    var result = await flutterTts.stop();
    if (result == 1) () => ttsState = TtsState.stopped;
  }

  Future<void> pause() async {
    var result = await flutterTts.pause();
    if (result == 1) () => ttsState = TtsState.paused;
  }

  Future<void> speak(String? text) async {
    await flutterTts.setVolume(volume);
    await flutterTts.setSpeechRate(rate);
    await flutterTts.setPitch(pitch);

    if (text!.isNotEmpty) {
      await flutterTts.speak(text);
    }
  }

  dynamic initTts() {
    flutterTts = FlutterTts();

    _setAwaitOptions();

    if (isAndroid) {
      _getDefaultEngine();
      _getDefaultVoice();
    }

    flutterTts.setStartHandler(() {
      print("Playing");
      ttsState = TtsState.playing;
    });

    flutterTts.setCompletionHandler(() {
      print("Complete");
      ttsState = TtsState.stopped;
    });

    flutterTts.setCancelHandler(() {
      print("Cancel");
      ttsState = TtsState.stopped;
    });

    flutterTts.setPauseHandler(() {
      print("Paused");
      ttsState = TtsState.paused;
    });

    flutterTts.setContinueHandler(() {
      print("Continued");
      ttsState = TtsState.continued;
    });

    flutterTts.setErrorHandler((msg) {
      print("error: $msg");
      ttsState = TtsState.stopped;
    });
  }

  // later for settings page to adjust volume, pitch, and speed (rate)

  // Widget _volume() {
  //   return Slider(
  //     value: volume,
  //     onChanged: (newVolume) {
  //       setState(() => volume = newVolume);
  //     },
  //     min: 0.0,
  //     max: 1.0,
  //     divisions: 10,
  //     label: "Volume: ${volume.toStringAsFixed(1)}",
  //   );
  // }

  // Widget _pitch() {
  //   return Slider(
  //     value: pitch,
  //     onChanged: (newPitch) {
  //       setState(() => pitch = newPitch);
  //     },
  //     min: 0.5,
  //     max: 2.0,
  //     divisions: 15,
  //     label: "Pitch: ${pitch.toStringAsFixed(1)}",
  //     activeColor: Colors.red,
  //   );
  // }

  // Widget _rate() {
  //   return Slider(
  //     value: rate,
  //     onChanged: (newRate) {
  //       setState(() => rate = newRate);
  //     },
  //     min: 0.0,
  //     max: 1.0,
  //     divisions: 10,
  //     label: "Rate: ${rate.toStringAsFixed(1)}",
  //     activeColor: Colors.green,
  //   );
}

enum TtsState { playing, stopped, paused, continued }
