// ignore_for_file: deprecated_member_use

import 'dart:async';
// ignore: unused_import
import 'dart:convert'; // For json decoding in websocket handler (if needed)
import 'dart:math'; // For proximity calculation

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:flutter/foundation.dart';

import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../core/models/feature_config.dart';
import '../../core/services/websocket_service.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/tts_service.dart';
import '../../core/services/barcode_api_service.dart';

import '../../features/feature_registry.dart';
import '../../features/currency_detection/presentation/pages/currency_detection.dart';
import '../../features/object_detection/presentation/pages/object_detection_page.dart';
import '../../features/hazard_detection/presentation/pages/hazard_detection_page.dart';
import '../../features/scene_detection/presentation/pages/scene_detection_page.dart';
import '../../features/text_detection/presentation/pages/text_detection_page.dart';
import '../../features/barcode_scanner/presentation/pages/barcode_scanner_page.dart';
import '../../features/focus_mode/presentation/pages/focus_mode_page.dart';
import '../../features/supervision/presentation/pages/supervision_page.dart';

import '../widgets/camera_view_widget.dart';
import '../widgets/feature_title_banner.dart';
import '../widgets/action_button.dart';

import 'settings_screen.dart';
// --- Imports End -----------------------------------------------------------------------------------------

enum MediaType { image, gif, video }

class TutorialStepData {
  final String text;
  final String? mediaAssetPath;
  final MediaType? mediaType;
  final bool autoAdvanceAfterMediaEnds;
  final double? mediaHeight;
  final BoxFit mediaFit;

  TutorialStepData({
    required this.text,
    this.mediaAssetPath,
    this.mediaType,
    this.autoAdvanceAfterMediaEnds = false,
    this.mediaHeight,
    this.mediaFit = BoxFit.contain,
  });
}
// --- END MOVED DEFINITIONS ---

class HomeScreen extends StatefulWidget {
  final CameraDescription? camera;

  const HomeScreen({Key? key, required this.camera}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // --- State Variables -----------------------------------------------------------------------------------
  // Camera & Page View
  CameraController? _cameraController;
  Future<void>? _initializeControllerFuture;
  bool _isMainCameraInitializing = false;
  Key _cameraViewKey = UniqueKey();
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Speech Recognition
  final SpeechToText _speechToText = SpeechToText();
  bool _isListening = false;
  bool _speechEnabled = false;
  bool _isListeningForFocusObject = false;

  // Services & Settings
  final WebSocketService _webSocketService = WebSocketService();
  late List<FeatureConfig> _features;
  final SettingsService _settingsService = SettingsService();
  final TtsService _ttsService = TtsService();
  final BarcodeApiService _barcodeApiService = BarcodeApiService();
  bool _ttsInitialized = false;
  String _selectedOcrLanguage = SettingsService.getValidatedDefaultLanguage();
  String _selectedObjectCategory = defaultObjectCategory;
  String? _globalTtsLanguageSetting =
      'en-US'; // Default TTS language to revert to. 'en-US' is a fallback.

  // Detection Results & State (for dedicated pages)
  String _lastObjectResult = "";
  String _lastSceneTextResult = "";
  String _lastCurrencyResult = "";
  // String _lastHazardRawResult = ""; // Not directly used for display, processed into below
  String _currentDisplayedHazardName = "";
  bool _isHazardAlertActive = false;

  // SuperVision State
  String _supervisionHazardName =
      ""; // Specific hazard name for SuperVisionPage
  bool _supervisionIsHazardActive =
      false; // Specific hazard active state for SuperVisionPage
  bool _isSupervisionProcessing = false; // Loading state for SuperVision
  String?
      _supervisionResultType; // e.g., 'object_detection', 'scene_detection' as determined by LLM
  String _supervisionDisplayResult =
      ""; // The result string to display on SuperVisionPage

  // Timers & Processing Flags
  Timer? _hazardAlertClearTimer;
  Timer? _detectionTimer;
  bool _isProcessingImage =
      false; // General flag for when an image is being sent/processed
  String?
      _lastRequestedFeatureId; // Tracks which feature requested the last image

  // Focus Mode State
  bool _isFocusModeActive = false;
  String? _focusedObject;
  bool _isFocusPromptActive = false;
  bool _isFocusObjectDetectedInFrame = false;
  bool _isFocusObjectCentered = false;
  bool _announcedFocusFound = false;
  double _currentProximity = 0.0;
  Timer? _focusBeepTimer;
  final AudioPlayer _beepPlayer = AudioPlayer(); // For focus beeps

  // Audio & Haptics
  final AudioPlayer _alertAudioPlayer = AudioPlayer(); // For hazard alerts
  bool _hasVibrator = false;
  bool? _hasAmplitudeControl;

  // --- Constants ------------------------------------------------------------------------------------------
  static const String _alertSoundPath = "audio/alert.mp3";
  static const String _beepSoundPath = "assets/audio/short_beep.mp3";
  static const Duration _detectionInterval = Duration(seconds: 5);
  static const Duration _hazardAlertPersistence = Duration(seconds: 4);
  static const Duration _focusFoundAnnounceCooldown = Duration(seconds: 5);
  static const double _focusCenterThreshold = 0.15;
  static const int _focusBeepMaxIntervalMs = 1200;
  static const int _focusBeepMinIntervalMs = 150;
  static const Set<String> _hazardObjectNames = {
    "car",
    "bicycle",
    "motorcycle",
    "bus",
    "train",
    "truck",
    "boat",
    "traffic light",
    "stop sign",
    "knife",
    "scissors",
    "fork",
    "oven",
    "toaster",
    "microwave",
    "bird",
    "cat",
    "dog",
    "horse",
    "sheep",
    "cow",
    "elephant",
    "bear",
    "zebra",
    "giraffe"
  };

  static const String _hasRunBeforeKey =
      'has_run_before'; // to check if run before

  // --- Tutorial State Variables ---
  // bool _isTutorialActive = false;
  // int _currentTutorialStep = 0;
  // List<String> _tutorialMessages = [];
  // List<String> _featureSpecificTutorialMessages = [];
  // bool _isFirstRun = true; // Assume true until checked
  // bool _isTutorialSpeaking = false; // To manage TTS during tutorial
  // bool _isSkipping = false;

  bool _isTutorialActive = false;
  int _currentTutorialStep = 0;
  List<TutorialStepData> _tutorialStepsData = [];
  List<TutorialStepData> _currentFeatureHelpSteps = [];
  bool _isFirstRun = true;
  bool _isTutorialSpeaking = false;
  bool _isSkipping = false;

  VideoPlayerController? _tutorialVideoController;
  Future<void>? _initializeVideoPlayerFuture;
  bool _isVideoBuffering = false;

  // --- Lifecycle Methods ------------------------------------------------------------------------------------
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
    debugPrint("[HomeScreen] initState Completed");
  }

  @override
  void dispose() {
    debugPrint("[HomeScreen] Disposing...");
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _disposeMainCameraController();
    _stopDetectionTimer();
    _hazardAlertClearTimer?.cancel();
    _stopFocusFeedback();
    if (_speechToText.isListening) _speechToText.stop();
    _speechToText.cancel();
    if (_ttsInitialized) _ttsService.dispose();
    _alertAudioPlayer.dispose();
    _beepPlayer.dispose();
    _webSocketService.close();
    debugPrint("[HomeScreen] Dispose complete.");
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final currentFeatureId = _features.isNotEmpty
        ? _features[_currentPage.clamp(0, _features.length - 1)].id
        : null;
    debugPrint(
        "[Lifecycle] State changed to: $state, Current Page: $currentFeatureId (Focus Active: $_isFocusModeActive, SuperVision Active: ${currentFeatureId == supervisionFeature.id})");

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _handleAppPause();
    } else if (state == AppLifecycleState.resumed) {
      _handleAppResume();
    }
  }

  // --- Initialization Helper -----------------------------------------------------------------------------------
  Future<void> _initializeApp() async {
    _initializeFeatures();

    // Load OCR lang and TTS V/P/R settings first
    final initialSettings = await Future.wait([
      _settingsService.getOcrLanguage(),
      _settingsService.getTtsVolume(),
      _settingsService.getTtsPitch(),
      _settingsService.getTtsRate(),
      _settingsService.getObjectDetectionCategory(),
    ]);
    _selectedOcrLanguage = initialSettings[0] as String;
    final ttsVolume = initialSettings[1] as double;
    final ttsPitch = initialSettings[2] as double;
    final ttsRate = initialSettings[3] as double;
    _selectedObjectCategory = initialSettings[4] as String;

    if (!_ttsInitialized) {
      await _ttsService.initTts(
          initialVolume: ttsVolume,
          initialPitch: ttsPitch,
          initialRate: ttsRate);
      _ttsInitialized = true;
      // Set initial global TTS language right after TTS init
      await _ttsService.setSpeechLanguage(_globalTtsLanguageSetting);
      debugPrint(
          "[TTS Lang] Initial app TTS language set to global: '$_globalTtsLanguageSetting'");
    } else {
      // If already initialized, update V,P,R but language is handled by page logic
      await _ttsService.updateSettings(ttsVolume, ttsPitch, ttsRate);
    }

    await _loadAndInitializeSettings();
    await _checkVibratorAndAmplitude();
    await _prepareAudioPlayers();
    //_initializeTutorialContent(); // Initialize tutorial messages
    // Check for first run after settings are loaded (SharedPreferences is available)
    await _checkFirstRun();

    final currentFeatureId = _features.isNotEmpty
        ? _features[_currentPage.clamp(0, _features.length - 1)].id
        : null;
    if (currentFeatureId != barcodeScannerFeature.id &&
        currentFeatureId != focusModeFeature.id) {
      await _initializeMainCameraController();
    } else {
      debugPrint(
          "[HomeScreen] Initializing on barcode/focus page, skipping initial main camera init.");
    }
    await _initSpeech();
    _initializeWebSocket();

    if (_isFirstRun && _ttsInitialized) {
      // Delay slightly to ensure UI is ready before starting tutorial
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted
            //&& _isFirstRun
            ) {
          // Double check _isFirstRun in case of quick state changes
          _startFullTutorial(isAutoStart: true);
        }
      });
    } else if (_ttsInitialized &&
        _features.isNotEmpty &&
        _features.first.title.isNotEmpty &&
        !_isTutorialActive) {
      _ttsService.speak(_features[0].title);
    }
  }

  Future<void> _checkFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isFirstRun = !(prefs.getBool(_hasRunBeforeKey) ?? false);
    });
    if (_isFirstRun) {
      debugPrint("[HomeScreen] First run detected.");
      // Mark that the app has run, so tutorial doesn't auto-start next time
      // Do this after the tutorial completes, or immediately if preferred.
      // For now, let's mark it when tutorial starts.
    } else {
      debugPrint("[HomeScreen] Not a first run.");
    }
  }

  void _initializeFeatures() {
    // Assumes availableFeatures from feature_registry.dart includes ALL features
    // (SuperVision, FocusMode, and others) in the desired order.
    _features = availableFeatures;
    debugPrint(
        "[HomeScreen] Features Initialized: ${_features.map((f) => f.id).toList()}");
  }

  Future<void> _loadAndInitializeSettings() async {
    // This function is primarily called when returning from settings.
    // It re-loads OCR language and TTS V/P/R.
    // TTS language itself will be re-evaluated based on current page context after this.
    final results = await Future.wait([
      _settingsService.getOcrLanguage(),
      _settingsService.getTtsVolume(),
      _settingsService.getTtsPitch(),
      _settingsService.getTtsRate(),
      _settingsService.getObjectDetectionCategory(),
    ]);
    _selectedOcrLanguage = results[0] as String;
    final ttsVolume = results[1] as double;
    final ttsPitch = results[2] as double;
    final ttsRate = results[3] as double;
    _selectedObjectCategory = results[4] as String;

    if (!_ttsInitialized) {
      // Should not happen if returning from settings, but good for robustness
      await _ttsService.initTts(
          initialVolume: ttsVolume,
          initialPitch: ttsPitch,
          initialRate: ttsRate);
      _ttsInitialized = true;
      await _ttsService.setSpeechLanguage(
          _globalTtsLanguageSetting); // Set to global if first time
    } else {
      await _ttsService.updateSettings(ttsVolume, ttsPitch, ttsRate);
      // TTS language is NOT set here directly, it will be handled by the calling context
      // (e.g., in _navigateToSettingsPage's return block)
    }
    debugPrint(
        "[HomeScreen] Settings loaded/reloaded. OCR: $_selectedOcrLanguage, Cat: $_selectedObjectCategory");
  }

  Future<void> _checkVibratorAndAmplitude() async {
    try {
      _hasVibrator = await Vibration.hasVibrator();
      if (_hasVibrator) {
        _hasAmplitudeControl = await Vibration.hasAmplitudeControl();
      } else {
        _hasAmplitudeControl = false;
      }
      debugPrint(
          "[HomeScreen] Vibrator available: $_hasVibrator, Amplitude Control: $_hasAmplitudeControl");
    } catch (e) {
      debugPrint("[HomeScreen] Error checking vibration capabilities: $e");
      _hasVibrator = false;
      _hasAmplitudeControl = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _prepareAudioPlayers() async {
    try {
      await _beepPlayer.setReleaseMode(ReleaseMode.stop);
      await _alertAudioPlayer.setReleaseMode(ReleaseMode.stop);
    } catch (e) {
      debugPrint("[HomeScreen] Error preparing audio players: $e");
    }
  }

// --- Tutorial Logic ---

  void _initializeTutorialContent() {
    // Example: Replace with your actual asset paths and desired media types
    _tutorialStepsData = [
      TutorialStepData(
        text: "Welcome to Blink AI.",
        mediaAssetPath:
            "assets/tutorial_media/app_logo.jpg", // Placeholder - REPLACE
        mediaType: MediaType.image,
        mediaHeight: 120,
      ),
      TutorialStepData(
        text:
            "This app is designed to help you understand your surroundings using your phone's camera and advanced analysis.",
      ),
      TutorialStepData(
        text: "Let's quickly go over the app's interface.",
      ),
      TutorialStepData(
        text:
            "At the top, you'll see the title of the currently selected feature, like 'Object Detection'.",

      ),
      TutorialStepData(
        text: "At the bottom center is the main action button.",

      ),
      TutorialStepData(
        text:
            "For features like Text Recognition or Scene Description, tapping this button will capture an image and process it.",
      ),
      TutorialStepData(
        text:
            "Long-pressing this button activates voice commands, allowing you to switch features or change settings by speaking.",
      ),
      TutorialStepData(
        text:
            "On the left and right edges of the screen, you'll find arrow buttons.",
        mediaAssetPath:
            "assets/tutorial_media/navigation_arrows_example.mp4", // Placeholder - REPLACE

      ),
      TutorialStepData(
        text:
            "You can tap these to navigate to the previous or next feature. You can also swipe left or right anywhere on the screen to change features.",
      ),
      TutorialStepData(
        text:
            "In the top right corner, the gear icon opens the settings screen. Here, you can adjust voice speed, language for text recognition, and object detection filters. you can also chnage the object detection filters to filter what types of objects are detected, uisng voice commands, just hold the main action button and say the phrase \" category \" then name your category.",

      ),
      TutorialStepData(
        text:
            "And in the top left corner, you'll see a question mark icon. That's the tutorial button! Tap it anytime for a quick explanation of the current feature. Long-press it to replay this full tutorial.",

      ),
      TutorialStepData(
        text: "Blink AI offers several powerful features. Let's explore them.",
      ),
      TutorialStepData(
          text:
              "SuperVision: This is our middleware feature, for your convenience. When on the SuperVision page, tap the main action button. It analyzes the camera view using AI, and, based on the analysis, it might include identifying objects, describing the scene, reading text, or even alerting you to hazards it finds."),
      TutorialStepData(
          text:
              "Object Detection: This feature works in real-time. As you point your phone around, it will continuously identify and announce objects it sees. You can filter what types of objects are detected in the settings menu."),
      TutorialStepData(
          text:
              "Hazard Detection: This feature also works in real-time to alert you to potential hazards, such as cars or specific items that could be dangerous. If a hazard is detected, the app will make a sound and vibrate."),
      TutorialStepData(
          text:
              "Object Finder: First, tap the main action button. The app will ask you to say the name of the object you want to find. After you say the object's name, the app will use sound and vibration to help guide you towards it as it's detected in the camera's view."),
      TutorialStepData(
          text:
              "Scene Description: Point your phone towards an area you want to understand better, then tap the main action button. The app will process the image and describe the scene to you."),
      TutorialStepData(
          text:
              "Text Recognition: If you want to read text from a document, sign, or product, point your phone at the text and tap the main action button. The app will read the detected text aloud. You can change the language for text recognition in the settings."),
      TutorialStepData(
          text:
              "Currency Detection: Tap the main action button when on the currency page. The app will analyze the image and announce the detected currency."),
      TutorialStepData(
          text:
              "Barcode Scanner: This feature activates automatically when you navigate to its page. Simply point your camera at a barcode. The app will scan it and, if the product is in its database, tell you the product information."),
      TutorialStepData(
          text: "To navigate between these features, you have a few options."),
      TutorialStepData(
          text:
              "You can swipe left or right anywhere on the main part of the screen."),
      TutorialStepData(
          text:
              "You can tap the large arrow buttons that appear on the left and right sides of the screen."),
      TutorialStepData(
          text:
              "Or, you can use voice commands. Long-press the main action button at the bottom, wait for the prompt, and then say the feature name like 'object detection', 'go to page 3', or 'barcode scanner'. You can also say 'settings' to go to the settings page."),
      TutorialStepData(
          text:
              "Remember, if you ever need a quick reminder on how to use the feature you're currently on, just tap the question mark button in the top left. To hear this full tutorial again, long-press that same question mark button."),
      TutorialStepData(
          text:
              "This concludes the main tutorial. We hope Vision Aid empowers you to explore your world with greater confidence. Happy exploring!"),
    ];
  }

  Future<void> _markTutorialAsCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hasRunBeforeKey, true);
    if (mounted) {
      setState(() {
        _isFirstRun = false;
      });
    }
    debugPrint("[Tutorial] Marked as completed. First run is now false.");
  }

  // Listener function needs to be defined to be removable and accessible
  void _videoListener() {
    if (!mounted ||
        !_isTutorialActive ||
        _tutorialVideoController == null ||
        !_tutorialVideoController!.value.isInitialized) {
      // Clean up listener if state is no longer valid for it
      _tutorialVideoController?.removeListener(_videoListener);
      return;
    }

    final currentDataSource = _currentFeatureHelpSteps.isNotEmpty
        ? _currentFeatureHelpSteps
        : _tutorialStepsData;
    if (_currentTutorialStep >= currentDataSource.length) {
      _tutorialVideoController?.removeListener(_videoListener);
      return;
    }
    final stepData = currentDataSource[_currentTutorialStep];
    final int stepBeingListenedTo =
        _currentTutorialStep; // Capture for async safety

    final bool isVideoCompleted =
        _tutorialVideoController!.value.isInitialized && // Ensure initialized
            _tutorialVideoController!.value.position >=
                _tutorialVideoController!.value.duration &&
            !_tutorialVideoController!.value.isPlaying &&
            !_tutorialVideoController!
                .value.isBuffering; // Ensure not just paused during buffering

    if (isVideoCompleted) {
      debugPrint(
          "[Tutorial] Video Listener: Video completed for step $stepBeingListenedTo");
      _tutorialVideoController!
          .removeListener(_videoListener); // Clean up listener for this video

      if (stepData.autoAdvanceAfterMediaEnds) {
        debugPrint(
            "[Tutorial] Video completed and autoAdvance is true. Advancing to next step.");
        Future.delayed(const Duration(milliseconds: 150), () {
          // Short delay for smoother transition
          if (mounted &&
              _isTutorialActive &&
              _currentTutorialStep == stepBeingListenedTo) {
            _handleTutorialSkip(isAutoAdvance: true);
          }
        });
      } else {
        debugPrint(
            "[Tutorial] Video completed, autoAdvance is false. Speaking text if any for step $stepBeingListenedTo.");
        if (mounted &&
            _isTutorialActive &&
            _currentTutorialStep == stepBeingListenedTo) {
          _isTutorialSpeaking = stepData.text
              .isNotEmpty; // Allow TTS for the text part of this video step
          if (mounted)
            setState(
                () {}); // Update UI to reflect potential change in "tap to skip" message
          _speakTutorialStepText(
              stepData, stepBeingListenedTo, currentDataSource);
        }
      }
    }
  }

  Future<void> _disposeTutorialVideoController() async {
    if (_tutorialVideoController != null) {
      debugPrint(
          "[Tutorial] Disposing tutorial video controller (DataSource: ${_tutorialVideoController?.dataSource})");
      final controllerToDispose = _tutorialVideoController;
      _tutorialVideoController = null; // Nullify immediately
      controllerToDispose
          ?.removeListener(_videoListener); // Remove listener before dispose
      await controllerToDispose?.pause();
      await controllerToDispose?.dispose();
      if (mounted) {
        // SetState is only needed if these directly drive UI rebuilding that wouldn't otherwise happen.
        // _initializeVideoPlayerFuture often triggers a FutureBuilder, so nullifying it is important.
        if (_initializeVideoPlayerFuture != null || _isVideoBuffering) {
          setState(() {
            _initializeVideoPlayerFuture = null;
            _isVideoBuffering = false;
          });
        }
      }
    }
  }

  void _startFullTutorial({bool isAutoStart = false}) async {
    debugPrint(
        "[Tutorial] _startFullTutorial CALLED. isAutoStart: $isAutoStart, Mounted: $mounted, TTS Initialized: $_ttsInitialized, isFirstRun: $_isFirstRun");
    _stopDetectionTimer(); // <<< ADD OR ENSURE THIS IS PRESENT AND EARLY
    if (!mounted) {
      debugPrint("[Tutorial] _startFullTutorial aborted: Not mounted.");
      return;
    }
    if (!_ttsInitialized) {
      debugPrint(
          "[Tutorial] _startFullTutorial aborted: TTS not initialized. Attempting init...");
      final initialSettings = await Future.wait([
        _settingsService.getTtsVolume(),
        _settingsService.getTtsPitch(),
        _settingsService.getTtsRate()
      ]);

      await _ttsService.initTts(
          initialVolume: initialSettings[0],
          initialPitch: initialSettings[1],
          initialRate: initialSettings[2]);
      _ttsInitialized = true;
      await _ttsService.setSpeechLanguage(_globalTtsLanguageSetting);
      debugPrint(
          "[Tutorial] Fallback TTS initialization attempted. TTS Initialized: $_ttsInitialized");
      if (!_ttsInitialized) return;
    }

    await _disposeTutorialVideoController();

    if (_isTutorialActive && _isTutorialSpeaking) {
      debugPrint(
          "[Tutorial] Full tutorial requested while another was active and speaking. Stopping current TTS.");
      await _ttsService.stop();
    } else if (_isTutorialActive && _tutorialVideoController != null) {
      debugPrint(
          "[Tutorial] Full tutorial requested while a video might be playing. Disposing video.");
      await _disposeTutorialVideoController(); // Ensure video stops if tutorial was active but not speaking
    }

    if (isAutoStart && !_isFirstRun) {
      debugPrint(
          "[Tutorial] _startFullTutorial (auto): Not a first run, skipping auto-start.");
      return;
    }

    debugPrint(
        "[Tutorial] Proceeding with _startFullTutorial. Current _isTutorialActive: $_isTutorialActive");

    await _ttsService.stop();
    debugPrint(
        "[Tutorial] TTS explicitly stopped. TTS Service isPlaying: ${_ttsService.isPlaying}, ttsState: ${_ttsService.ttsState}");

    _currentFeatureHelpSteps = [];

    if (_tutorialStepsData.isEmpty) {
      debugPrint(
          "[Tutorial] _tutorialStepsData is EMPTY in _startFullTutorial. Re-initializing it now.");
      _initializeTutorialContent(); // This should populate _tutorialStepsData
      debugPrint(
          "[Tutorial] _startFullTutorial: _tutorialStepsData length after re-init: ${_tutorialStepsData.length}");
      if (_tutorialStepsData.isEmpty) {
        debugPrint(
            "[Tutorial] CRITICAL: _tutorialStepsData STILL EMPTY after re-init. Aborting full tutorial.");
        if (mounted) {
          setState(() {
            _isTutorialActive = false;
          });
        }
        return;
      }
    } else {
      debugPrint(
          "[Tutorial] _startFullTutorial: _tutorialStepsData already populated. Length: ${_tutorialStepsData.length}");
    }

    if (mounted) {
      setState(() {
        _isTutorialActive = true;
        _currentTutorialStep = 0;
        // _isTutorialSpeaking will be determined by _playNextTutorialStep based on the first step's content
      });
    } else {
      debugPrint(
          "[Tutorial] _startFullTutorial aborted after checks: Not mounted before setState.");
      return;
    }

    if (isAutoStart || _isFirstRun) {
      if (isAutoStart && _isFirstRun) {
        await _markTutorialAsCompleted();
      } else if (!isAutoStart && _isFirstRun) {
        await _markTutorialAsCompleted();
      }
    }

    debugPrint(
        "[Tutorial] _startFullTutorial about to call _playNextTutorialStep with _tutorialStepsData.");
    _playNextTutorialStep(dataSource: _tutorialStepsData);
  }

  List<TutorialStepData> _getFeatureSpecificHelpSteps(String featureId) {
    // This function should already be correct from your previous version.
    // Ensure it returns List<TutorialStepData>
    switch (featureId) {
      case 'supervision':
        return [
          TutorialStepData(
              text:
                  "SuperVision: Tap the main action button at the bottom. The app will then analyze what the camera sees and provide a smart description using AI, through automatically identifying what the camera sees. Long press the action button for general voice commands.")
        ];
      case 'object_detection':
        return [
          TutorialStepData(
              text:
                  "Object Detection: This feature runs in real-time. Point your camera, and it will announce recognized objects along with their reltaive location. No need to tap the button unless you want to use voice commands via long press. You can filter object categories by holding the main button and saying the object name, or you do so from the settings page.")
        ];
      case 'hazard_detection':
        return [
          TutorialStepData(
              text:
                  "Hazard Detection: This feature runs in real-time. It automatically alerts you to potential hazards with sound and vibration. No button tap needed for detection. Long press the action button for general voice commands.")
        ];
      case 'focus_mode':
        return [
          TutorialStepData(
              text:
                  "Metal Detector: Tap the main action button, then clearly say the name of the object you're looking for. The app will then use sounds and vibrations to guide you as the object comes into view and gets closer to the center.")
        ];
      case 'scene_detection':
        return [
          TutorialStepData(
              text:
                  "Scene Description: Point your camera at the scene you want described, then tap the main action button. The app will analyze and describe it. Long press for voice commands.")
        ];
      case 'text_detection':
        return [
          TutorialStepData(
              text:
                  "Text Recognition: Point your camera at the text you want to read, then tap the main action button. The app will detect and read the text aloud. Change OCR language in settings. Long press for voice commands.")
        ];
      case 'currency_detection':
        return [
          TutorialStepData(
              text:
                  "Currency Detection: Tap the main action button when on the currency page. The app will analyze the image and announce the detected currency.")
        ];
      case 'barcode_scanner':
        return [
          TutorialStepData(
              text:
                  "Barcode Scanner: This activates automatically on this page. Point your camera at a barcode to scan it. The app will announce product information if found. No button tap needed for scanning.")
        ];
      default:
        return [
          TutorialStepData(
              text:
                  "Help for this feature is not yet available. Tap the main action button or long press for voice commands.")
        ];
    }
  }

  void _startCurrentFeatureTutorial() async {
    if (!mounted || !_ttsInitialized) return;

    await _disposeTutorialVideoController();

    if (_isTutorialActive && _isTutorialSpeaking) {
      await _ttsService.stop();
    } else if (_isTutorialActive && _tutorialVideoController != null) {
      await _disposeTutorialVideoController();
    }

    await _ttsService.stop();

    _stopDetectionTimer(); // <<< ADD OR ENSURE THIS IS PRESENT AND EARLY
    await _disposeTutorialVideoController();

    final currentFeature =
        _features[_currentPage.clamp(0, _features.length - 1)];
    _currentFeatureHelpSteps = _getFeatureSpecificHelpSteps(currentFeature.id);
    // _tutorialStepsData = []; // DO NOT CLEAR _tutorialStepsData HERE. It's for the main tutorial.

    debugPrint("[Tutorial] Starting help for feature: ${currentFeature.title}");

    if (mounted) {
      setState(() {
        _isTutorialActive = true;
        _currentTutorialStep = 0;
        // _isTutorialSpeaking will be set by _playNextTutorialStep
      });
    } else {
      return;
    }
    _playNextTutorialStep(dataSource: _currentFeatureHelpSteps);
  }

  Future<void> _handleTutorialSkip({bool isAutoAdvance = false}) async {
    if (!mounted || !_isTutorialActive || _isSkipping) return;

    _isSkipping = true;
    final int stepSkippedFrom = _currentTutorialStep;
    debugPrint(
        "[Tutorial] Skip handling started for step $stepSkippedFrom. AutoAdvance: $isAutoAdvance");

    if (!isAutoAdvance) {
      await _ttsService.stop();
      await _disposeTutorialVideoController();
    }

    _currentTutorialStep++;

    final List<TutorialStepData> currentDataSource =
        _currentFeatureHelpSteps.isNotEmpty
            ? _currentFeatureHelpSteps
            : _tutorialStepsData;

    if (mounted && _isTutorialActive) {
      if (_currentTutorialStep < currentDataSource.length) {
        debugPrint("[Tutorial] Skipping to step $_currentTutorialStep.");
        _playNextTutorialStep(dataSource: currentDataSource);
      } else {
        debugPrint("[Tutorial] Skip: Reached end of tutorial.");
        _endTutorial(); // Call _endTutorial which now handles restarting the timer
      }
    }
    if (mounted) _isSkipping = false; // Reset skipping flag
    // No need to call _startDetectionTimerIfNeeded() here directly,
    // as _endTutorial() will be called if it's the end of the tutorial.
    debugPrint("[Tutorial] Skip handling finished for step $stepSkippedFrom.");
  }

  void _playNextTutorialStep(
      {required List<TutorialStepData> dataSource}) async {
    if (!mounted || !_isTutorialActive || dataSource.isEmpty) {
      // Added dataSource.isEmpty check
      if (_isTutorialActive && mounted) _endTutorial();
      return;
    }

    final currentStepIndexForVideoCheck = _currentTutorialStep;
    if (_tutorialVideoController != null) {
      if (currentStepIndexForVideoCheck < dataSource.length) {
        final nextStepData = dataSource[currentStepIndexForVideoCheck];
        // A more robust check for "same video" might compare the full dataSource string
        // This simplified check assumes different asset paths mean different videos.
        bool disposeOldVideo = true;
        if (nextStepData.mediaType == MediaType.video &&
            _tutorialVideoController!.dataSource
                .contains(nextStepData.mediaAssetPath!)) {
          // Check if current controller is for the next step's video
          // Potentially, if it's the exact same video asset, you might not dispose.
          // For now, let's assume if it's a new step, we prefer a fresh controller unless logic is more complex.
          // This check is a bit loose. A direct string comparison of asset paths is better.
          if (_tutorialVideoController!.dataSource ==
              VideoPlayerController.asset(nextStepData.mediaAssetPath!)
                  .dataSource) {
            // More direct
            disposeOldVideo =
                false; // It's the same video, don't dispose if you want to resume/seek
            debugPrint(
                "[Tutorial PlayNext] Next step is same video. Not disposing controller.");
          }
        }
        if (disposeOldVideo) await _disposeTutorialVideoController();
      } else {
        await _disposeTutorialVideoController();
      }
    }

    if (_currentTutorialStep >= dataSource.length) {
      _endTutorial();
      return;
    }

    final stepData = dataSource[_currentTutorialStep];
    debugPrint(
        "[Tutorial PlayNext] Playing step ${_currentTutorialStep + 1}/${dataSource.length}: \"${stepData.text.substring(0, min(stepData.text.length, 30))}...\" Media: ${stepData.mediaAssetPath ?? 'None'}");

    if (mounted) {
      // _isTutorialSpeaking should be true if this step has text and we intend to speak it.
      // It can be set to false by video logic if text is deferred.
      _isTutorialSpeaking = stepData.text.isNotEmpty;
      setState(() {});
    } else {
      return;
    }

    final int stepForThisCall = _currentTutorialStep;

    if (stepData.mediaAssetPath != null &&
        stepData.mediaType == MediaType.video) {
      if (mounted) setState(() => _isVideoBuffering = true);

      // Determine if TTS for this step should be paused while video loads/plays
      // If video has text and does not auto-advance the entire step, TTS might be deferred.
      bool deferTTSForVideo =
          stepData.text.isNotEmpty && !stepData.autoAdvanceAfterMediaEnds;
      if (deferTTSForVideo) {
        _isTutorialSpeaking = false; // TTS will be triggered by video listener
      }

      _tutorialVideoController =
          VideoPlayerController.asset(stepData.mediaAssetPath!);
      _tutorialVideoController!.addListener(_videoListener);
      _initializeVideoPlayerFuture =
          _tutorialVideoController!.initialize().then((_) {
        if (!mounted ||
            !_isTutorialActive ||
            stepForThisCall != _currentTutorialStep) {
          debugPrint(
              "[Tutorial PlayNext] Video init: Stale step or tutorial inactive. Disposing.");
          _disposeTutorialVideoController();
          return;
        }
        if (mounted) setState(() => _isVideoBuffering = false);
        _tutorialVideoController!.play();
        debugPrint(
            "[Tutorial PlayNext] Video playing: ${stepData.mediaAssetPath}");

        // If this video step has no text, and doesn't auto-advance, then _isTutorialSpeaking should be false
        // so the user must tap to continue after the video.
        if (stepData.text.isEmpty && !stepData.autoAdvanceAfterMediaEnds) {
          if (mounted) setState(() => _isTutorialSpeaking = false);
        }
        // If video has text but doesn't auto-advance the step, listener handles speaking.
        // If video auto-advances the step, listener calls _handleTutorialSkip.
      }).catchError((error, stackTrace) {
        debugPrint(
            "[Tutorial PlayNext] Error initializing video '${stepData.mediaAssetPath}': $error \n$stackTrace");
        if (mounted) setState(() => _isVideoBuffering = false);
        if (mounted &&
            _isTutorialActive &&
            stepForThisCall == _currentTutorialStep) {
          // If video fails, ensure _isTutorialSpeaking is true if there's text, then speak it.
          _isTutorialSpeaking = stepData.text.isNotEmpty;
          _speakTutorialStepText(stepData, stepForThisCall, dataSource);
        }
      });
    } else {
      // Image, GIF, or no media
      // _isTutorialSpeaking is already set based on stepData.text.isNotEmpty
      _speakTutorialStepText(stepData, stepForThisCall, dataSource);
    }
  }

  Future<void> _speakTutorialStepText(TutorialStepData stepData,
      int stepForThisCall, List<TutorialStepData> dataSource) async {
    if (!mounted ||
        !_isTutorialActive ||
        !_isTutorialSpeaking ||
        stepForThisCall != _currentTutorialStep) {
      // If conditions are not met (e.g. tutorial was ended, or this isn't the current step anymore) then abort.
      // Also, if _isTutorialSpeaking became false (e.g. user tapped skip while text was meant to play), abort speaking.
      debugPrint(
          "[Tutorial Speak] Aborted speak for step $stepForThisCall. Mounted: $mounted, Active: $_isTutorialActive, SpeakingFlag: $_isTutorialSpeaking, StepMatch: ${stepForThisCall == _currentTutorialStep}");
      return;
    }

    await _ttsService.speak(stepData.text);

    // After speaking, or if there was no text to speak for this step
    if (mounted &&
        _isTutorialActive &&
        _isTutorialSpeaking &&
        stepForThisCall == _currentTutorialStep) {
      // If it's not a video that's currently playing and waiting for completion to advance
      bool shouldAutoAdvanceAfterSpeech = true;
      if (stepData.mediaType == MediaType.video &&
          _tutorialVideoController != null &&
          _tutorialVideoController!.value.isInitialized &&
          _tutorialVideoController!.value.isPlaying) {
        if (!stepData.autoAdvanceAfterMediaEnds) {
          shouldAutoAdvanceAfterSpeech =
              false; // Video is playing, user will tap to advance or video listener handles it.
        }
      }

      // This condition was added to handle text after a non-auto-advancing video.
      // If the video auto-advances the *entire step*, its listener calls _handleTutorialSkip.
      if (stepData.mediaType == MediaType.video &&
          stepData.autoAdvanceAfterMediaEnds &&
          _tutorialVideoController != null &&
          _tutorialVideoController!.value.isInitialized &&
          !_tutorialVideoController!.value.isPlaying) {
        // This case means: it's a video step, it auto advances the step, and the video has finished playing.
        // The listener should have already called _handleTutorialSkip. So, don't advance here.
        shouldAutoAdvanceAfterSpeech = false;
        debugPrint(
            "[Tutorial Speak] Text for auto-advancing video step $stepForThisCall spoken. Listener handles step advancement.");
      }

      if (shouldAutoAdvanceAfterSpeech) {
        debugPrint(
            "[Tutorial Speak] Auto-advancing after speech/no-media for step $stepForThisCall");
        _currentTutorialStep++;
        _playNextTutorialStep(dataSource: dataSource);
      } else {
        debugPrint(
            "[Tutorial Speak] Not auto-advancing for step $stepForThisCall (e.g. video playing or non-auto-advancing video finished text)");
      }
    } else if (mounted &&
        _isTutorialActive &&
        !_isTutorialSpeaking &&
        stepForThisCall == _currentTutorialStep) {
      // This case: speaking flag was turned off (e.g., by manual skip) during awaited speak.
      debugPrint(
          "[Tutorial Speak] Speaking flag became false during/after speak for step $stepForThisCall. No auto-advance.");
    }
  }

  void _endTutorial() async {
    if (!mounted) return;
    debugPrint(
        "[Tutorial] Ending tutorial. Was active: $_isTutorialActive, Current step: $_currentTutorialStep");

    await _disposeTutorialVideoController();

    if (_isTutorialSpeaking || _ttsService.isPlaying) {
      await _ttsService.stop();
    }
    if (mounted) {
      setState(() {
        _isTutorialActive = false;
        _currentTutorialStep = 0;
        _isTutorialSpeaking = false;
        _currentFeatureHelpSteps = [];
      });
    }

    debugPrint(
        "[Tutorial] Tutorial ended. Attempting to restart detection timer if needed.");
    _startDetectionTimerIfNeeded(); // <<< THIS IS ALREADY HERE
  }
// --- End Tutorial Logic ---

  // --- Lifecycle Event Handlers -----------------------------------------------------------------------------------
  void _handleAppPause() {
    debugPrint("[Lifecycle] App inactive/paused - Cleaning up...");
    _stopDetectionTimer();
    _stopFocusFeedback();
    if (_ttsInitialized) _ttsService.stop();
    _alertAudioPlayer.pause();
    _beepPlayer.pause();
    _hazardAlertClearTimer?.cancel();

    final currentFeatureId = _features.isNotEmpty
        ? _features[_currentPage.clamp(0, _features.length - 1)].id
        : null;
    if (currentFeatureId != barcodeScannerFeature.id) {
      _disposeMainCameraController();
    } else {
      debugPrint(
          "[Lifecycle] App paused on barcode page, main camera already disposed.");
    }
  }

  void _handleAppResume() {
    debugPrint("[Lifecycle] App resumed");
    final currentFeatureId = _features.isNotEmpty
        ? _features[_currentPage.clamp(0, _features.length - 1)].id
        : null;

    // Re-initialize camera if needed (not barcode or focus mode without object)
    bool isFocusModeWaitingForObject =
        _isFocusModeActive && _focusedObject == null;
    if (currentFeatureId != barcodeScannerFeature.id &&
        !isFocusModeWaitingForObject) {
      debugPrint(
          "[Lifecycle] Resumed on non-barcode/non-initial-focus page. Ensuring main camera.");
      _initializeMainCameraController();
    } else {
      debugPrint(
          "[Lifecycle] Resumed on barcode page or initial focus page. Main camera remains off/uninitialized.");
    }

    if (!_webSocketService.isConnected) {
      debugPrint("[Lifecycle] Attempting WebSocket reconnect on resume...");
      _webSocketService.connect();
    } else {
      _startDetectionTimerIfNeeded();
    }
  }

  // --- Camera Management ---
  Future<void> _disposeMainCameraController() async {
    if (_cameraController == null &&
        _initializeControllerFuture == null &&
        !_isMainCameraInitializing) return;
    debugPrint("[HomeScreen] Disposing main camera controller...");
    _stopDetectionTimer();
    final controllerToDispose = _cameraController;
    final initFuture = _initializeControllerFuture;
    _cameraController = null;
    _initializeControllerFuture = null;
    _isMainCameraInitializing = false;
    _cameraViewKey = UniqueKey();
    if (mounted) setState(() {});
    try {
      if (initFuture != null)
        await initFuture
            .timeout(const Duration(milliseconds: 200))
            .catchError((_) {});
      if (controllerToDispose != null) {
        await controllerToDispose.dispose();
        debugPrint("[HomeScreen] Main camera disposed.");
      }
    } catch (e, s) {
      debugPrint("[HomeScreen] Error disposing camera: $e \n$s");
    }
    debugPrint("[HomeScreen] Main camera dispose sequence finished.");
  }

  Future<void> _initializeMainCameraController() async {
    debugPrint(
        "[HomeScreen] Attempting to initialize main camera controller...");
    final currentFeatureId = _features.isNotEmpty
        ? _features[_currentPage.clamp(0, _features.length - 1)].id
        : null;
    bool isFocusModeWaitingForObject =
        _isFocusModeActive && _focusedObject == null;
    if (widget.camera == null ||
        currentFeatureId == barcodeScannerFeature.id ||
        isFocusModeWaitingForObject ||
        _cameraController != null ||
        _isMainCameraInitializing) {
      debugPrint(
          "[HomeScreen] Skipping main camera init. Reason: No camera (${widget.camera == null}), Barcode ($currentFeatureId == ${barcodeScannerFeature.id}), Initial Focus ($isFocusModeWaitingForObject), Exists (${_cameraController != null}), Initializing ($_isMainCameraInitializing)");
      return;
    }
    if (!mounted) {
      debugPrint("[HomeScreen] Camera init skipped: Not mounted.");
      return;
    }
    debugPrint(
        "[HomeScreen] Proceeding with main CameraController initialization...");
    _isMainCameraInitializing = true;
    _cameraController = null;
    _initializeControllerFuture = null;
    _cameraViewKey = UniqueKey();
    if (mounted) setState(() {});
    await Future.delayed(const Duration(milliseconds: 50));
    isFocusModeWaitingForObject =
        _isFocusModeActive && _focusedObject == null; // Re-check
    final updatedCurrentFeatureId = _features.isNotEmpty
        ? _features[_currentPage.clamp(0, _features.length - 1)].id
        : null; // Re-check current page
    if (!mounted ||
        updatedCurrentFeatureId == barcodeScannerFeature.id ||
        isFocusModeWaitingForObject) {
      _isMainCameraInitializing = false;
      if (mounted) setState(() {});
      debugPrint(
          "[HomeScreen] Aborting camera init after delay. Mounted: $mounted, Feature: $updatedCurrentFeatureId, FocusWaiting: $isFocusModeWaitingForObject");
      return;
    }

    CameraController newController;
    try {
      newController = CameraController(widget.camera!, ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
    } catch (e) {
      debugPrint("[HomeScreen] Error creating CameraController: $e");
      if (mounted) {
        _showStatusMessage("Failed to create camera", isError: true);
        _isMainCameraInitializing = false;
        setState(() {});
      }
      return;
    }

    Future<void> initFuture;
    try {
      _cameraController = newController;
      initFuture = newController.initialize();
      _initializeControllerFuture = initFuture;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("[HomeScreen] Error assigning init future: $e");
      if (mounted) {
        _showStatusMessage("Failed camera init", isError: true);
        _cameraController = null;
        _initializeControllerFuture = null;
        _isMainCameraInitializing = false;
        setState(() {});
      }
      return;
    }

    try {
      await initFuture;
      if (!mounted) {
        debugPrint(
            "[HomeScreen] Camera init successful but widget unmounted. Disposing.");
        try {
          await newController.dispose();
        } catch (_) {}
        return;
      }
      if (_cameraController == newController) {
        debugPrint("[HomeScreen] Main Camera initialized successfully.");
        _isMainCameraInitializing = false;
        _startDetectionTimerIfNeeded();
      } else {
        debugPrint(
            "[HomeScreen] Camera controller changed during init. Disposing new.");
        try {
          await newController.dispose();
        } catch (_) {}
        _isMainCameraInitializing = false;
      }
    } catch (error, s) {
      debugPrint("[HomeScreen] Main Camera initialization error: $error\n$s");
      if (!mounted) {
        _isMainCameraInitializing = false;
        return;
      }
      final bool shouldReset = _cameraController == newController;
      if (shouldReset) {
        _showStatusMessage("Camera init failed", isError: true);
        _cameraController = null;
        _initializeControllerFuture = null;
      } else {
        try {
          await newController.dispose();
        } catch (_) {}
      }
      _isMainCameraInitializing = false;
    } finally {
      if (mounted) setState(() {});
    }
  }

// --- WebSocket Handling ---
  void _initializeWebSocket() {
    debugPrint("[HomeScreen] Initializing WebSocket listener...");
    _webSocketService.responseStream.listen(_handleWebSocketData,
        onError: _handleWebSocketError,
        onDone: _handleWebSocketDone,
        cancelOnError: false);
    _webSocketService.connect();
  }

  void _handleWebSocketData(Map<String, dynamic> data) {
    if (!mounted) return;

    // Handle connection event separately
    if (data.containsKey('event') && data['event'] == 'connect') {
      _showStatusMessage("Connected", durationSeconds: 2);
      _startDetectionTimerIfNeeded();
      return;
    }
    if (data.containsKey('event') &&
        (data['event'] == 'disconnect' ||
            data['event'] == 'error' ||
            data['event'] == 'connect_error' ||
            data['event'] == 'connect_timeout')) {
      _handleWebSocketError(data['message'] ??
          data['reason'] ??
          'Unknown connection issue: ${data['event']}');
      return;
    }

    final bool isSupervisionResponse = data['is_from_supervision_llm'] == true;

    if (isSupervisionResponse) {
      // --- Handle SuperVision Result ---
      debugPrint('[HomeScreen] Processing SuperVision routed result: $data');
      final String resultTextRaw = data['result'] as String? ?? "No result";
      final String? actualFeatureIdFromSupervision =
          data['feature_id'] as String?;

      if (actualFeatureIdFromSupervision == null) {
        debugPrint(
            '[HomeScreen] SuperVision result missing feature_id. Cannot process.');
        if (mounted) {
          setState(() {
            _isSupervisionProcessing = false;
            _supervisionDisplayResult =
                "Error: Invalid response from server (missing feature_id)";
            _supervisionResultType = "supervision_error"; // Mark as error type
          });
        }
        return;
      }

      setState(() {
        _isSupervisionProcessing = false;
        _supervisionResultType = actualFeatureIdFromSupervision;
        _supervisionDisplayResult = ""; // Clear previous
        _supervisionHazardName = ""; // Clear previous
        _supervisionIsHazardActive = false; // Clear previous
        String textToSpeak = "";

        if (actualFeatureIdFromSupervision == objectDetectionFeature.id) {
          final odResult =
              _processSupervisionObjectDetectionResult(resultTextRaw);
          _supervisionDisplayResult = odResult['display'];
          textToSpeak = odResult['speak']
              ? odResult['speakText']
              : "Object detection complete.";
          List<String> detectedObjectsList = resultTextRaw.isNotEmpty &&
                  !resultTextRaw.startsWith("Error") &&
                  resultTextRaw != "No objects detected"
              ? resultTextRaw
                  .toLowerCase()
                  .split(',')
                  .map((e) => e.trim())
                  .toList()
              : [];
          String hazardNameFromOD =
              _processHazardDetection(detectedObjectsList);
          if (hazardNameFromOD.isNotEmpty) {
            _supervisionHazardName = hazardNameFromOD;
            _supervisionIsHazardActive = _isHazardAlertActive;
          }
        } else if (actualFeatureIdFromSupervision ==
            hazardDetectionFeature.id) {
          List<String> detectedObjectsList = resultTextRaw.isNotEmpty &&
                  !resultTextRaw.startsWith("Error") &&
                  resultTextRaw != "No objects detected"
              ? resultTextRaw
                  .toLowerCase()
                  .split(',')
                  .map((e) => e.trim())
                  .toList()
              : [];
          String hazardName = _processHazardDetection(detectedObjectsList);
          _supervisionHazardName = hazardName;
          _supervisionIsHazardActive = _isHazardAlertActive;
          _supervisionDisplayResult = hazardName.isNotEmpty
              ? hazardName.replaceAll('_', ' ')
              : "No direct hazards detected by SuperVision.";
          textToSpeak = hazardName.isNotEmpty
              ? ""
              : "Hazard scan complete. No critical hazards identified by SuperVision.";
        } else if (actualFeatureIdFromSupervision == sceneDetectionFeature.id) {
          final sceneResult = _processSupervisionSceneResult(resultTextRaw);
          _supervisionDisplayResult = sceneResult['display'];
          textToSpeak = sceneResult['speak']
              ? sceneResult['speakText']
              : "Scene analysis complete.";
        } else if (actualFeatureIdFromSupervision == textDetectionFeature.id) {
          final textResult = _processSupervisionTextResult(resultTextRaw);
          _supervisionDisplayResult = textResult['display'];
          textToSpeak = textResult['speak']
              ? textResult['speakText']
              : "Text analysis complete.";
        } else if (actualFeatureIdFromSupervision ==
            currencyDetectionFeature.id) {
          // Updated for currency
          final currencyResult = _processSupervisionCurrencyResult(
              resultTextRaw); // This function expects a string resultTextRaw
          _supervisionDisplayResult = currencyResult['display'];
          textToSpeak = currencyResult['speak']
              ? currencyResult['speakText']
              : "Currency analysis complete.";
        } else if (actualFeatureIdFromSupervision == 'supervision_error') {
          _supervisionDisplayResult = resultTextRaw.isNotEmpty
              ? resultTextRaw
              : "SuperVision analysis failed.";
          textToSpeak = _supervisionDisplayResult;
        } else {
          _supervisionDisplayResult =
              "Unknown result type from SuperVision: $actualFeatureIdFromSupervision. Raw: $resultTextRaw";
          textToSpeak =
              "SuperVision analysis complete with an unknown result type.";
          debugPrint(
              "[HomeScreen] SuperVision unhandled feature ID: $actualFeatureIdFromSupervision, data: $resultTextRaw");
        }

        if (_ttsInitialized && textToSpeak.isNotEmpty) {
          bool hazardWasSpokenByAlert =
              (_supervisionHazardName.isNotEmpty && _isHazardAlertActive);
          if (!hazardWasSpokenByAlert) {
            _ttsService.speak(textToSpeak);
          } else if (textToSpeak != "") {
            String nonHazardPart = textToSpeak;
            if (_supervisionHazardName.isNotEmpty) {
              nonHazardPart = nonHazardPart
                  .replaceAll(
                      RegExp(
                          "Hazard detected: ${_supervisionHazardName.replaceAll('_', ' ')}",
                          caseSensitive: false),
                      "")
                  .trim();
              nonHazardPart = nonHazardPart
                  .replaceAll(
                      RegExp(
                          "Hazard: ${_supervisionHazardName.replaceAll('_', ' ')}",
                          caseSensitive: false),
                      "")
                  .trim();
            }
            if (nonHazardPart.isNotEmpty && nonHazardPart != ".")
              _ttsService.speak(nonHazardPart);
          }
        }
        _isProcessingImage = false;
        _lastRequestedFeatureId = null;
      });
    } else if (data.containsKey('result') &&
        data['result'] is Map<String, dynamic>) {
      final Map<String, dynamic> resultData = data['result'];
      final String status = resultData['status'] ?? 'error';
      final String? receivedForFeatureId = _lastRequestedFeatureId;

      _processFeatureResult(receivedForFeatureId, status, resultData);
      _isProcessingImage = false;
      _lastRequestedFeatureId = null;
    } else {
      debugPrint('[HomeScreen] Received unexpected WS data format: $data');
      if (_isProcessingImage) setState(() => _isProcessingImage = false);
      if (_isSupervisionProcessing)
        setState(() => _isSupervisionProcessing = false);
      _lastRequestedFeatureId = null;
    }
  }

  void _processFeatureResult(
      String? featureId, String status, Map<String, dynamic> resultData) {
    if (!mounted) return;

    if (featureId == objectDetectionFeature.id && status == 'ok') {
      List<Map<String, dynamic>> allDetectionsForHazardCheck =
          (resultData['detections'] as List<dynamic>? ?? [])
              .map((d) => d as Map<String, dynamic>)
              .toList();
      // ignore: unused_local_variable
      List<String> allDetectedNamesForHazardCheck = allDetectionsForHazardCheck
          .map((d) => (d['name'] as String? ?? '').trim())
          .where((name) => name.isNotEmpty)
          .toList();
      //  _processHazardDetection(allDetectedNamesForHazardCheck); // This will trigger alerts if needed
    } else if (featureId == hazardDetectionFeature.id && status == 'ok') {
      List<String> currentDetections = (resultData['detections']
                  as List<dynamic>?)
              ?.map((d) => (d as Map<String, dynamic>)['name'] as String? ?? '')
              .where((name) => name.isNotEmpty)
              .toList() ??
          [];
      _processHazardDetection(currentDetections);
    }

    setState(() {
      if (_isFocusModeActive && featureId == focusModeFeature.id) {
        if (status == 'found') {
          final detection = resultData['detection'] as Map<String, dynamic>?;
          final String detectedName =
              (detection?['name'] as String?)?.toLowerCase() ?? "null";
          final String targetName = _focusedObject?.toLowerCase() ?? "null";
          debugPrint(
              "[Focus] Received detection: '$detectedName'. Target: '$targetName'. Status: '$status'");
          if (detection != null && detectedName == targetName) {
            final double centerX = detection['center_x'] as double? ?? 0.5;
            final double centerY = detection['center_y'] as double? ?? 0.5;
            final double dx = centerX - 0.5;
            final double dy = centerY - 0.5;
            final double dist = sqrt(dx * dx + dy * dy);
            _currentProximity = (1.0 - (dist / 0.707)).clamp(0.0, 1.0);
            debugPrint(
                "[Focus] Target '$targetName' found. Prox: ${_currentProximity.toStringAsFixed(3)}");
            _isFocusObjectDetectedInFrame = true;
            _isFocusObjectCentered = dist < _focusCenterThreshold;

            if (_isFocusObjectCentered && !_announcedFocusFound) {
              if (_ttsInitialized)
                _ttsService.speak("${_focusedObject ?? 'Object'} found!");
              _announcedFocusFound = true;
              Future.delayed(_focusFoundAnnounceCooldown, () {
                if (mounted) _announcedFocusFound = false;
              });
            }
          } else {
            debugPrint(
                "[Focus] Detected '$detectedName' != target '$targetName'. Resetting.");
            _currentProximity = 0.0;
            _isFocusObjectDetectedInFrame = false;
            _isFocusObjectCentered = false;
          }
        } else {
          debugPrint(
              "[Focus] Target '$_focusedObject' not found or error. Status '$status'. Resetting.");
          _currentProximity = 0.0;
          _isFocusObjectDetectedInFrame = false;
          _isFocusObjectCentered = false;
        }
        _updateFocusFeedback();
      } else {
        bool speakResult = false;
        String textToSpeak = "";
        String displayResult = "";

        if (featureId == objectDetectionFeature.id) {
          if (status == 'ok') {
            List<Map<String, dynamic>> allDetectionsFullData =
                (resultData['detections'] as List<dynamic>? ?? [])
                    .map((d) => d as Map<String, dynamic>)
                    .toList();

            if (allDetectionsFullData.isEmpty) {
              displayResult = "No objects detected";
              speakResult = true;
              textToSpeak = displayResult;
            } else {
              // Objects were detected, now filter them by category
              List<Map<String, dynamic>> categoryFilteredDetections =
                  allDetectionsFullData.where((detection) {
                String name =
                    (detection['name'] as String? ?? '').toLowerCase();
                if (_selectedObjectCategory == 'all') return true;
                return cocoObjectToCategoryMap[name] == _selectedObjectCategory;
              }).toList();

              if (categoryFilteredDetections.isNotEmpty) {
                List<String> descriptions = [];
                // The backend already sends detections sorted by confidence and limited by MAX_OBJECTS_TO_RETURN.
                // So, we iterate `categoryFilteredDetections`.
                for (var detection in categoryFilteredDetections) {
                  String name =
                      detection['name'] as String? ?? 'Unknown Object';
                  double centerX =
                      (detection['center_x'] as num?)?.toDouble() ?? 0.5;
                  double centerY =
                      (detection['center_y'] as num?)?.toDouble() ?? 0.5;
                  String location = _getObjectLocation(centerX, centerY);

                  String capitalizedName = name.isNotEmpty
                      ? name[0].toUpperCase() + name.substring(1)
                      : 'Object';
                  descriptions
                      .add("${capitalizedName.replaceAll('_', ' ')} $location");
                }
                displayResult = descriptions.join(', ');
                speakResult = true;
                textToSpeak = displayResult;
              } else {
                // Objects were detected, but none matched the current category filter
                displayResult =
                    "No objects in category: ${objectDetectionCategories[_selectedObjectCategory] ?? _selectedObjectCategory}";
                speakResult = true;
                textToSpeak = displayResult;
              }
            }
          } else if (status == 'none') {
            displayResult = "No objects detected";
            speakResult = true;
            textToSpeak = displayResult;
          } else {
            // Error status
            displayResult = resultData['message'] ?? "Detection Error";
            speakResult = true;
            textToSpeak = displayResult;
          }
          _lastObjectResult = displayResult;
        } else if (featureId == sceneDetectionFeature.id) {
          if (status == 'ok') {
            displayResult = (resultData['scene'] as String? ?? "Unknown Scene")
                .replaceAll('_', ' ');
            speakResult = true;
            textToSpeak = "Scene: $displayResult";
          } else {
            displayResult = resultData['message'] ?? "Scene Error";
          }
          _lastSceneTextResult = displayResult;
        } else if (featureId == textDetectionFeature.id) {
          if (status == 'ok') {
            displayResult = resultData['text'] as String? ?? "No text";
            speakResult = true;
            textToSpeak = "Text detected: $displayResult";
          } else if (status == 'none') {
            displayResult = "No text detected";
          } else {
            displayResult = resultData['message'] ?? "Text Error";
          }
          _lastSceneTextResult = displayResult;
        } else if (featureId == currencyDetectionFeature.id) {
          if (status == 'ok') {
            final String currencyName =
                resultData['currency'] as String? ?? "Unknown Currency";
            // Clean the currency name for both display and TTS
            final String cleanedCurrencyName =
                currencyName.replaceAll('_', ' ');
            displayResult = cleanedCurrencyName;
            speakResult = true;
            textToSpeak = "Currency detected: $cleanedCurrencyName";
          } else if (status == 'none') {
            displayResult = resultData['message'] ?? "No currency detected";
            // Also ensure TTS reflects this accurately if needed
            textToSpeak = displayResult;
            speakResult = true; // Speak "No currency detected"
          } else {
            // Error status
            displayResult = resultData['message'] ?? "Currency Error";
            textToSpeak = displayResult;
            speakResult = true; // Speak the error
          }
          _lastCurrencyResult = displayResult;
        }

        if (speakResult &&
            _ttsInitialized &&
            featureId != hazardDetectionFeature.id) {
          // Hazard speech handled by _triggerHazardAlert
          _ttsService.speak(textToSpeak);
        }
      }
    });
  }

  Map<String, dynamic> _processSupervisionObjectDetectionResult(
      String rawDetections) {
    String displayResult;
    bool speakResult = false;
    String textToSpeak = "";

    if (rawDetections.isNotEmpty &&
        rawDetections != "No objects detected" &&
        !rawDetections.startsWith("Error")) {
      List<String> allDetected =
          rawDetections.split(',').map((e) => e.trim()).toList();
      List<String> filteredObjects = _filterObjectsByCategory(allDetected);

      if (filteredObjects.isNotEmpty) {
        displayResult = filteredObjects.join(', ');
        speakResult = true;
        textToSpeak = displayResult;
      } else {
        displayResult =
            "No objects found in category: ${objectDetectionCategories[_selectedObjectCategory] ?? _selectedObjectCategory}";
        speakResult = false;
      }
    } else {
      displayResult = rawDetections;
      speakResult = false;
    }
    return {
      'display': displayResult,
      'speak': speakResult,
      'speakText': textToSpeak
    };
  }

  Map<String, dynamic> _processSupervisionSceneResult(String resultTextRaw) {
    String displayResult = resultTextRaw.replaceAll('_', ' ');
    bool speakResult =
        displayResult.isNotEmpty && !displayResult.startsWith("Error");
    String textToSpeak = speakResult ? "Scene: $displayResult" : "";
    return {
      'display': displayResult,
      'speak': speakResult,
      'speakText': textToSpeak
    };
  }

  Map<String, dynamic> _processSupervisionTextResult(String resultTextRaw) {
    String displayResult = resultTextRaw;
    bool speakResult = displayResult.isNotEmpty &&
        displayResult != "No text detected" &&
        !displayResult.startsWith("Error");
    String textToSpeak = speakResult ? "Text detected: $displayResult" : "";
    return {
      'display': displayResult,
      'speak': speakResult,
      'speakText': textToSpeak
    };
  }

  List<String> _filterObjectsByCategory(List<String> objectNames) {
    if (_selectedObjectCategory == 'all') return objectNames;
    return objectNames.where((obj) {
      String lowerObj = obj.toLowerCase();
      return cocoObjectToCategoryMap[lowerObj] == _selectedObjectCategory;
    }).toList();
  }

  String _processHazardDetection(List<String> detectedObjectNames) {
    String specificHazardFound = "";
    bool hazardFoundInFrame = false;

    for (String objName in detectedObjectNames) {
      String lowerCaseName = objName.toLowerCase();
      if (_hazardObjectNames.contains(lowerCaseName)) {
        hazardFoundInFrame = true;
        specificHazardFound = lowerCaseName;
        break;
      }
    }

    if (hazardFoundInFrame) {
      _triggerHazardAlert(specificHazardFound);
    }
    return specificHazardFound;
  }

  Map<String, dynamic> _processSupervisionCurrencyResult(String resultTextRaw) {
    // This function expects the raw string result from the backend's SuperVision currency processing
    String displayResult =
        resultTextRaw.replaceAll('_', ' '); // Basic formatting if needed
    bool speakResult = displayResult.isNotEmpty &&
        !displayResult.toLowerCase().startsWith("error") &&
        displayResult.toLowerCase() !=
            "no currency detected by supervision"; // Check for common non-results
    String textToSpeak = speakResult
        ? "Currency detected: $displayResult"
        : (displayResult.toLowerCase().startsWith("error")
            ? displayResult
            : ""); // Speak error or actual result

    // If "No currency detected by SuperVision", don't speak it unless you want to.
    // For this implementation, we will only speak actual detections or errors.
    if (displayResult.toLowerCase() == "no currency detected by supervision") {
      textToSpeak =
          ""; // Don't speak "No currency detected" for supervision, keep it visual
    }

    return {
      'display': displayResult,
      'speak': speakResult,
      'speakText': textToSpeak
    };
  }

  void _handleWebSocketError(error) {
    if (!mounted) return;
    debugPrint('[HomeScreen] WebSocket Error: $error');
    _stopDetectionTimer();
    _stopFocusFeedback();
    _hazardAlertClearTimer?.cancel();
    if (_ttsInitialized) _ttsService.stop();
    setState(() {
      _isProcessingImage = false;
      _lastObjectResult = "Connection Error";
      _lastSceneTextResult = "Connection Error";
      _lastCurrencyResult = "Connection Error"; // Reset currency on error
      _isHazardAlertActive = false;
      _currentDisplayedHazardName = "";
      _isFocusModeActive = false;
      _focusedObject = null;
      _isSupervisionProcessing = false;
      _supervisionResultType = "supervision_error";
      _supervisionDisplayResult = "Connection Error: ${error.toString()}";
      _supervisionHazardName = "";
      _supervisionIsHazardActive = false;
    });
    _showStatusMessage("Connection Error: ${error.toString()}", isError: true);
  }

  void _handleWebSocketDone() {
    if (!mounted) return;
    debugPrint('[HomeScreen] WebSocket connection closed.');
    _stopDetectionTimer();
    _stopFocusFeedback();
    _hazardAlertClearTimer?.cancel();
    if (_ttsInitialized) _ttsService.stop();
    if (mounted) {
      setState(() {
        _isProcessingImage = false;
        _lastObjectResult = "Disconnected";
        _lastSceneTextResult = "Disconnected";
        _lastCurrencyResult = "Disconnected"; // Reset currency on disconnect
        _isHazardAlertActive = false;
        _currentDisplayedHazardName = "";
        _isFocusModeActive = false;
        _focusedObject = null;
        _isSupervisionProcessing = false;
        _supervisionResultType = "supervision_error";
        _supervisionDisplayResult = "Disconnected. Trying to reconnect...";
        _supervisionHazardName = "";
        _supervisionIsHazardActive = false;
      });
      _showStatusMessage('Disconnected. Trying to reconnect...',
          isError: true, durationSeconds: 5);
    }
  }

  // --- Speech Recognition Handling ---
  Future<void> _initSpeech() async {
    try {
      _speechEnabled = await _speechToText.initialize(
          onStatus: _handleSpeechStatus,
          onError: _handleSpeechError,
          debugLogging: kDebugMode);
      debugPrint('Speech recognition initialized: $_speechEnabled');
      if (!_speechEnabled && mounted)
        _showStatusMessage('Speech unavailable', durationSeconds: 3);
    } catch (e) {
      debugPrint('Error initializing speech: $e');
      if (mounted) _showStatusMessage('Speech init failed', durationSeconds: 3);
    }
  }

  void _handleSpeechStatus(String status) {
    if (!mounted) return;
    debugPrint('Speech status: $status');
    final bool isCurrentlyListening = status == SpeechToText.listeningStatus;
    if (_isListening != isCurrentlyListening) {
      setState(() => _isListening = isCurrentlyListening);
    }
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    if (!mounted) return;
    debugPrint(
        'Speech error: ${error.errorMsg} (Permanent: ${error.permanent})');
    if (_isListening) setState(() => _isListening = false);
    if (_isListeningForFocusObject) _isListeningForFocusObject = false;
    String errorMessage = 'Speech error: ${error.errorMsg}';
    if (error.errorMsg.contains('permission') ||
        error.errorMsg.contains('denied')) {
      errorMessage = 'Microphone permission needed.';
      _showPermissionInstructions();
    } else if (error.errorMsg == 'error_no_match') {
      errorMessage = 'Could not recognize speech. Please try again.';
    } else if (error.errorMsg.contains('No speech')) {
      errorMessage = 'No speech detected.';
    } else if (error.errorMsg.contains('timeout')) {
      errorMessage = 'Listening timed out.';
    } else if (error.permanent) {
      errorMessage = 'Speech recognition error. Please restart.';
    }
    _showStatusMessage(errorMessage, isError: true, durationSeconds: 4);
  }

  void _startListening({bool isForFocusObject = false}) async {
    if (!_speechEnabled) {
      _showStatusMessage('Speech not available', isError: true);
      _initSpeech();
      return;
    }
    bool hasPermission = await _speechToText.hasPermission;
    if (!hasPermission && mounted) {
      _showPermissionInstructions();
      _showStatusMessage('Microphone permission needed', isError: true);
      return;
    }
    if (!mounted) return;
    if (_speechToText.isListening) await _stopListening();

    _isListeningForFocusObject = isForFocusObject;
    debugPrint(
        "Starting speech listener... (For Focus Object: $_isListeningForFocusObject)");
    if (_ttsInitialized) _ttsService.stop();

    try {
      await _speechToText.listen(
          onResult: _handleSpeechResult,
          listenFor: Duration(seconds: isForFocusObject ? 10 : 7),
          pauseFor: const Duration(seconds: 3),
          partialResults: false,
          cancelOnError: true,
          listenMode: ListenMode.confirmation);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Error starting speech listener: $e");
      if (mounted) {
        _showStatusMessage("Could not start listening", isError: true);
        setState(() => _isListening = false);
      }
      if (_isListeningForFocusObject) _isListeningForFocusObject = false;
    }
  }

  Future<void> _stopListening() async {
    if (_speechToText.isListening) {
      debugPrint("Stopping speech listener...");
      await _speechToText.stop();
    }
    if (_isListeningForFocusObject) _isListeningForFocusObject = false;
  }

  Future<void> _setSelectedObjectCategory(String categoryKey) async {
    if (!mounted) return;

    if (!objectDetectionCategories.containsKey(categoryKey)) {
      debugPrint("[HomeScreen] Invalid object category key: $categoryKey");
      if (_ttsInitialized) _ttsService.speak("Invalid object category.");
      _showStatusMessage("Invalid object category: $categoryKey",
          isError: true, durationSeconds: 3);
      return;
    }

    if (_selectedObjectCategory == categoryKey) {
      if (_ttsInitialized)
        _ttsService.speak(
            "Object filter is already ${objectDetectionCategories[categoryKey]}.");
      _showStatusMessage(
          "Object filter already ${objectDetectionCategories[categoryKey]}.",
          durationSeconds: 2);
      return;
    }

    setState(() {
      _selectedObjectCategory = categoryKey;
      // If on object detection page, update UI to reflect filter change
      if (_features.isNotEmpty &&
          _currentPage >= 0 &&
          _currentPage < _features.length &&
          _features[_currentPage].id == objectDetectionFeature.id) {
        _lastObjectResult =
            "Filter changed to ${objectDetectionCategories[categoryKey]}.";
      }
    });

    await _settingsService.setObjectDetectionCategory(categoryKey);

    final successMessage =
        "Object filter set to ${objectDetectionCategories[categoryKey]}.";
    if (_ttsInitialized) {
      _ttsService.speak(successMessage);
    }
    debugPrint(
        "[HomeScreen] Object category set to: $categoryKey (${objectDetectionCategories[categoryKey]}) by voice command.");
    _showStatusMessage(successMessage, durationSeconds: 3);
  }

  // Helper to process category voice commands
  // Returns true if command was handled, false otherwise
  Future<bool> _handleObjectCategoryVoiceCommand(String command) async {
    if (!mounted) return false;

    const List<String> prefixes = [
      "set object filter to ",
      "change object filter to ",
      "detect only ",
      "show only ",
      "filter objects to ",
      "object filter ", // e.g., "object filter people"
      "category ", // e.g., "category people"
    ];

    String? matchedPrefix;
    String spokenCategoryName = "";

    for (final prefix in prefixes) {
      if (command.startsWith(prefix)) {
        spokenCategoryName = command.substring(prefix.length).trim();
        matchedPrefix = prefix;
        break;
      }
    }

    if (matchedPrefix != null && spokenCategoryName.isNotEmpty) {
      // Find the category key by matching the spoken name (case-insensitive)
      for (final entry in objectDetectionCategories.entries) {
        final categoryKey = entry.key;
        final categoryDisplayName = entry.value;
        if (categoryDisplayName.toLowerCase() == spokenCategoryName ||
            categoryKey.toLowerCase() == spokenCategoryName) {
          await _setSelectedObjectCategory(categoryKey);
          return true; // Command handled
        }
      }
      // Special handling for "all" if display name isn't exactly "all"
      if (spokenCategoryName == "all" &&
          objectDetectionCategories.containsKey('all')) {
        await _setSelectedObjectCategory('all');
        return true; // Command handled
      }
      // If a prefix was matched, but the category name part was not recognized
      if (_ttsInitialized)
        _ttsService.speak("Category '$spokenCategoryName' not recognized.");
      _showStatusMessage("Category '$spokenCategoryName' not recognized.",
          isError: true);
      return true; // Consumed the command prefix, even if category was wrong
    }
    return false; // Command not related to object category filtering
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    if (mounted && result.finalResult && result.recognizedWords.isNotEmpty) {
      String command = result.recognizedWords.toLowerCase().trim();
      debugPrint(
          'Final recognized speech: "$command" (Was for focus: $_isListeningForFocusObject)');

      if (_isFocusModeActive && _isListeningForFocusObject) {
        debugPrint("[Focus] Setting focused object to: '$command'");
        setState(() {
          _focusedObject = command;
          _isFocusPromptActive = false;
          _isFocusObjectDetectedInFrame = false;
          _isFocusObjectCentered = false;
          _currentProximity = 0.0;
          _announcedFocusFound = false;
        });
        _stopFocusFeedback();
        if (_ttsInitialized)
          _ttsService.speak("Finding ${_focusedObject ?? 'object'}");
        debugPrint("[Focus] Object set. Triggering camera initialization...");
        _initializeMainCameraController(); // Initialize camera for focus mode
      } else {
        debugPrint("[Speech] Processing general command: '$command'");
        _processGeneralSpeechCommand(command);
      }
      if (_isListeningForFocusObject) _isListeningForFocusObject = false;
    }
  }

  void _processGeneralSpeechCommand(String command) async {
    // Made async
    if (!mounted) return;
    if (command == 'settings' || command == 'setting') {
      _navigateToSettingsPage();
      return;
    }

    // Attempt to handle object category command first
    if (await _handleObjectCategoryVoiceCommand(command)) {
      // Added await
      return; // Command was handled (either successfully or category name was invalid but prefix matched)
    }

    // If not a category command, try to navigate to a feature page
    int targetPageIndex = -1;
    for (int i = 0; i < _features.length; i++) {
      if (i >= _features.length) break; // Should not happen, but defensive
      for (String keyword in _features[i].voiceCommandKeywords) {
        if (command.contains(keyword)) {
          targetPageIndex = i;
          break;
        }
      }
      if (targetPageIndex != -1) break;
    }

    if (targetPageIndex != -1) {
      _navigateToPage(targetPageIndex);
    } else {
      // Only show "command not recognized" if it wasn't handled by category or page navigation
      _showStatusMessage('Command "$command" not recognized.',
          durationSeconds: 3);
      if (_ttsInitialized) _ttsService.speak('Command not recognized.');
    }
  }

  // --- Detection Logic ---
  void _startDetectionTimerIfNeeded() {
    if (!mounted || _features.isEmpty) return;
    final currentFeatureId =
        _features[_currentPage.clamp(0, _features.length - 1)].id;

    bool isNormalRealtime = (currentFeatureId == objectDetectionFeature.id ||
        currentFeatureId == hazardDetectionFeature.id);
    bool isFocusModeRunning = _isFocusModeActive &&
        _focusedObject != null &&
        currentFeatureId == focusModeFeature.id;

    if ((isNormalRealtime || isFocusModeRunning) &&
        _detectionTimer == null &&
        _cameraController != null &&
        (_cameraController?.value.isInitialized ?? false) &&
        !_isMainCameraInitializing &&
        _webSocketService.isConnected) {
      debugPrint(
          "[HomeScreen] Starting detection timer. Mode: ${isFocusModeRunning ? 'Focus' : 'Normal Realtime'}");
      _detectionTimer = Timer.periodic(_detectionInterval, (_) {
        _performPeriodicDetection();
      });
    } else {
      bool shouldStopTimer = false;
      if (_detectionTimer != null) {
        if (_isFocusModeActive &&
            _focusedObject == null &&
            currentFeatureId == focusModeFeature.id)
          shouldStopTimer = true;
        else if (!isNormalRealtime && !isFocusModeRunning)
          shouldStopTimer = true;
      }
      if (shouldStopTimer) _stopDetectionTimer();
    }
  }

  void _stopDetectionTimer() {
    if (_detectionTimer?.isActive ?? false) {
      debugPrint("[HomeScreen] Stopping detection timer...");
      _detectionTimer!.cancel();
      _detectionTimer = null;
      if (mounted && _isProcessingImage)
        setState(() => _isProcessingImage = false);
    }
  }

  void _performPeriodicDetection() async {
    final currentController = _cameraController;
    if (!mounted ||
        currentController == null ||
        !currentController.value.isInitialized ||
        currentController.value.isTakingPicture ||
        _isMainCameraInitializing ||
        _isProcessingImage ||
        !_webSocketService.isConnected ||
        _features.isEmpty) {
      return;
    }

    final currentFeatureId =
        _features[_currentPage.clamp(0, _features.length - 1)].id;
    bool isFocusDetection = _isFocusModeActive &&
        _focusedObject != null &&
        currentFeatureId == focusModeFeature.id;
    bool isNormalObjectDetection =
        currentFeatureId == objectDetectionFeature.id;
    bool isHazardDetectionOnPage =
        currentFeatureId == hazardDetectionFeature.id;

    String detectionTypeToSend;
    String? focusObjectToSend;
    String? featureRequesting;

    if (isFocusDetection) {
      detectionTypeToSend = 'focus_detection'; // Backend expects this for focus
      focusObjectToSend = _focusedObject;
      featureRequesting = focusModeFeature.id;
    } else if (isNormalObjectDetection || isHazardDetectionOnPage) {
      detectionTypeToSend =
          objectDetectionFeature.id; // Send as 'object_detection' for both
      featureRequesting = currentFeatureId;
    } else {
      _stopDetectionTimer();
      return;
    }

    if (!_cameraControllerCheck(showError: false)) return;

    try {
      if (!mounted ||
          _cameraController != currentController ||
          !_cameraController!.value.isInitialized) {
        if (mounted && _isProcessingImage)
          setState(() => _isProcessingImage = false);
        return;
      }
      if (mounted)
        setState(() => _isProcessingImage = true);
      else
        return;
      _lastRequestedFeatureId = featureRequesting;
      debugPrint(
          "[Detection] Taking picture for feature: $featureRequesting (Focus Object: $focusObjectToSend)");

      final XFile imageFile = await currentController.takePicture();
      _webSocketService.sendImageForProcessing(
          imageFile: imageFile,
          processingType: detectionTypeToSend,
          focusObject: focusObjectToSend);
    } catch (e, stackTrace) {
      if (e is CameraException && e.code == 'disposed') {
        debugPrint(
            "[Detection] Error: Used disposed CameraController. Ignoring.");
      } else {
        _handleCaptureError(e, stackTrace, featureRequesting);
      }
      _lastRequestedFeatureId = null;
      if (mounted) setState(() => _isProcessingImage = false);
    }
  }

  // For Scene, Text, and SuperVision
  void _performManualDetection(String featureId) async {
    if (featureId ==
            barcodeScannerFeature.id || // Barcode handles its own camera
        featureId == objectDetectionFeature.id || // Realtime
        featureId == hazardDetectionFeature.id || // Realtime
        featureId == focusModeFeature.id) {
      // Realtime after object select
      return;
    }
    debugPrint('Manual detection triggered for feature: $featureId');

    if (!_cameraControllerCheck(showError: true)) {
      debugPrint(
          'Manual detection aborted: Camera check failed for $featureId.');
      return;
    }
    if ((_isProcessingImage && featureId != supervisionFeature.id) ||
        (_isSupervisionProcessing && featureId == supervisionFeature.id) ||
        !_webSocketService.isConnected) {
      debugPrint(
          'Manual detection aborted for $featureId: Already processing or WS disconnected.');
      _showStatusMessage("Processing or disconnected",
          isError: true, durationSeconds: 2);
      return;
    }

    try {
      if (featureId == supervisionFeature.id) {
        if (mounted) setState(() => _isSupervisionProcessing = true);
      } else {
        if (mounted) setState(() => _isProcessingImage = true);
      }
      _lastRequestedFeatureId = featureId;
      if (_ttsInitialized) _ttsService.stop();
      _showStatusMessage("Capturing...", durationSeconds: 1);
      final XFile imageFile = await _cameraController!.takePicture();
      _showStatusMessage("Processing...", durationSeconds: 2);

      if (featureId == supervisionFeature.id) {
        _webSocketService.sendImageForProcessing(
            imageFile: imageFile,
            processingType: supervisionFeature.id, // 'supervision'
            supervisionRequestType:
                'llm_route' // Specific for SuperVision LLM routing
            );
      } else {
        // Scene, Text, or Currency
        _webSocketService.sendImageForProcessing(
            imageFile: imageFile,
            processingType:
                featureId, // 'scene_detection', 'text_detection', or 'currency_detection'
            languageCode: (featureId == textDetectionFeature.id)
                ? _selectedOcrLanguage
                : null);
      }
    } catch (e, stackTrace) {
      _handleCaptureError(e, stackTrace, featureId);
      _lastRequestedFeatureId = null;
      if (mounted) {
        if (featureId == supervisionFeature.id)
          setState(() => _isSupervisionProcessing = false);
        else
          setState(() => _isProcessingImage = false);
      }
    }
    // _isProcessingImage / _isSupervisionProcessing reset in _handleWebSocketData
  }

  bool _cameraControllerCheck({required bool showError}) {
    final currentFeatureId = _features.isNotEmpty
        ? _features[_currentPage.clamp(0, _features.length - 1)].id
        : null;
    if (currentFeatureId == barcodeScannerFeature.id) return false;

    bool isReady = _cameraController != null &&
        _cameraController!.value.isInitialized &&
        !_isMainCameraInitializing;
    if (!isReady) {
      if (!_isMainCameraInitializing && showError)
        _showStatusMessage("Camera not ready", isError: true);
      if (_cameraController == null &&
          widget.camera != null &&
          !_isMainCameraInitializing &&
          showError) {
        _initializeMainCameraController();
      }
      return false;
    }
    if (_cameraController!.value.isTakingPicture) return false;
    return true;
  }

  void _handleCaptureError(Object e, StackTrace stackTrace, String? featureId) {
    final idForLog = featureId ?? "unknown_feature";
    debugPrint('Capture/Send Error for $idForLog: $e');
    debugPrintStack(stackTrace: stackTrace);
    String errorMsg = e is CameraException
        ? "Capture Error: ${e.description ?? e.code}"
        : "Processing Error";
    if (mounted) {
      if (_ttsInitialized) _ttsService.stop();
      setState(() {
        if (featureId == currencyDetectionFeature.id)
          _lastCurrencyResult = "Error";
        else if (featureId == objectDetectionFeature.id)
          _lastObjectResult = "Error";
        else if (featureId == hazardDetectionFeature.id) {
          _clearHazardAlert();
        } else if (featureId == focusModeFeature.id) {
          _stopFocusFeedback();
          _focusedObject = null;
          _isFocusModeActive = false;
        } else if (featureId == supervisionFeature.id) {
          _isSupervisionProcessing = false;
          _supervisionResultType = "supervision_error";
          _supervisionDisplayResult = errorMsg;
          _supervisionHazardName = "";
          _supervisionIsHazardActive = false;
        } else if (featureId != null && featureId != barcodeScannerFeature.id)
          _lastSceneTextResult = "Error";
        _isProcessingImage = false; // General flag
      });
      _showStatusMessage(errorMsg, isError: true, durationSeconds: 4);
    }
  }

  // --- Alerting (Hazard & Focus) ---
  void _triggerHazardAlert(String hazardName) {
    debugPrint("[ALERT] Hazard Triggering for: $hazardName");
    bool wasAlreadyActive = _isHazardAlertActive;
    if (mounted) {
      setState(() {
        _isHazardAlertActive = true;
        _currentDisplayedHazardName = hazardName;
        // Also update supervision hazard state if a hazard is globally triggered
        _supervisionHazardName = hazardName;
        _supervisionIsHazardActive = true;
      });
    }
    _playAlertSound();
    _triggerVibration(isHazard: true);
    if (!wasAlreadyActive && _ttsInitialized)
      _ttsService.speak("Hazard detected: ${hazardName.replaceAll('_', ' ')}");
    _hazardAlertClearTimer?.cancel();
    _hazardAlertClearTimer = Timer(_hazardAlertPersistence, _clearHazardAlert);
  }

  void _clearHazardAlert() {
    if (mounted && _isHazardAlertActive) {
      setState(() {
        _isHazardAlertActive = false;
        _currentDisplayedHazardName = "";
        // If clearing global hazard, SuperVision page might still show it if its own detection found one.
        // Or, we could clear _supervisionIsHazardActive too, depending on desired behavior.
        // For now, let's assume SuperVision's own state manages its hazard display based on its *last* analysis.
        // Global clear just clears the dedicated hazard page's active alert.
      });
      debugPrint("[ALERT] Hazard alert cleared.");
    }
    _hazardAlertClearTimer = null;
  }

  Future<void> _playAlertSound() async {
    try {
      await _alertAudioPlayer.play(AssetSource(_alertSoundPath), volume: 1.0);
      debugPrint("[ALERT] Playing hazard sound.");
    } catch (e) {
      debugPrint("[ALERT] Error playing hazard sound: $e");
    }
  }

  void _updateFocusFeedback() {
    if (!mounted || !_isFocusModeActive) {
      _stopFocusFeedback();
      return;
    }
    _focusBeepTimer?.cancel();
    if (_currentProximity > 0.05) {
      final double proximityFactor = _currentProximity * _currentProximity;
      int interval = (_focusBeepMaxIntervalMs -
              (proximityFactor *
                  (_focusBeepMaxIntervalMs - _focusBeepMinIntervalMs)))
          .toInt();
      interval =
          interval.clamp(_focusBeepMinIntervalMs, _focusBeepMaxIntervalMs);
      debugPrint(
          "[Focus Feedback] Prox: ${_currentProximity.toStringAsFixed(2)}, Interval: $interval ms");
      _focusBeepTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
        if (!mounted || !_isFocusModeActive) {
          _focusBeepTimer?.cancel();
          return;
        }
        _playBeepSound();
        _triggerVibration(proximity: _currentProximity);
      });
    } else {
      debugPrint(
          "[Focus Feedback] Prox (${_currentProximity.toStringAsFixed(2)}) low. Stopping.");
    }
  }

  void _stopFocusFeedback() {
    _focusBeepTimer?.cancel();
    _focusBeepTimer = null;
  }

  Future<void> _playBeepSound() async {
    debugPrint("[Focus Feedback] Playing beep sound...");
    try {
      await _beepPlayer.play(AssetSource(_beepSoundPath),
          mode: PlayerMode.lowLatency, volume: 0.8);
    } catch (e) {
      debugPrint("[Focus Feedback] Error playing beep sound: $e");
    }
  }

  Future<void> _triggerVibration(
      {bool isHazard = false, double proximity = 0.0}) async {
    if (!_hasVibrator) return;
    try {
      if (isHazard) {
        Vibration.vibrate(duration: 500, amplitude: 255);
        debugPrint("[ALERT] Hazard vibration.");
      } else if (_isFocusModeActive && proximity > 0.05) {
        if (_hasAmplitudeControl ?? false) {
          int amplitude = (1 + (proximity * 254)).toInt().clamp(1, 255);
          Vibration.vibrate(duration: 80, amplitude: amplitude);
        } else {
          Vibration.vibrate(duration: 80);
        }
      }
    } catch (e) {
      debugPrint("[Vibration] Error: $e");
    }
  }

  // --- Navigation & UI Helpers ---
  void _showStatusMessage(String message,
      {bool isError = false, int durationSeconds = 3}) {
    if (!mounted) return;
    debugPrint("[Status] $message ${isError ? '(Error)' : ''}");
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : Colors.grey[800],
        duration: Duration(seconds: durationSeconds),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 90.0, left: 15.0, right: 15.0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10.0),
        ),
      ),
    );
  }

  void _navigateToPage(int pageIndex) {
    if (!mounted || _features.isEmpty) return;
    final targetIndex = pageIndex.clamp(0, _features.length - 1);

    // --- ADD CHECK: Only navigate if target is different from current page ---
    if (targetIndex == _currentPage) {
      debugPrint(
          "Attempted to navigate to the same page ($targetIndex). Skipping.");
      return;
    }
    // --- END CHECK ---

    if (_pageController.hasClients) {
      if (_ttsInitialized) _ttsService.stop();
      debugPrint(
          "Navigating from $_currentPage to page index: $targetIndex (${_features[targetIndex].title})");
      _pageController.animateToPage(
        targetIndex,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
      // IMPORTANT: Do NOT update _currentPage here. Let _onPageChanged handle it
      // when the animation completes or settles.
    }
  }

  // In _navigateToSettingsPage()
  Future<void> _navigateToSettingsPage() async {
    if (!mounted) return;
    debugPrint("Navigating to Settings...");
    if (_speechToText.isListening) await _stopListening();
    if (_ttsInitialized) _ttsService.stop();
    _stopDetectionTimer();
    _stopFocusFeedback();
    final currentFeatureId = _features.isNotEmpty
        ? _features[_currentPage.clamp(0, _features.length - 1)].id
        : null;
    bool isMainCameraPage = currentFeatureId != barcodeScannerFeature.id;
    if (isMainCameraPage) await _disposeMainCameraController();

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsScreen()),
    );

    if (!mounted) return;
    debugPrint("Returned from Settings.");

    // Reload OCR language and TTS V,P,R settings
    await _loadAndInitializeSettings();

    // --- NEW: Adjust TTS language based on current page and new settings ---
    if (_features[_currentPage].id == textDetectionFeature.id) {
      final String ocrLang = _selectedOcrLanguage;
      String? targetTtsLang = ocrToTtsLanguageMap[ocrLang];
      debugPrint(
          "[TTS Lang] Settings Return (On Text Rec): OCR lang '$ocrLang', mapped TTS lang '$targetTtsLang'. Global: '$_globalTtsLanguageSetting'");
      await _ttsService
          .setSpeechLanguage(targetTtsLang ?? _globalTtsLanguageSetting);
    } else {
      // If not on text rec page, ensure TTS is set to global default
      debugPrint(
          "[TTS Lang] Settings Return (Not On Text Rec). Ensuring TTS is global: '$_globalTtsLanguageSetting'");
      await _ttsService.setSpeechLanguage(_globalTtsLanguageSetting);
    }
    // --- END NEW ---

    bool isFocusModeWaitingForObject =
        _isFocusModeActive && _focusedObject == null;
    if (isMainCameraPage && !isFocusModeWaitingForObject) {
      await _initializeMainCameraController();
    }
    _startDetectionTimerIfNeeded();
  }

  void _showPermissionInstructions() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Microphone Permission'),
        content: const Text(
          'Voice control requires microphone access.\nPlease enable the Microphone permission in Settings.',
        ),
        actions: <Widget>[
          TextButton(
            child: const Text('OK'),
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(15.0)),
      ),
    );
  }

  void _navigateToPreviousPage() {
    // Check if we are not on the first page
    if (_currentPage >= 0) {
      _navigateToPage(_currentPage - 1);
    }
  }

  void _navigateToNextPage() {
    // Check if we are not on the last page
    if (_currentPage <= _features.length - 1) {
      if (_currentPage + 1 == BarcodeScannerPage) {
        _navigateToPage(_currentPage);
        return;
      }
      _navigateToPage(_currentPage + 1);
    }
  }

  // --- Page Change Handler ---
  void _onPageChanged(int index) async {
    if (!mounted) return;
    final newPageIndex = index.clamp(0, _features.length - 1);
    // Ensure newPageIndex is valid (already clamped, but good for clarity if features list could be empty during an edge case)
    if (newPageIndex >= _features.length) {
      debugPrint(
          "[Navigation Error] newPageIndex $newPageIndex is out of bounds for features list length ${_features.length}.");
      return;
    }

    final int previousPageIndex = _currentPage;

    // Prevent redundant calls if the index hasn't actually changed
    if (previousPageIndex == newPageIndex) {
      debugPrint(
          "[Navigation] Attempted to navigate to the same page ($newPageIndex). Skipping _onPageChanged logic.");
      return;
    }

    // Validate previousPageIndex before using it to access _features list
    if (previousPageIndex < 0 || previousPageIndex >= _features.length) {
      debugPrint(
          "[Navigation Error] Invalid previousPageIndex: $previousPageIndex. Current new is $newPageIndex.");
      // Attempt to recover by setting current page and letting UI rebuild.
      // Avoids crashing on _features[previousPageIndex]
      _currentPage = newPageIndex;
      if (mounted) setState(() {});
      // It might be better to speak the new feature title here if recovery is simple.
      // For now, just recover state and return.
      return;
    }

    if (_isTutorialActive) {
      debugPrint(
          "[Tutorial] Page changed during active tutorial. Ending tutorial.");
      await _ttsService.stop();
      _isTutorialSpeaking = false;
      _endTutorial();
    }

    final previousFeature = _features[previousPageIndex];
    final newFeature = _features[newPageIndex];
    debugPrint(
        "[Navigation] Page changed from ${previousFeature.id} (idx $previousPageIndex) to ${newFeature.id} (idx $newPageIndex)");

    // Stop ongoing activities FIRST
    if (_ttsInitialized) _ttsService.stop();
    _stopDetectionTimer();
    _stopFocusFeedback();
    if (previousFeature.id == hazardDetectionFeature.id) _clearHazardAlert();

    // --- TTS Language Management on Page Change ---
    if (_ttsInitialized) {
      // Ensure TTS service is ready
      if (newFeature.id == textDetectionFeature.id) {
        final String ocrLang = _selectedOcrLanguage;
        String? targetTtsLang = ocrToTtsLanguageMap[ocrLang];
        debugPrint(
            "[TTS Lang] Navigating TO Text Rec Page: OCR lang '$ocrLang', mapped TTS lang '$targetTtsLang'. Global TTS: '$_globalTtsLanguageSetting'");
        await _ttsService
            .setSpeechLanguage(targetTtsLang ?? _globalTtsLanguageSetting);
      }
      // When navigating FROM Text Recognition page to a DIFFERENT page
      else if (previousFeature.id == textDetectionFeature.id &&
          newFeature.id != textDetectionFeature.id) {
        debugPrint(
            "[TTS Lang] Navigating FROM Text Rec Page. Reverting TTS to global: '$_globalTtsLanguageSetting'");
        await _ttsService.setSpeechLanguage(_globalTtsLanguageSetting);
      }
      // If navigating between non-text pages, or from a non-text page to another non-text page,
      // ensure the global TTS language is active. This also handles the first page load if it's not Text Rec.
      else if (newFeature.id != textDetectionFeature.id) {
        debugPrint(
            "[TTS Lang] Navigating to/between NON-Text Rec pages. Ensuring global TTS: '$_globalTtsLanguageSetting'");
        await _ttsService.setSpeechLanguage(_globalTtsLanguageSetting);
      }
    }
    // --- END TTS Language Management ---

    bool wasFocusMode = _isFocusModeActive;
    _isFocusModeActive = newFeature.id == focusModeFeature.id;

    _currentPage = newPageIndex; // Update current page state
    if (mounted)
      setState(() {});
    else
      return; // Rebuild UI with new page context

    // --- Camera Transitions ---
    bool isSwitchingToBarcode = newFeature.id == barcodeScannerFeature.id;
    bool isSwitchingToFocusInitial = _isFocusModeActive &&
        _focusedObject == null &&
        newFeature.id == focusModeFeature.id;
    bool isSwitchingFromBarcode =
        previousFeature.id == barcodeScannerFeature.id;
    bool isSwitchingFromFocus = wasFocusMode && !_isFocusModeActive;

    debugPrint(
        "[Nav] CamLogic: ToBarcode=$isSwitchingToBarcode, ToFocusInitial=$isSwitchingToFocusInitial, FromBarcode=$isSwitchingFromBarcode, FromFocus=$isSwitchingFromFocus");

    if (isSwitchingToFocusInitial) {
      if (_cameraController != null || _isMainCameraInitializing) {
        debugPrint(
            "[Nav] Switching TO initial focus - Speaking TTS then disposing main camera...");
        // TTS for focus prompt uses current language (which would be global or OCR lang if coming from TextRec)
        if (_ttsInitialized)
          await _ttsService.speak(
              "Metal Detector. Tap the button, then say the object name.");
        await _disposeMainCameraController();
        debugPrint("[Nav] Main camera disposed after TTS for focus.");
      } else {
        if (_ttsInitialized)
          await _ttsService.speak(
              "Metal Detector. Tap the button, then say the object name.");
      }
    } else if (isSwitchingToBarcode) {
      if (_cameraController != null || _isMainCameraInitializing) {
        debugPrint(
            "[Nav] Switching TO barcode - disposing main camera (async)...");
        _disposeMainCameraController(); // Dispose without awaiting
      }
    } else if (isSwitchingFromBarcode || isSwitchingFromFocus) {
      bool newPageNeedsCamera = newFeature.id != barcodeScannerFeature.id &&
          !isSwitchingToFocusInitial;
      if (newPageNeedsCamera) {
        debugPrint(
            "[Nav] Switching FROM barcode/focus TO page needing camera (${newFeature.id}) - Ensuring camera init...");
        await Future.delayed(
            const Duration(milliseconds: 200)); // Short delay before re-init
        _initializeMainCameraController();
        // _initializeMainCameraController(); // Second call if you find it necessary
        if (mounted) setState(() {});
        debugPrint(
            "[Nav] Camera initialization for ${newFeature.id} complete/triggered.");
      }
    } else {
      // Transitions between other pages that might need camera
      bool newPageNeedsCamera = newFeature.id != barcodeScannerFeature.id &&
          !isSwitchingToFocusInitial;
      // If new page needs camera AND (it's null OR not initialized) AND not currently initializing
      if (newPageNeedsCamera &&
          (_cameraController == null ||
              !_cameraController!.value.isInitialized) &&
          !_isMainCameraInitializing) {
        debugPrint(
            "[Nav] Other transition: Page ${newFeature.id} needs camera, ensuring it's initialized.");
        _initializeMainCameraController();
        _initializeMainCameraController(); // Second call if needed
        if (mounted) setState(() {});
      }
    }
    // --- End Camera Transitions ---

    // --- Clear Previous Page Results & Reset State ---
    if (mounted) {
      setState(() {
        _isProcessingImage = false;
        _lastRequestedFeatureId = null;
        if (previousFeature.id == objectDetectionFeature.id)
          _lastObjectResult = "";
        else if (previousFeature.id == sceneDetectionFeature.id ||
            previousFeature.id == textDetectionFeature.id)
          _lastSceneTextResult = "";
        else if (previousFeature.id == currencyDetectionFeature.id)
          _lastCurrencyResult = "";

        if (previousFeature.id == supervisionFeature.id) {
          _isSupervisionProcessing = false;
          _supervisionResultType = null;
          _supervisionDisplayResult = "";
          _supervisionHazardName = "";
          _supervisionIsHazardActive = false;
        }
        if (isSwitchingFromFocus) {
          // Only reset focus state if truly leaving focus mode
          debugPrint(
              "[Nav] Resetting Focus state variables as we are leaving Focus Mode.");
          _focusedObject = null;
          _isFocusPromptActive = false;
          _isFocusObjectDetectedInFrame = false;
          _isFocusObjectCentered = false;
          _currentProximity = 0.0;
          _announcedFocusFound = false;
        }
      });
    } else {
      return; // Widget unmounted, abort
    }
    // --- End Clear State ---

    // --- Final Page Setup ---
    // Announce New Feature Title (if not focus initial, as that already announced)
    // This will use the TTS language set just above (OCR lang for TextRec, global for others).
    if (_ttsInitialized && !isSwitchingToFocusInitial) {
      _ttsService.speak(newFeature.title);
    }

    // Setup Focus Prompt (if entering focus initial state)
    if (isSwitchingToFocusInitial) {
      if (mounted) {
        setState(() {
          _isFocusPromptActive = true;
          _isFocusObjectDetectedInFrame = false;
          _isFocusObjectCentered = false;
          _currentProximity = 0.0;
          _announcedFocusFound = false;
        });
      }
      _stopFocusFeedback(); // Ensure feedback is off initially
      debugPrint(
          "[Focus] Entered Focus Mode Initial State (Object prompt active).");
    } else {
      // Applies to ObjectDetection, HazardDetection, FocusMode (once object selected)
      _startDetectionTimerIfNeeded();
    }
    // --- End Final Page Setup ---
  }

// --- Widget Build Logic ---
  @override
  Widget build(BuildContext context) {
    if (_features.isEmpty)
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(
              child:
                  Text("No features.", style: TextStyle(color: Colors.white))));

    final currentFeature =
        _features[_currentPage.clamp(0, _features.length - 1)];
    final bool isBarcodePage = currentFeature.id == barcodeScannerFeature.id;
    final bool isFocusModeWaiting =
        _isFocusModeActive && _focusedObject == null;
    final bool shouldShowMainCamera = !isBarcodePage && !isFocusModeWaiting;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (shouldShowMainCamera)
            _buildCameraDisplay()
          else
            Container(
                key: ValueKey('placeholder_${currentFeature.id}'),
                color: Colors.black),
          _buildFeaturePageView(),
          FeatureTitleBanner(
              title: currentFeature.title,
              backgroundColor: currentFeature.color),
          _buildTutorialButton(),
          if (_currentPage >= 0 && !_isTutorialActive)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8.0),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: Colors.white, size: 48.0),
                  onPressed: _navigateToPreviousPage,
                  tooltip: 'Previous Feature',
                  style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withOpacity(0.35),
                      padding: const EdgeInsets.all(10.0),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(50))),
                ),
              ),
            ),
          if (_currentPage <= _features.length - 1 && !_isTutorialActive)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: IconButton(
                  icon: const Icon(Icons.arrow_forward_ios_rounded,
                      color: Colors.white, size: 48.0),
                  onPressed: _navigateToNextPage,
                  tooltip: 'Next Feature',
                  style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withOpacity(0.35),
                      padding: const EdgeInsets.all(10.0),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(50))),
                ),
              ),
            ),
          if (!_isTutorialActive) _buildSettingsButton(),
          if (!_isTutorialActive) _buildMainActionButton(currentFeature),
          if (_isTutorialActive) _buildTutorialOverlay(),
        ],
      ),
    );
  }

  Widget _buildTutorialButton() {
    return Align(
      alignment: Alignment.topLeft,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 10.0, left: 15.0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withAlpha((0.3 * 255).round()),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(Icons.question_mark_rounded,
                  color: Colors.white,
                  size: 30.0,
                  shadows: [
                    Shadow(
                        blurRadius: 6.0,
                        color: Colors.black54,
                        offset: Offset(1.0, 1.0))
                  ]),
              tooltip: 'Tap for feature help, Long-press for full tutorial',
              onPressed: () {
                debugPrint("[Tutorial Button] Short-press detected!");
                if (_isTutorialActive && _isTutorialSpeaking) {
                  _ttsService.stop();
                  _isTutorialSpeaking = false;
                  // _endTutorial(); // Consider if ending is always right here
                } else {
                  _startCurrentFeatureTutorial();
                }
              },
              onLongPress: () {
                debugPrint(
                    "[Tutorial Button] Long-press detected! Calling _startFullTutorial...");
                _startFullTutorial(); // Not autoStart, user initiated
              },
            ),
          ),
        ),
      ),
    );
  }

// In // --- Widget Build Logic --- section

  Widget _buildTutorialOverlay() {
    final List<TutorialStepData> currentDataSource =
        _currentFeatureHelpSteps.isNotEmpty
            ? _currentFeatureHelpSteps
            : _tutorialStepsData;

    if (!_isTutorialActive ||
        currentDataSource.isEmpty ||
        _currentTutorialStep >= currentDataSource.length) {
      if (_isTutorialActive && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _isTutorialActive) _endTutorial();
        });
      }
      return const SizedBox.shrink();
    }
    final stepData = currentDataSource[_currentTutorialStep];

    Widget mediaWidget = const SizedBox.shrink();
    if (stepData.mediaAssetPath != null) {
      if (stepData.mediaType == MediaType.image ||
          stepData.mediaType == MediaType.gif) {
        mediaWidget = Image.asset(
          stepData.mediaAssetPath!,
          height:
              stepData.mediaHeight, // Uses provided height or null (intrinsic)
          fit: stepData.mediaFit,
          errorBuilder: (context, error, stackTrace) {
            debugPrint(
                "[Tutorial] Error loading image/gif asset: ${stepData.mediaAssetPath} - $error");
            return Icon(Icons.broken_image, color: Colors.grey[700], size: 50);
          },
        );
      } else if (stepData.mediaType == MediaType.video) {
        mediaWidget = (_initializeVideoPlayerFuture != null &&
                _tutorialVideoController != null)
            ? FutureBuilder(
                future: _initializeVideoPlayerFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done &&
                      _tutorialVideoController!.value.isInitialized) {
                    return SizedBox(
                      height: stepData.mediaHeight ??
                          250, // Default height for video if not specified
                      child: AspectRatio(
                        aspectRatio:
                            _tutorialVideoController!.value.aspectRatio,
                        child: VideoPlayer(_tutorialVideoController!),
                      ),
                    );
                  } else if (snapshot.hasError) {
                    debugPrint(
                        "[Tutorial] Video snapshot error: ${snapshot.error}");
                    return Center(
                        child: Text("Error loading video",
                            style: TextStyle(color: Colors.red[300])));
                  }
                  return SizedBox(
                      height: stepData.mediaHeight ?? 250,
                      child: Center(
                          child: _isVideoBuffering
                              ? const CircularProgressIndicator(
                                  color: Colors.white)
                              : Icon(Icons.play_circle_fill,
                                  color: Colors.grey[700], size: 50)));
                },
              )
            : SizedBox(
                height: stepData.mediaHeight ?? 250,
                child: Center(
                    child: Icon(Icons.videocam_off,
                        color: Colors.grey[700],
                        size: 50))); // Placeholder if controller not ready
      }
    }

    return Positioned.fill(
      child: GestureDetector(
        onTap: () {
          // Allow skip if full tutorial is playing, or if it's feature help.
          // Also, if a video is playing and doesn't auto-advance, tap should skip.
          bool isVideoPlayingNoAutoAdvance =
              stepData.mediaType == MediaType.video &&
                  _tutorialVideoController != null &&
                  _tutorialVideoController!.value.isPlaying &&
                  !stepData.autoAdvanceAfterMediaEnds;

          if ((_isTutorialActive &&
                  _isTutorialSpeaking &&
                  currentDataSource.length > 1) ||
              (_isTutorialActive &&
                  !_isTutorialSpeaking &&
                  isVideoPlayingNoAutoAdvance)) {
            // Allow skip if video is playing and user taps
            _handleTutorialSkip();
          } else if (_isTutorialActive &&
              _currentFeatureHelpSteps.isNotEmpty &&
              currentDataSource.length == 1) {
            // If it's single-step feature help, tapping dismisses it.
            _endTutorial();
          }
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: Colors.black.withOpacity(0.9),
          padding: const EdgeInsets.symmetric(horizontal: 20.0).copyWith(
            top: MediaQuery.of(context).padding.top +
                20, // Account for status bar
            bottom: MediaQuery.of(context).padding.bottom +
                20, // Account for nav bar
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (stepData.mediaAssetPath != null) ...[
                mediaWidget,
                const SizedBox(height: 20),
              ],
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    stepData.text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20, // Slightly smaller for more text
                      fontWeight: FontWeight.w500, // Adjusted weight
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              if (stepData.mediaType == MediaType.video &&
                  _tutorialVideoController != null &&
                  _tutorialVideoController!.value.isInitialized)
                const SizedBox(
                    height:
                        10), // spacer for video controls if they were visible
              Padding(
                padding: const EdgeInsets.only(top: 15.0, bottom: 10.0),
                child: Text(
                  _isTutorialSpeaking
                      ? "Tap to skip"
                      : (stepData.mediaType == MediaType.video &&
                              _tutorialVideoController?.value.isPlaying == true
                          ? "Tap to skip video or text"
                          : "Tap to continue"),
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.7), fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraDisplay() {
    if (_isMainCameraInitializing) {
      return Container(
          key: const ValueKey('placeholder_initializing'),
          color: Colors.black,
          child: const Center(
              child: CircularProgressIndicator(color: Colors.white)));
    } else if (_cameraController != null &&
        _initializeControllerFuture != null) {
      return FutureBuilder<void>(
          key: _cameraViewKey,
          future: _initializeControllerFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done) {
              if (_cameraController != null &&
                  _cameraController!.value.isInitialized) {
                return CameraViewWidget(
                    cameraController: _cameraController,
                    initializeControllerFuture: _initializeControllerFuture);
              } else {
                return _buildCameraErrorPlaceholder("Camera failed");
              }
            } else {
              return Container(
                  color: Colors.black,
                  child: const Center(
                      child: CircularProgressIndicator(color: Colors.white)));
            }
          });
    } else {
      return _buildCameraErrorPlaceholder("Camera unavailable");
    }
  }

  Widget _buildCameraErrorPlaceholder(String message) {
    return Container(
        key: ValueKey('placeholder_error_$message'),
        color: Colors.black,
        child: Center(
            child: Text(message, style: const TextStyle(color: Colors.red))));
  }

  Widget _buildFeaturePageView() {
    return PageView.builder(
        controller: _pageController,
        itemCount: _features.length,
        physics: const ClampingScrollPhysics(),
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          if (index >= _features.length)
            return Center(
                child: Text("Error: Invalid page index $index",
                    style: const TextStyle(color: Colors.red)));
          final feature = _features[index];

          switch (feature.id) {
            case 'barcode_scanner':
              return BarcodeScannerPage(
                  key: const ValueKey('barcodeScanner'),
                  barcodeApiService: _barcodeApiService,
                  ttsService: _ttsService);
            case 'object_detection':
              return ObjectDetectionPage(detectionResult: _lastObjectResult);
            case 'hazard_detection':
              return HazardDetectionPage(
                  detectionResult: _currentDisplayedHazardName,
                  isHazardAlert: _isHazardAlertActive);
            case 'scene_detection':
              return SceneDetectionPage(detectionResult: _lastSceneTextResult);
            case 'text_detection':
              return TextDetectionPage(detectionResult: _lastSceneTextResult);
            case 'currency_detection': // This uses _lastCurrencyResult
              return CurrencyDetectionPage(
                  detectionResult: _lastCurrencyResult);
            case 'focus_mode':
              return FocusModePage(
                  key: const ValueKey('focusMode'),
                  focusedObject: _focusedObject,
                  isObjectDetectedInFrame: _isFocusObjectDetectedInFrame,
                  isObjectCentered: _isFocusObjectCentered,
                  isPrompting: _isFocusPromptActive);
            case 'supervision':
              return SuperVisionPage(
                  key: const ValueKey('supervision'),
                  isLoading: _isSupervisionProcessing,
                  resultType: _supervisionResultType,
                  displayResult: _supervisionDisplayResult,
                  hazardName: _supervisionHazardName,
                  isHazardActive: _supervisionIsHazardActive);
            default:
              return Center(
                  child: Text('Unknown Page: ${feature.id}',
                      style: const TextStyle(color: Colors.white)));
          }
        });
  }

  Widget _buildSettingsButton() {
    return Align(
        alignment: Alignment.topRight,
        child: SafeArea(
            child: Padding(
                padding: const EdgeInsets.only(top: 10.0, right: 15.0),
                child: IconButton(
                    icon: const Icon(Icons.settings,
                        color: Colors.white,
                        size: 32.0,
                        shadows: [
                          Shadow(
                              blurRadius: 6.0,
                              color: Colors.black54,
                              offset: Offset(1.0, 1.0))
                        ]),
                    onPressed: _navigateToSettingsPage,
                    tooltip: 'Settings'))));
  }

  Widget _buildMainActionButton(FeatureConfig currentFeature) {
    final bool isRealtimeObjectOrHazard =
        currentFeature.id == objectDetectionFeature.id ||
            currentFeature.id == hazardDetectionFeature.id;
    final bool isBarcodePage = currentFeature.id == barcodeScannerFeature.id;
    final bool isFocusActivePage = currentFeature.id == focusModeFeature.id;
    final bool isSuperVisionPage = currentFeature.id == supervisionFeature.id;
    final bool isCurrencyPage =
        currentFeature.id == currencyDetectionFeature.id; // Already here

    VoidCallback? onTapAction;
    if (isSuperVisionPage) {
      onTapAction = () {
        debugPrint(
            "[Action Button] SuperVision tap - performing LLM analysis.");
        _performManualDetection(supervisionFeature.id);
      };
    } else if (isFocusActivePage) {
      onTapAction = () {
        debugPrint("[Action Button] Focus tap - listening for object.");
        if (!_speechEnabled) {
          _showStatusMessage('Speech not available', isError: true);
          _initSpeech();
          return;
        }
        if (_speechToText.isNotListening)
          _startListening(isForFocusObject: true);
        else
          _stopListening();
      };
    } else if (!isRealtimeObjectOrHazard && !isBarcodePage) {
      // This covers Scene, Text, and Currency
      onTapAction = () {
        debugPrint(
            "[Action Button] Manual detection tap for ${currentFeature.id}");
        _performManualDetection(currentFeature.id);
      };
    }

    VoidCallback onLongPressAction = () {
      debugPrint("[Action Button] Long press - listening for general command.");
      if (!_speechEnabled) {
        _showStatusMessage('Speech not available', isError: true);
        _initSpeech();
        return;
      }
      if (_speechToText.isNotListening)
        _startListening(isForFocusObject: false);
      else
        _stopListening();
    };

    IconData iconData = Icons.mic_none;
    if (_isListening)
      iconData = Icons.mic;
    else if (isCurrencyPage) {
      // Icon for currency page is already correct
      iconData = Icons.attach_money;
    } else if (isFocusActivePage)
      iconData = Icons.filter_center_focus;
    else if (isSuperVisionPage)
      iconData = Icons.auto_awesome;
    else if (!isRealtimeObjectOrHazard && !isBarcodePage)
      iconData = Icons.play_arrow;
    else
      iconData = Icons.camera_alt;

    return ActionButton(
        onTap: onTapAction,
        onLongPress: onLongPressAction,
        isListening: _isListening,
        color: currentFeature.color,
        iconOverride: iconData);
  }

  String _getObjectLocation(double centerX, double centerY) {
    String verticalPos;
    String horizontalPos;

    // Vertical position
    if (centerY < 1 / 3) {
      verticalPos = "top";
    } else if (centerY < 2 / 3) {
      verticalPos = "middle";
    } else {
      verticalPos = "bottom";
    }

    // Horizontal position
    if (centerX < 1 / 3) {
      horizontalPos = "left";
    } else if (centerX < 2 / 3) {
      horizontalPos = "center";
    } else {
      horizontalPos = "right";
    }

    // Combine for descriptive location
    if (verticalPos == "middle" && horizontalPos == "center") {
      return "center";
    }
    // e.g. "top left", "middle right", "bottom center"
    return "$verticalPos $horizontalPos";
  }
}
