import 'dart:async';
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

import '../../core/models/feature_config.dart';
import '../../core/services/websocket_service.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/tts_service.dart';
import '../../core/services/barcode_api_service.dart';

import '../../features/feature_registry.dart'; 
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

  // Detection Results & State (for dedicated pages)
  String _lastObjectResult = "";
  String _lastSceneTextResult = "";
  // String _lastHazardRawResult = ""; // Not directly used for display, processed into below
  String _currentDisplayedHazardName = "";
  bool _isHazardAlertActive = false;

  // SuperVision State
  String _supervisionHazardName = ""; // Specific hazard name for SuperVisionPage
  bool _supervisionIsHazardActive = false; // Specific hazard active state for SuperVisionPage
  bool _isSupervisionProcessing = false; // Loading state for SuperVision
  String? _supervisionResultType; // e.g., 'object_detection', 'scene_detection' as determined by LLM
  String _supervisionDisplayResult = ""; // The result string to display on SuperVisionPage

  // Timers & Processing Flags
  Timer? _hazardAlertClearTimer;
  Timer? _detectionTimer;
  bool _isProcessingImage = false; // General flag for when an image is being sent/processed
  String? _lastRequestedFeatureId; // Tracks which feature requested the last image

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
  static const Duration _detectionInterval = Duration(seconds: 3);
  static const Duration _hazardAlertPersistence = Duration(seconds: 4);
  static const Duration _focusFoundAnnounceCooldown = Duration(seconds: 5);
  static const double _focusCenterThreshold = 0.15;
  static const int _focusBeepMaxIntervalMs = 1200;
  static const int _focusBeepMinIntervalMs = 150;
  static const Set<String> _hazardObjectNames = {
    "car", "bicycle", "motorcycle", "bus", "train", "truck", "boat",
    "traffic light", "stop sign", "knife", "scissors", "fork",
    "oven", "toaster", "microwave", "bird", "cat", "dog", "horse",
    "sheep", "cow", "elephant", "bear", "zebra", "giraffe"
  };











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
    final currentFeatureId = _features.isNotEmpty ? _features[_currentPage.clamp(0, _features.length - 1)].id : null;
    debugPrint("[Lifecycle] State changed to: $state, Current Page: $currentFeatureId (Focus Active: $_isFocusModeActive, SuperVision Active: ${currentFeatureId == supervisionFeature.id})");

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _handleAppPause();
    } else if (state == AppLifecycleState.resumed) {
      _handleAppResume();
    }
  }











  // --- Initialization Helper -----------------------------------------------------------------------------------
  Future<void> _initializeApp() async {
    _initializeFeatures();
    await _loadAndInitializeSettings();
    await _checkVibratorAndAmplitude();
    await _prepareAudioPlayers();

    final currentFeatureId = _features.isNotEmpty ? _features[_currentPage.clamp(0, _features.length - 1)].id : null;
    // Don't init main camera if starting on barcode or focus mode (until object selected)
    if (currentFeatureId != barcodeScannerFeature.id && currentFeatureId != focusModeFeature.id) {
      await _initializeMainCameraController();
    } else {
      debugPrint("[HomeScreen] Initializing on barcode/focus page, skipping initial main camera init.");
    }
    await _initSpeech();
    _initializeWebSocket();
    if (_ttsInitialized && _features.isNotEmpty && _features.first.title.isNotEmpty) {
       _ttsService.speak(_features[0].title);
    }
  }

  void _initializeFeatures() {
    // Assumes availableFeatures from feature_registry.dart includes ALL features
    // (SuperVision, FocusMode, and others) in the desired order.
    _features = availableFeatures;
    debugPrint("[HomeScreen] Features Initialized: ${_features.map((f) => f.id).toList()}");
  }

  Future<void> _loadAndInitializeSettings() async {
    final results = await Future.wait([
      _settingsService.getOcrLanguage(), _settingsService.getTtsVolume(),
      _settingsService.getTtsPitch(), _settingsService.getTtsRate(),
      _settingsService.getObjectDetectionCategory(),
    ]);
    _selectedOcrLanguage = results[0] as String;
    final ttsVolume = results[1] as double; final ttsPitch = results[2] as double;
    final ttsRate = results[3] as double; _selectedObjectCategory = results[4] as String;

    if (!_ttsInitialized) {
      await _ttsService.initTts(initialVolume: ttsVolume, initialPitch: ttsPitch, initialRate: ttsRate);
      _ttsInitialized = true;
    } else { await _ttsService.updateSettings(ttsVolume, ttsPitch, ttsRate); }
    debugPrint("[HomeScreen] Settings loaded. OCR: $_selectedOcrLanguage, Cat: $_selectedObjectCategory");
  }

  Future<void> _checkVibratorAndAmplitude() async {
    try {
      _hasVibrator = await Vibration.hasVibrator() ?? false;
      if (_hasVibrator) {
        _hasAmplitudeControl = await Vibration.hasAmplitudeControl() ?? false;
      } else {
        _hasAmplitudeControl = false;
      }
      debugPrint("[HomeScreen] Vibrator available: $_hasVibrator, Amplitude Control: $_hasAmplitudeControl");
    } catch (e) {
      debugPrint("[HomeScreen] Error checking vibration capabilities: $e");
      _hasVibrator = false; _hasAmplitudeControl = false;
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











  // --- Lifecycle Event Handlers -----------------------------------------------------------------------------------
  void _handleAppPause() {
    debugPrint("[Lifecycle] App inactive/paused - Cleaning up...");
    _stopDetectionTimer();
    _stopFocusFeedback();
    if (_ttsInitialized) _ttsService.stop();
    _alertAudioPlayer.pause();
    _beepPlayer.pause();
    _hazardAlertClearTimer?.cancel();

    final currentFeatureId = _features.isNotEmpty ? _features[_currentPage.clamp(0, _features.length - 1)].id : null;
    if (currentFeatureId != barcodeScannerFeature.id) {
      _disposeMainCameraController();
    } else {
      debugPrint("[Lifecycle] App paused on barcode page, main camera already disposed.");
    }
  }

  void _handleAppResume() {
    debugPrint("[Lifecycle] App resumed");
    final currentFeatureId = _features.isNotEmpty ? _features[_currentPage.clamp(0, _features.length - 1)].id : null;

    // Re-initialize camera if needed (not barcode or focus mode without object)
    bool isFocusModeWaitingForObject = _isFocusModeActive && _focusedObject == null;
    if (currentFeatureId != barcodeScannerFeature.id && !isFocusModeWaitingForObject) {
      debugPrint("[Lifecycle] Resumed on non-barcode/non-initial-focus page. Ensuring main camera.");
      _initializeMainCameraController();
    } else {
      debugPrint("[Lifecycle] Resumed on barcode page or initial focus page. Main camera remains off/uninitialized.");
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
    if (_cameraController == null && _initializeControllerFuture == null && !_isMainCameraInitializing) return;
    debugPrint("[HomeScreen] Disposing main camera controller...");
    _stopDetectionTimer();
    final controllerToDispose = _cameraController; final initFuture = _initializeControllerFuture;
    _cameraController = null; _initializeControllerFuture = null; _isMainCameraInitializing = false;
    _cameraViewKey = UniqueKey();
    if (mounted) setState(() {});
    try {
      if (initFuture != null) await initFuture.timeout(const Duration(milliseconds: 200)).catchError((_) {});
      if (controllerToDispose != null) { await controllerToDispose.dispose(); debugPrint("[HomeScreen] Main camera disposed."); }
    } catch (e, s) { debugPrint("[HomeScreen] Error disposing camera: $e \n$s"); }
    debugPrint("[HomeScreen] Main camera dispose sequence finished.");
  }

  Future<void> _initializeMainCameraController() async {
    debugPrint("[HomeScreen] Attempting to initialize main camera controller...");
    final currentFeatureId = _features.isNotEmpty ? _features[_currentPage.clamp(0, _features.length - 1)].id : null;
    bool isFocusModeWaitingForObject = _isFocusModeActive && _focusedObject == null;
    if (widget.camera == null || currentFeatureId == barcodeScannerFeature.id || isFocusModeWaitingForObject || _cameraController != null || _isMainCameraInitializing) {
      debugPrint("[HomeScreen] Skipping main camera init. Reason: No camera (${widget.camera == null}), Barcode ($currentFeatureId == ${barcodeScannerFeature.id}), Initial Focus ($isFocusModeWaitingForObject), Exists (${_cameraController != null}), Initializing ($_isMainCameraInitializing)");
      return;
    }
    if (!mounted) { debugPrint("[HomeScreen] Camera init skipped: Not mounted."); return; }
    debugPrint("[HomeScreen] Proceeding with main CameraController initialization...");
    _isMainCameraInitializing = true; _cameraController = null; _initializeControllerFuture = null;
    _cameraViewKey = UniqueKey();
    if (mounted) setState(() {});
    await Future.delayed(const Duration(milliseconds: 50));
    isFocusModeWaitingForObject = _isFocusModeActive && _focusedObject == null; // Re-check
    final updatedCurrentFeatureId = _features.isNotEmpty ? _features[_currentPage.clamp(0, _features.length - 1)].id : null; // Re-check current page
    if (!mounted || updatedCurrentFeatureId == barcodeScannerFeature.id || isFocusModeWaitingForObject) {
      _isMainCameraInitializing = false; if (mounted) setState(() {});
      debugPrint("[HomeScreen] Aborting camera init after delay. Mounted: $mounted, Feature: $updatedCurrentFeatureId, FocusWaiting: $isFocusModeWaitingForObject"); return;
    }

    CameraController newController;
    try {
      newController = CameraController(widget.camera!, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
    } catch (e) {
      debugPrint("[HomeScreen] Error creating CameraController: $e");
      if (mounted) { _showStatusMessage("Failed to create camera", isError: true); _isMainCameraInitializing = false; setState(() {}); } return;
    }

    Future<void> initFuture;
    try { _cameraController = newController; initFuture = newController.initialize(); _initializeControllerFuture = initFuture; if (mounted) setState(() {}); } catch (e) {
      debugPrint("[HomeScreen] Error assigning init future: $e");
      if (mounted) { _showStatusMessage("Failed camera init", isError: true); _cameraController = null; _initializeControllerFuture = null; _isMainCameraInitializing = false; setState(() {}); } return;
    }

    try {
      await initFuture;
      if (!mounted) { debugPrint("[HomeScreen] Camera init successful but widget unmounted. Disposing."); try { await newController.dispose(); } catch (_) {} return; }
      if (_cameraController == newController) {
        debugPrint("[HomeScreen] Main Camera initialized successfully.");
        _isMainCameraInitializing = false;
        _startDetectionTimerIfNeeded();
      } else {
        debugPrint("[HomeScreen] Camera controller changed during init. Disposing new."); try { await newController.dispose(); } catch (_) {}
        _isMainCameraInitializing = false;
      }
    } catch (error, s) {
      debugPrint("[HomeScreen] Main Camera initialization error: $error\n$s");
      if (!mounted) { _isMainCameraInitializing = false; return; }
      final bool shouldReset = _cameraController == newController;
      if (shouldReset) {
        _showStatusMessage("Camera init failed", isError: true);
        _cameraController = null; _initializeControllerFuture = null;
      } else { try { await newController.dispose(); } catch (_) {} }
      _isMainCameraInitializing = false;
    } finally { if (mounted) setState(() {}); }
  }











  // --- WebSocket Handling ---
  void _initializeWebSocket() {
    debugPrint("[HomeScreen] Initializing WebSocket listener...");
    _webSocketService.responseStream.listen(
        _handleWebSocketData,
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
     if (data.containsKey('event') && (data['event'] == 'disconnect' || data['event'] == 'error' || data['event'] == 'connect_error' || data['event'] == 'connect_timeout')) {
        _handleWebSocketError(data['message'] ?? data['reason'] ?? 'Unknown connection issue: ${data['event']}');
        return;
    }


    final bool isSupervisionResponse = data['is_from_supervision_llm'] == true;

    if (isSupervisionResponse) {
        // --- Handle SuperVision Result ---
        debugPrint('[HomeScreen] Processing SuperVision routed result: $data');
        final String resultTextRaw = data['result'] as String? ?? "No result";
        final String? actualFeatureIdFromSupervision = data['feature_id'] as String?;

        if (actualFeatureIdFromSupervision == null) {
            debugPrint('[HomeScreen] SuperVision result missing feature_id. Cannot process.');
            if (mounted) {
                setState(() {
                    _isSupervisionProcessing = false;
                    _supervisionDisplayResult = "Error: Invalid response from server (missing feature_id)";
                    _supervisionResultType = "supervision_error"; // Mark as error type
                });
            }
            return;
        }

        setState(() {
            _isSupervisionProcessing = false;
            _supervisionResultType = actualFeatureIdFromSupervision;
            _supervisionDisplayResult = ""; // Clear previous
            _supervisionHazardName = "";    // Clear previous
            _supervisionIsHazardActive = false; // Clear previous
            String textToSpeak = "";

            // Helpers adapted from _process<Feature>Detection methods
            // These now directly update _supervisionDisplayResult and build textToSpeak

            if (actualFeatureIdFromSupervision == objectDetectionFeature.id) {
                final odResult = _processSupervisionObjectDetectionResult(resultTextRaw);
                _supervisionDisplayResult = odResult['display'];
                textToSpeak = odResult['speak'] ? odResult['speakText'] : "Object detection complete.";

                // Check for hazards within these object detections
                 List<String> detectedObjectsList = resultTextRaw.isNotEmpty && !resultTextRaw.startsWith("Error") && resultTextRaw != "No objects detected"
                    ? resultTextRaw.toLowerCase().split(',').map((e) => e.trim()).toList()
                    : [];
                String hazardNameFromOD = _processHazardDetection(detectedObjectsList); // Uses Backend's main hazard logic
                if (hazardNameFromOD.isNotEmpty) {
                    _supervisionHazardName = hazardNameFromOD; // Set for SuperVisionPage display
                    _supervisionIsHazardActive = _isHazardAlertActive; // Reflect main alert state
                    // TTS for hazard handled by _triggerHazardAlert, avoid double speaking here
                    // textToSpeak += ". Hazard: ${hazardNameFromOD.replaceAll('_', ' ')}";
                }

            } else if (actualFeatureIdFromSupervision == hazardDetectionFeature.id) {
                List<String> detectedObjectsList = resultTextRaw.isNotEmpty && !resultTextRaw.startsWith("Error") && resultTextRaw != "No objects detected"
                    ? resultTextRaw.toLowerCase().split(',').map((e) => e.trim()).toList()
                    : [];
                String hazardName = _processHazardDetection(detectedObjectsList); // Main hazard logic triggers alert & TTS
                _supervisionHazardName = hazardName;
                _supervisionIsHazardActive = _isHazardAlertActive;
                _supervisionDisplayResult = hazardName.isNotEmpty ? hazardName.replaceAll('_', ' ') : "No direct hazards detected by SuperVision.";
                textToSpeak = hazardName.isNotEmpty ? "" : "Hazard scan complete. No critical hazards identified by SuperVision.";

            } else if (actualFeatureIdFromSupervision == sceneDetectionFeature.id) {
                final sceneResult = _processSupervisionSceneResult(resultTextRaw);
                _supervisionDisplayResult = sceneResult['display'];
                textToSpeak = sceneResult['speak'] ? sceneResult['speakText'] : "Scene analysis complete.";

            } else if (actualFeatureIdFromSupervision == textDetectionFeature.id) {
                final textResult = _processSupervisionTextResult(resultTextRaw);
                _supervisionDisplayResult = textResult['display'];
                textToSpeak = textResult['speak'] ? textResult['speakText'] : "Text analysis complete.";
            }
             else if (actualFeatureIdFromSupervision == 'supervision_error'){
                 _supervisionDisplayResult = resultTextRaw.isNotEmpty ? resultTextRaw : "SuperVision analysis failed.";
                 textToSpeak = _supervisionDisplayResult;
            }
            else {
                _supervisionDisplayResult = "Unknown result type from SuperVision: $actualFeatureIdFromSupervision. Raw: $resultTextRaw";
                textToSpeak = "SuperVision analysis complete with an unknown result type.";
                debugPrint("[HomeScreen] SuperVision unhandled feature ID: $actualFeatureIdFromSupervision, data: $resultTextRaw");
            }

            // Speak the combined result from SuperVision, carefully to avoid double-speaking hazards
            if (_ttsInitialized && textToSpeak.isNotEmpty) {
                bool hazardWasSpokenByAlert = (_supervisionHazardName.isNotEmpty && _isHazardAlertActive);
                if (!hazardWasSpokenByAlert) {
                    _ttsService.speak(textToSpeak);
                } else if (textToSpeak != "") { // Speak non-hazard part if any
                    String nonHazardPart = textToSpeak;
                     // Attempt to remove hazard announcement from textToSpeak if it was already said
                    if (_supervisionHazardName.isNotEmpty) {
                        nonHazardPart = nonHazardPart.replaceAll(RegExp("Hazard detected: ${_supervisionHazardName.replaceAll('_', ' ')}", caseSensitive: false), "").trim();
                        nonHazardPart = nonHazardPart.replaceAll(RegExp("Hazard: ${_supervisionHazardName.replaceAll('_', ' ')}", caseSensitive: false), "").trim();
                    }
                    if (nonHazardPart.isNotEmpty && nonHazardPart != ".") _ttsService.speak(nonHazardPart);
                }
            }
             _isProcessingImage = false; // Reset general processing flag
             _lastRequestedFeatureId = null;
        });

    } else if (data.containsKey('result') && data['result'] is Map<String, dynamic>) {
        // --- Handle Direct/Focus Mode Result ---
        final Map<String, dynamic> resultData = data['result'];
        final String status = resultData['status'] ?? 'error';
        final String? receivedForFeatureId = _lastRequestedFeatureId;

        _processFeatureResult(receivedForFeatureId, status, resultData); // P1's original logic
         _isProcessingImage = false; // Reset general processing flag
         _lastRequestedFeatureId = null;


    } else {
        debugPrint('[HomeScreen] Received unexpected WS data format: $data');
        if (_isProcessingImage) setState(() => _isProcessingImage = false);
        if (_isSupervisionProcessing) setState(() => _isSupervisionProcessing = false);
         _lastRequestedFeatureId = null;
    }
}


  // Processes results for dedicated feature pages (Object, Scene, Text) and Focus Mode
  // This is primarily Backend's logic.
  void _processFeatureResult(String? featureId, String status, Map<String, dynamic> resultData) {
    if (!mounted) return;

    // Hazard check for object detection results on its dedicated page
    if (featureId == objectDetectionFeature.id && status == 'ok') {
        List<String> currentDetections = (resultData['detections'] as List<dynamic>?)
            ?.map((d) => (d as Map<String, dynamic>)['name'] as String? ?? '')
            .where((name) => name.isNotEmpty)
            .toList() ?? [];
      //  _processHazardDetection(currentDetections); // This will trigger alerts if needed
    } else if (featureId == hazardDetectionFeature.id && status == 'ok') {
        List<String> currentDetections = (resultData['detections'] as List<dynamic>?)
            ?.map((d) => (d as Map<String, dynamic>)['name'] as String? ?? '')
            .where((name) => name.isNotEmpty)
            .toList() ?? [];
        _processHazardDetection(currentDetections);
    }


    setState(() {
        // --- Handle Focus Mode Results ---
        if (_isFocusModeActive && featureId == focusModeFeature.id) { // Ensure featureId matches for focus
            if (status == 'found') {
                final detection = resultData['detection'] as Map<String, dynamic>?;
                final String detectedName = (detection?['name'] as String?)?.toLowerCase() ?? "null";
                final String targetName = _focusedObject?.toLowerCase() ?? "null";
                debugPrint("[Focus] Received detection: '$detectedName'. Target: '$targetName'. Status: '$status'");
                if (detection != null && detectedName == targetName) {
                    final double centerX = detection['center_x'] as double? ?? 0.5;
                    final double centerY = detection['center_y'] as double? ?? 0.5;
                    final double dx = centerX - 0.5; final double dy = centerY - 0.5;
                    final double dist = sqrt(dx * dx + dy * dy);
                    _currentProximity = (1.0 - (dist / 0.707)).clamp(0.0, 1.0);
                    debugPrint("[Focus] Target '$targetName' found. Prox: ${_currentProximity.toStringAsFixed(3)}");
                    _isFocusObjectDetectedInFrame = true;
                    _isFocusObjectCentered = dist < _focusCenterThreshold;

                    if (_isFocusObjectCentered && !_announcedFocusFound) {
                        if (_ttsInitialized) _ttsService.speak("${_focusedObject ?? 'Object'} found!");
                        _announcedFocusFound = true;
                        Future.delayed(_focusFoundAnnounceCooldown, () {
                            if (mounted) _announcedFocusFound = false;
                        });
                    }
                } else {
                    debugPrint("[Focus] Detected '$detectedName' != target '$targetName'. Resetting.");
                    _currentProximity = 0.0; _isFocusObjectDetectedInFrame = false; _isFocusObjectCentered = false;
                }
            } else { // 'not_found', 'none', 'error' for focus mode
                debugPrint("[Focus] Target '$_focusedObject' not found or error. Status '$status'. Resetting.");
                _currentProximity = 0.0; _isFocusObjectDetectedInFrame = false; _isFocusObjectCentered = false;
            }
            _updateFocusFeedback();
        }
        // --- Handle Normal Mode Results (for dedicated pages) ---
        else {
            bool speakResult = false;
            String textToSpeak = "";
            String displayResult = "";

            if (featureId == objectDetectionFeature.id) {
                if (status == 'ok') {
                    List<String> names = (resultData['detections'] as List<dynamic>?)
                        ?.map((d) => (d as Map<String, dynamic>)['name'] as String? ?? '')
                        .where((name) => name.isNotEmpty).toList() ?? [];
                    List<String> filteredNames = _filterObjectsByCategory(names);
                    displayResult = filteredNames.isNotEmpty ? filteredNames.join(', ') : "No objects in category";
                    speakResult = filteredNames.isNotEmpty;
                    textToSpeak = displayResult;
                } else if (status == 'none') { displayResult = "No objects detected";
                } else { displayResult = resultData['message'] ?? "Detection Error"; }
                _lastObjectResult = displayResult;
            }
            else if (featureId == sceneDetectionFeature.id) {
                if (status == 'ok') {
                    displayResult = (resultData['scene'] as String? ?? "Unknown Scene").replaceAll('_', ' ');
                    speakResult = true; textToSpeak = "Scene: $displayResult";
                } else { displayResult = resultData['message'] ?? "Scene Error"; }
                _lastSceneTextResult = displayResult;
            }
            else if (featureId == textDetectionFeature.id) {
                if (status == 'ok') {
                    displayResult = resultData['text'] as String? ?? "No text";
                    speakResult = true; textToSpeak = "Text detected: $displayResult";
                } else if (status == 'none') { displayResult = "No text detected";
                } else { displayResult = resultData['message'] ?? "Text Error"; }
                _lastSceneTextResult = displayResult;
            }
            // Hazard feature ID results are primarily handled by _processHazardDetection setting global state

            if (speakResult && _ttsInitialized && featureId != hazardDetectionFeature.id) {
                _ttsService.speak(textToSpeak);
            }
        }
       // _isProcessingImage = false; // This is now reset in _handleWebSocketData
    });
  }

  // Helper methods for processing SuperVision's STRING results (adapted from Backend)
  Map<String, dynamic> _processSupervisionObjectDetectionResult(String rawDetections) {
    String displayResult;
    bool speakResult = false;
    String textToSpeak = "";

    if (rawDetections.isNotEmpty && rawDetections != "No objects detected" && !rawDetections.startsWith("Error")) {
        List<String> allDetected = rawDetections.split(',').map((e) => e.trim()).toList();
        List<String> filteredObjects = _filterObjectsByCategory(allDetected); // Use Backend's filtering

        if (filteredObjects.isNotEmpty) {
            displayResult = filteredObjects.join(', ');
            speakResult = true;
            textToSpeak = displayResult;
        } else {
            displayResult = "No objects found in category: ${objectDetectionCategories[_selectedObjectCategory] ?? _selectedObjectCategory}";
            speakResult = false; // Don't speak if empty after filter
        }
    } else {
        displayResult = rawDetections; // "No objects detected" or "Error..."
        speakResult = false;
    }
    return {'display': displayResult, 'speak': speakResult, 'speakText': textToSpeak};
}

  Map<String, dynamic> _processSupervisionSceneResult(String resultTextRaw) {
      String displayResult = resultTextRaw.replaceAll('_', ' ');
      bool speakResult = displayResult.isNotEmpty && !displayResult.startsWith("Error");
      String textToSpeak = speakResult ? "Scene: $displayResult" : "";
      return {'display': displayResult, 'speak': speakResult, 'speakText': textToSpeak};
  }

  Map<String, dynamic> _processSupervisionTextResult(String resultTextRaw) {
      String displayResult = resultTextRaw;
      bool speakResult = displayResult.isNotEmpty && displayResult != "No text detected" && !displayResult.startsWith("Error");
      String textToSpeak = speakResult ? "Text detected: $displayResult" : "";
      return {'display': displayResult, 'speak': speakResult, 'speakText': textToSpeak};
  }


  List<String> _filterObjectsByCategory(List<String> objectNames) {
    if (_selectedObjectCategory == 'all') return objectNames;
    return objectNames.where((obj) {
      String lowerObj = obj.toLowerCase();
      return cocoObjectToCategoryMap[lowerObj] == _selectedObjectCategory;
    }).toList();
  }

  // Processes list of object names for hazards, triggers alert, returns primary hazard name. (Backend logic)
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
      _triggerHazardAlert(specificHazardFound); // Triggers sound, vibration, TTS
    }
    // This method sets _isHazardAlertActive and _currentDisplayedHazardName
    // which are used by HazardDetectionPage and SuperVisionPage.
    return specificHazardFound; // Return name for other uses if needed
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
      _lastObjectResult = "Connection Error"; _lastSceneTextResult = "Connection Error";
      _isHazardAlertActive = false; _currentDisplayedHazardName = "";
      _isFocusModeActive = false; _focusedObject = null;
      // SuperVision error state
      _isSupervisionProcessing = false;
      _supervisionResultType = "supervision_error";
      _supervisionDisplayResult = "Connection Error: ${error.toString()}";
      _supervisionHazardName = ""; _supervisionIsHazardActive = false;
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
        _lastObjectResult = "Disconnected"; _lastSceneTextResult = "Disconnected";
        _isHazardAlertActive = false; _currentDisplayedHazardName = "";
        _isFocusModeActive = false; _focusedObject = null;
        // SuperVision disconnected state
        _isSupervisionProcessing = false;
        _supervisionResultType = "supervision_error";
        _supervisionDisplayResult = "Disconnected. Trying to reconnect...";
        _supervisionHazardName = ""; _supervisionIsHazardActive = false;
      });
      _showStatusMessage('Disconnected. Trying to reconnect...', isError: true, durationSeconds: 5);
    }
  }











  // --- Speech Recognition Handling ---
  Future<void> _initSpeech() async {
    try {
      _speechEnabled = await _speechToText.initialize(
          onStatus: _handleSpeechStatus, onError: _handleSpeechError, debugLogging: kDebugMode);
      debugPrint('Speech recognition initialized: $_speechEnabled');
      if (!_speechEnabled && mounted) _showStatusMessage('Speech unavailable', durationSeconds: 3);
    } catch (e) { debugPrint('Error initializing speech: $e'); if (mounted) _showStatusMessage('Speech init failed', durationSeconds: 3); }
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
    debugPrint('Speech error: ${error.errorMsg} (Permanent: ${error.permanent})');
    if (_isListening) setState(() => _isListening = false);
    if (_isListeningForFocusObject) _isListeningForFocusObject = false;
    String errorMessage = 'Speech error: ${error.errorMsg}';
    if (error.errorMsg.contains('permission') || error.errorMsg.contains('denied')) {
      errorMessage = 'Microphone permission needed.'; _showPermissionInstructions();
    } else if (error.errorMsg == 'error_no_match') { errorMessage = 'Could not recognize speech. Please try again.';
    } else if (error.errorMsg.contains('No speech')) { errorMessage = 'No speech detected.';
    } else if (error.errorMsg.contains('timeout')) { errorMessage = 'Listening timed out.';
    } else if (error.permanent) { errorMessage = 'Speech recognition error. Please restart.'; }
    _showStatusMessage(errorMessage, isError: true, durationSeconds: 4);
  }

  void _startListening({bool isForFocusObject = false}) async {
    if (!_speechEnabled) { _showStatusMessage('Speech not available', isError: true); _initSpeech(); return; }
    bool hasPermission = await _speechToText.hasPermission;
    if (!hasPermission && mounted) { _showPermissionInstructions(); _showStatusMessage('Microphone permission needed', isError: true); return; }
    if (!mounted) return;
    if (_speechToText.isListening) await _stopListening();

    _isListeningForFocusObject = isForFocusObject;
    debugPrint("Starting speech listener... (For Focus Object: $_isListeningForFocusObject)");
    if (_ttsInitialized) _ttsService.stop();

    try {
      await _speechToText.listen(
          onResult: _handleSpeechResult,
          listenFor: Duration(seconds: isForFocusObject ? 10 : 7),
          pauseFor: const Duration(seconds: 3), partialResults: false, cancelOnError: true,
          listenMode: ListenMode.confirmation
      );
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Error starting speech listener: $e");
      if (mounted) { _showStatusMessage("Could not start listening", isError: true); setState(() => _isListening = false); }
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

  void _handleSpeechResult(SpeechRecognitionResult result) {
    if (mounted && result.finalResult && result.recognizedWords.isNotEmpty) {
      String command = result.recognizedWords.toLowerCase().trim();
      debugPrint('Final recognized speech: "$command" (Was for focus: $_isListeningForFocusObject)');

      if (_isFocusModeActive && _isListeningForFocusObject) {
        debugPrint("[Focus] Setting focused object to: '$command'");
        setState(() {
          _focusedObject = command; _isFocusPromptActive = false;
          _isFocusObjectDetectedInFrame = false; _isFocusObjectCentered = false;
          _currentProximity = 0.0; _announcedFocusFound = false;
        });
        _stopFocusFeedback();
        if (_ttsInitialized) _ttsService.speak("Finding ${_focusedObject ?? 'object'}");
        debugPrint("[Focus] Object set. Triggering camera initialization...");
        _initializeMainCameraController(); // Initialize camera for focus mode
      } else {
        debugPrint("[Speech] Processing general command: '$command'");
        _processGeneralSpeechCommand(command);
      }
      if (_isListeningForFocusObject) _isListeningForFocusObject = false;
    }
  }

  void _processGeneralSpeechCommand(String command) {
    if (command == 'settings' || command == 'setting') { _navigateToSettingsPage(); return; }
    int targetPageIndex = -1;
    for (int i = 0; i < _features.length; i++) {
      for (String keyword in _features[i].voiceCommandKeywords) {
        if (command.contains(keyword)) { targetPageIndex = i; break; }
      }
      if (targetPageIndex != -1) break;
    }
    if (targetPageIndex != -1) {
      _navigateToPage(targetPageIndex);
    } else { _showStatusMessage('Command "$command" not recognized.', durationSeconds: 3); }
  }











  // --- Detection Logic ---
  void _startDetectionTimerIfNeeded() {
    if (!mounted || _features.isEmpty) return;
    final currentFeatureId = _features[_currentPage.clamp(0, _features.length - 1)].id;

    bool isNormalRealtime = (currentFeatureId == objectDetectionFeature.id || currentFeatureId == hazardDetectionFeature.id);
    bool isFocusModeRunning = _isFocusModeActive && _focusedObject != null && currentFeatureId == focusModeFeature.id;

    if ((isNormalRealtime || isFocusModeRunning) &&
        _detectionTimer == null &&
        _cameraController != null && (_cameraController?.value.isInitialized ?? false) &&
        !_isMainCameraInitializing && _webSocketService.isConnected) {
      debugPrint("[HomeScreen] Starting detection timer. Mode: ${isFocusModeRunning ? 'Focus' : 'Normal Realtime'}");
      _detectionTimer = Timer.periodic(_detectionInterval, (_) { _performPeriodicDetection(); });
    } else {
      bool shouldStopTimer = false;
      if (_detectionTimer != null) {
        if (_isFocusModeActive && _focusedObject == null && currentFeatureId == focusModeFeature.id) shouldStopTimer = true;
        else if (!isNormalRealtime && !isFocusModeRunning) shouldStopTimer = true;
      }
      if (shouldStopTimer) _stopDetectionTimer();
    }
  }

  void _stopDetectionTimer() {
    if (_detectionTimer?.isActive ?? false) {
      debugPrint("[HomeScreen] Stopping detection timer...");
      _detectionTimer!.cancel(); _detectionTimer = null;
      if (mounted && _isProcessingImage) setState(() => _isProcessingImage = false);
    }
  }

  void _performPeriodicDetection() async {
    final currentController = _cameraController;
    if (!mounted || currentController == null || !currentController.value.isInitialized || currentController.value.isTakingPicture || _isMainCameraInitializing || _isProcessingImage || !_webSocketService.isConnected || _features.isEmpty) {
      return;
    }

    final currentFeatureId = _features[_currentPage.clamp(0, _features.length - 1)].id;
    bool isFocusDetection = _isFocusModeActive && _focusedObject != null && currentFeatureId == focusModeFeature.id;
    bool isNormalObjectDetection = currentFeatureId == objectDetectionFeature.id;
    bool isHazardDetectionOnPage = currentFeatureId == hazardDetectionFeature.id;

    String detectionTypeToSend; String? focusObjectToSend; String? featureRequesting;

    if (isFocusDetection) {
      detectionTypeToSend = 'focus_detection'; // Backend expects this for focus
      focusObjectToSend = _focusedObject;
      featureRequesting = focusModeFeature.id;
    } else if (isNormalObjectDetection || isHazardDetectionOnPage) {
      detectionTypeToSend = objectDetectionFeature.id; // Send as 'object_detection' for both
      featureRequesting = currentFeatureId;
    } else {
      _stopDetectionTimer(); return;
    }

    if (!_cameraControllerCheck(showError: false)) return;

    try {
      if (!mounted || _cameraController != currentController || !_cameraController!.value.isInitialized) {
        if (mounted && _isProcessingImage) setState(() => _isProcessingImage = false); return;
      }
      if (mounted) setState(() => _isProcessingImage = true); else return;
      _lastRequestedFeatureId = featureRequesting;
      debugPrint("[Detection] Taking picture for feature: $featureRequesting (Focus Object: $focusObjectToSend)");

      final XFile imageFile = await currentController.takePicture();
      _webSocketService.sendImageForProcessing(
          imageFile: imageFile, processingType: detectionTypeToSend, focusObject: focusObjectToSend
      );
    } catch (e, stackTrace) {
      if (e is CameraException && e.code == 'disposed') {
        debugPrint("[Detection] Error: Used disposed CameraController. Ignoring.");
      } else {
        _handleCaptureError(e, stackTrace, featureRequesting);
      }
      _lastRequestedFeatureId = null;
      if (mounted) setState(() => _isProcessingImage = false);
    }
  }

  // For Scene, Text, and SuperVision
  void _performManualDetection(String featureId) async {
    if (featureId == barcodeScannerFeature.id || // Barcode handles its own camera
        featureId == objectDetectionFeature.id || // Realtime
        featureId == hazardDetectionFeature.id ||   // Realtime
        featureId == focusModeFeature.id) {         // Realtime after object select
        return;
    }
    debugPrint('Manual detection triggered for feature: $featureId');

    if (!_cameraControllerCheck(showError: true)) {
      debugPrint('Manual detection aborted: Camera check failed for $featureId.');
      return;
    }
    if ((_isProcessingImage && featureId != supervisionFeature.id) ||
        (_isSupervisionProcessing && featureId == supervisionFeature.id) ||
        !_webSocketService.isConnected) {
      debugPrint('Manual detection aborted for $featureId: Already processing or WS disconnected.');
      _showStatusMessage("Processing or disconnected", isError: true, durationSeconds: 2);
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
            supervisionRequestType: 'llm_route' // Specific for SuperVision LLM routing
            );
      } else { // Scene or Text
        _webSocketService.sendImageForProcessing(
            imageFile: imageFile,
            processingType: featureId, // 'scene_detection' or 'text_detection'
            languageCode: (featureId == textDetectionFeature.id) ? _selectedOcrLanguage : null
            );
      }
    } catch (e, stackTrace) {
      _handleCaptureError(e, stackTrace, featureId);
      _lastRequestedFeatureId = null;
      if (mounted) {
        if (featureId == supervisionFeature.id) setState(() => _isSupervisionProcessing = false);
        else setState(() => _isProcessingImage = false);
      }
    }
    // _isProcessingImage / _isSupervisionProcessing reset in _handleWebSocketData
  }


  bool _cameraControllerCheck({required bool showError}) {
    final currentFeatureId = _features.isNotEmpty ? _features[_currentPage.clamp(0, _features.length - 1)].id : null;
    if (currentFeatureId == barcodeScannerFeature.id) return false;

    bool isReady = _cameraController != null && _cameraController!.value.isInitialized && !_isMainCameraInitializing;
    if (!isReady) {
      if (!_isMainCameraInitializing && showError) _showStatusMessage("Camera not ready", isError: true);
      if (_cameraController == null && widget.camera != null && !_isMainCameraInitializing && showError) {
        _initializeMainCameraController();
      }
      return false;
    }
    if (_cameraController!.value.isTakingPicture) return false;
    return true;
  }

  void _handleCaptureError(Object e, StackTrace stackTrace, String? featureId) {
    final idForLog = featureId ?? "unknown_feature";
    debugPrint('Capture/Send Error for $idForLog: $e'); debugPrintStack(stackTrace: stackTrace);
    String errorMsg = e is CameraException ? "Capture Error: ${e.description ?? e.code}" : "Processing Error";
    if (mounted) {
      if (_ttsInitialized) _ttsService.stop();
      setState(() {
        if (featureId == objectDetectionFeature.id) _lastObjectResult = "Error";
        else if (featureId == hazardDetectionFeature.id) { _clearHazardAlert(); }
        else if (featureId == focusModeFeature.id) { _stopFocusFeedback(); _focusedObject = null; _isFocusModeActive = false; }
        else if (featureId == supervisionFeature.id) {
            _isSupervisionProcessing = false;
            _supervisionResultType = "supervision_error";
            _supervisionDisplayResult = errorMsg;
            _supervisionHazardName = ""; _supervisionIsHazardActive = false;
        }
        else if (featureId != null && featureId != barcodeScannerFeature.id) _lastSceneTextResult = "Error";
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
    if (!wasAlreadyActive && _ttsInitialized) _ttsService.speak("Hazard detected: ${hazardName.replaceAll('_', ' ')}");
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
    try { await _alertAudioPlayer.play(AssetSource(_alertSoundPath), volume: 1.0); debugPrint("[ALERT] Playing hazard sound."); }
    catch (e) { debugPrint("[ALERT] Error playing hazard sound: $e"); }
  }

  void _updateFocusFeedback() {
    if (!mounted || !_isFocusModeActive) { _stopFocusFeedback(); return; }
    _focusBeepTimer?.cancel();
    if (_currentProximity > 0.05) {
      final double proximityFactor = _currentProximity * _currentProximity;
      int interval = (_focusBeepMaxIntervalMs - (proximityFactor * (_focusBeepMaxIntervalMs - _focusBeepMinIntervalMs))).toInt();
      interval = interval.clamp(_focusBeepMinIntervalMs, _focusBeepMaxIntervalMs);
      debugPrint("[Focus Feedback] Prox: ${_currentProximity.toStringAsFixed(2)}, Interval: $interval ms");
      _focusBeepTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
        if (!mounted || !_isFocusModeActive) { _focusBeepTimer?.cancel(); return; }
        _playBeepSound();
        _triggerVibration(proximity: _currentProximity);
      });
    } else {
      debugPrint("[Focus Feedback] Prox (${_currentProximity.toStringAsFixed(2)}) low. Stopping.");
    }
  }

  void _stopFocusFeedback() {
    _focusBeepTimer?.cancel(); _focusBeepTimer = null;
  }

  Future<void> _playBeepSound() async {
    debugPrint("[Focus Feedback] Playing beep sound...");
    try { await _beepPlayer.play(AssetSource(_beepSoundPath), mode: PlayerMode.lowLatency, volume: 0.8); }
    catch (e) { debugPrint("[Focus Feedback] Error playing beep sound: $e"); }
  }

  Future<void> _triggerVibration({bool isHazard = false, double proximity = 0.0}) async {
    if (!_hasVibrator) return;
    try {
      if (isHazard) {
        Vibration.vibrate(duration: 500, amplitude: 255); debugPrint("[ALERT] Hazard vibration.");
      } else if (_isFocusModeActive && proximity > 0.05) {
        if (_hasAmplitudeControl ?? false) {
          int amplitude = (1 + (proximity * 254)).toInt().clamp(1, 255);
          Vibration.vibrate(duration: 80, amplitude: amplitude);
        } else { Vibration.vibrate(duration: 80); }
      }
    } catch (e) { debugPrint("[Vibration] Error: $e"); }
  }











  // --- Navigation & UI Helpers ---
  void _showStatusMessage(String message, {bool isError = false, int durationSeconds = 3}) {
    if (!mounted) return; debugPrint("[Status] $message ${isError ? '(Error)' : ''}");
    final messenger = ScaffoldMessenger.of(context); messenger.removeCurrentSnackBar();
    messenger.showSnackBar( SnackBar( content: Text(message), backgroundColor: isError ? Colors.redAccent : Colors.grey[800], duration: Duration(seconds: durationSeconds), behavior: SnackBarBehavior.floating, margin: const EdgeInsets.only(bottom: 90.0, left: 15.0, right: 15.0), shape: RoundedRectangleBorder( borderRadius: BorderRadius.circular(10.0), ), ), );
  }
  void _navigateToPage(int pageIndex) {
    if (!mounted || _features.isEmpty) return;
    final targetIndex = pageIndex.clamp(0, _features.length - 1);

    // --- ADD CHECK: Only navigate if target is different from current page ---
    if (targetIndex == _currentPage) {
        debugPrint("Attempted to navigate to the same page ($targetIndex). Skipping.");
        return;
    }
    // --- END CHECK ---

    if (_pageController.hasClients) {
      if (_ttsInitialized) _ttsService.stop();
      debugPrint("Navigating from $_currentPage to page index: $targetIndex (${_features[targetIndex].title})");
      _pageController.animateToPage(
        targetIndex,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
       // IMPORTANT: Do NOT update _currentPage here. Let _onPageChanged handle it
       // when the animation completes or settles.
    }
  }

  Future<void> _navigateToSettingsPage() async {
    if (!mounted) return; debugPrint("Navigating to Settings...");
    if (_speechToText.isListening) await _stopListening();
    if (_ttsInitialized) _ttsService.stop();
    _stopDetectionTimer(); _stopFocusFeedback();
    final currentFeatureId = _features.isNotEmpty ? _features[_currentPage.clamp(0, _features.length - 1)].id : null;
    bool isMainCameraPage = currentFeatureId != barcodeScannerFeature.id;
    if (isMainCameraPage) await _disposeMainCameraController();
    await Navigator.push( context, MaterialPageRoute(builder: (context) => const SettingsScreen()), );
    if (!mounted) return; debugPrint("Returned from Settings.");
    await _loadAndInitializeSettings();
    bool isFocusModeWaitingForObject = _isFocusModeActive && _focusedObject == null;
    if (isMainCameraPage && !isFocusModeWaitingForObject) await _initializeMainCameraController();
    _startDetectionTimerIfNeeded();
  }

  void _showPermissionInstructions() {
    if (!mounted) return; showDialog( context: context, builder: (BuildContext dialogContext) => AlertDialog( title: const Text('Microphone Permission'), content: const Text(
        'Voice control requires microphone access.\nPlease enable the Microphone permission in Settings.',
    ), actions: <Widget>[ TextButton( child: const Text('OK'), onPressed: () => Navigator.of(dialogContext).pop(), ), ], shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15.0)), ), );
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
      if(_currentPage+1 == BarcodeScannerPage){
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
    if (newPageIndex >= _features.length) return; // Should not happen

    // --- CAPTURE PREVIOUS INDEX BEFORE ANY STATE CHANGE (Robustness Improvement) ---
    final int previousPageIndex = _currentPage;
    // --- --- --- --- --- --- --- --- --- --- --- --- ---

    // Prevent redundant calls if the index hasn't actually changed
    if (previousPageIndex == newPageIndex) return;

    // Ensure indices are valid before proceeding
    if (previousPageIndex < 0 || previousPageIndex >= _features.length) {
         debugPrint("[Navigation Error] Invalid previousPageIndex: $previousPageIndex");
         return; // Avoid proceeding with invalid state
    }

    final previousFeature = _features[previousPageIndex];
    final newFeature = _features[newPageIndex];
    debugPrint("[Navigation] Page changed from ${previousFeature.id} (idx $previousPageIndex) to ${newFeature.id} (idx $newPageIndex)");

    // Stop ongoing activities FIRST
    if (_ttsInitialized) _ttsService.stop();
    _stopDetectionTimer();
    _stopFocusFeedback();
    if (previousFeature.id == hazardDetectionFeature.id) _clearHazardAlert();

    bool wasFocusMode = _isFocusModeActive;
    _isFocusModeActive = newFeature.id == focusModeFeature.id;

    // --- UPDATE _currentPage STATE SYNCHRONOUSLY (Robustness Improvement) ---
    _currentPage = newPageIndex;
    // --- --- --- --- --- --- --- --- --- --- --- ---

    // --- Perform setState EARLY (Robustness Improvement / User Preference) ---
    // This triggers the UI rebuild process. Subsequent async operations might complete after this.
    if(mounted) setState(() {}); else return;
    // --- --- --- --- --- --- --- --- --- --- --- ---

    // --- Camera Transitions (Integrating User Logic) ---
    bool isSwitchingToBarcode = newFeature.id == barcodeScannerFeature.id;
    // Focus Initial: Entering focus mode AND object is null
    bool isSwitchingToFocusInitial = _isFocusModeActive && _focusedObject == null && newFeature.id == focusModeFeature.id;
    bool isSwitchingFromBarcode = previousFeature.id == barcodeScannerFeature.id;
    // Switching From Focus: Was focus mode AND (is no longer focus mode OR focus object is now set)
    // Let's stick to the user's simpler definition for now: was focus mode AND is no longer focus mode
    bool isSwitchingFromFocus = wasFocusMode && !_isFocusModeActive;

    debugPrint("[Nav] CamLogic: ToBarcode=$isSwitchingToBarcode, ToFocusInitial=$isSwitchingToFocusInitial, FromBarcode=$isSwitchingFromBarcode, FromFocus=$isSwitchingFromFocus");

    // --- User's TTS Logic for Focus Initial ---
    // This specific block handles the TTS prompt *before* disposal when switching to focus initial state.
    // We keep the `await` on dispose here because the TTS likely needs to happen first.
    if (isSwitchingToFocusInitial) {
        if (_cameraController != null || _isMainCameraInitializing) {
            debugPrint("[Nav] Switching TO initial focus - Speaking TTS then disposing main camera...");
            if(_ttsInitialized) await _ttsService.speak("Object finder. Tap the button, then say the object name."); // Speak first
            await _disposeMainCameraController(); // Then dispose (awaited)
             debugPrint("[Nav] Main camera disposed after TTS for focus.");
        } else {
             // Camera is already null/not initializing, just speak the prompt
             if(_ttsInitialized) await _ttsService.speak("Object finder. Tap the button, then say the object name.");
        }
    }
    // --- End User's TTS Logic ---

    // --- General Disposal Logic (excluding the focus initial case handled above) ---
    // Handles switching TO barcode. We make disposal async here.
    else if (isSwitchingToBarcode) {
         if (_cameraController != null || _isMainCameraInitializing) {
            debugPrint("[Nav] Switching TO barcode - disposing main camera (async)...");
            _disposeMainCameraController(); // Dispose without awaiting
        }
    }
    // --- End General Disposal Logic ---

    // --- Initialization Logic (Including User's Double Init) ---
    // Handles switching FROM barcode or FROM focus mode (when it's not focus initial anymore)
    else if (isSwitchingFromBarcode || isSwitchingFromFocus) {
        bool newPageNeedsCamera = newFeature.id != barcodeScannerFeature.id && !isSwitchingToFocusInitial; // Double check target isn't focus initial
        if (newPageNeedsCamera) {
            debugPrint("[Nav] Switching FROM barcode/focus TO page needing camera (${newFeature.id}) - Applying User's Double Initialization...");
            // --- User's Double Initialization Workaround ---
            await Future.delayed(const Duration(milliseconds: 200));
            _initializeMainCameraController(); // First call
            _initializeMainCameraController(); // Second call
             if(mounted) setState(() {}); // User's explicit setState after double init
             debugPrint("[Nav] Double camera initialization complete.");
             // --- End User's Workaround ---
        }
    }
    // --- End Initialization Logic ---

    // --- Handle transitions between other pages needing camera ---
    else {
        bool newPageNeedsCamera = newFeature.id != barcodeScannerFeature.id && !isSwitchingToFocusInitial;
        // Check if camera is needed AND (it's null OR it's currently initializing - avoid triggering if already good)
        if (newPageNeedsCamera && (_cameraController == null || !_cameraController!.value.isInitialized) && !_isMainCameraInitializing ) {
             debugPrint("[Nav] Other transition: Page ${newFeature.id} needs camera, ensuring it's initialized (async).");
            _initializeMainCameraController(); // Initialize without awaiting
            _initializeMainCameraController(); // Second call
            setState(() {}); // User's explicit setState after double init
           // if(mounted) setState(() {}); // User's explicit setState after double init
        }
    }
    // --- End Camera Transitions ---


    // --- Clear Previous Page Results & Reset State ---
    // It's generally safer to clear state *after* potentially long async operations
    // like camera init/dispose have at least been initiated.
    if (mounted) {
      setState(() {
        _isProcessingImage = false; _lastRequestedFeatureId = null;
        if (previousFeature.id == objectDetectionFeature.id) _lastObjectResult = "";
        // Hazard clear already happened earlier based on feature ID
        else if (previousFeature.id == sceneDetectionFeature.id || previousFeature.id == textDetectionFeature.id) _lastSceneTextResult = "";

        if (previousFeature.id == supervisionFeature.id) {
            _isSupervisionProcessing = false; _supervisionResultType = null;
            _supervisionDisplayResult = ""; _supervisionHazardName = "";
            _supervisionIsHazardActive = false;
        }
        // Only reset Focus state variables if truly LEAVING focus mode.
        // Don't reset if just selecting an object *within* focus mode.
        if (isSwitchingFromFocus) {
            debugPrint("[Nav] Resetting Focus state variables as we are leaving Focus Mode.");
            _focusedObject = null; _isFocusPromptActive = false; _isFocusObjectDetectedInFrame = false;
            _isFocusObjectCentered = false; _currentProximity = 0.0; _announcedFocusFound = false;
        }
      });
    } else { return; }
    // --- End Clear State ---


    // --- Final Page Setup ---
    // Announce New Feature Title (if not focus initial, as that already announced)
    if (_ttsInitialized && !isSwitchingToFocusInitial) {
         _ttsService.speak(newFeature.title);
    }

    // Setup Focus Prompt (if entering focus initial state)
    // Note: TTS prompt was handled earlier in this specific case.
    if (isSwitchingToFocusInitial) {
        if(mounted) {
            setState(() {
                _isFocusPromptActive = true; // Show prompt UI element
                _isFocusObjectDetectedInFrame = false; _isFocusObjectCentered = false;
                _currentProximity = 0.0; _announcedFocusFound = false;
            });
        }
        _stopFocusFeedback(); // Ensure feedback is off initially
        debugPrint("[Focus] Entered Focus Mode Initial State (Object prompt active).");
    }
    // Start Detection Timer if applicable for the new page
    else {
        // Applies to ObjectDetection, HazardDetection, FocusMode (once object selected)
        _startDetectionTimerIfNeeded();
    }
    // --- End Final Page Setup ---
}











  // --- Widget Build Logic ---
  @override
  Widget build(BuildContext context) {
    if (_features.isEmpty) return const Scaffold(backgroundColor: Colors.black, body: Center(child: Text("No features.", style: TextStyle(color: Colors.white))));

    final currentFeature = _features[_currentPage.clamp(0, _features.length - 1)];
    final bool isBarcodePage = currentFeature.id == barcodeScannerFeature.id;
    final bool isFocusModeWaiting = _isFocusModeActive && _focusedObject == null;
    final bool shouldShowMainCamera = !isBarcodePage && !isFocusModeWaiting;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (shouldShowMainCamera)
            _buildCameraDisplay()
          else
            Container(key: ValueKey('placeholder_${currentFeature.id}'), color: Colors.black),

          _buildFeaturePageView(),
          FeatureTitleBanner(title: currentFeature.title, backgroundColor: currentFeature.color),
            // --- Left Navigation Arrow ---
          if (_currentPage >= 0) // Only show if not the first page
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                // Add some padding from the edge
                padding: const EdgeInsets.only(left: 8.0),
                child: IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded, // Or Icons.chevron_left
                    color: Colors.white,
                    size: 48.0, // Adjust size as needed
                  ),
                  onPressed: _navigateToPreviousPage, // Call the helper method
                  tooltip: 'Previous Feature',
                  // Optional: Add background for better visibility
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withOpacity(0.35),
                    padding: const EdgeInsets.all(10.0),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(50)),
                  ),
                ),
              ),
            ),

          // --- Right Navigation Arrow ---
          if (_currentPage <= _features.length - 1) // Only show if not the last page
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                // Add some padding from the edge
                padding: const EdgeInsets.only(right: 8.0),
                child: IconButton(
                  icon: const Icon(
                    Icons.arrow_forward_ios_rounded, // Or Icons.chevron_right
                    color: Colors.white,
                    size: 48.0, // Adjust size as needed
                  ),
                  onPressed: _navigateToNextPage, // Call the helper method
                  tooltip: 'Next Feature',
                  // Optional: Add background for better visibility
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withOpacity(0.35),
                    padding: const EdgeInsets.all(10.0),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(50)),
                  ),
                ),
              ),
            ),
          _buildSettingsButton(),
          _buildMainActionButton(currentFeature),
        ],
      ),
    );
  }

  Widget _buildCameraDisplay() {
    if (_isMainCameraInitializing) {
      return Container(key: const ValueKey('placeholder_initializing'), color: Colors.black, child: const Center(child: CircularProgressIndicator(color: Colors.white)));
    } else if (_cameraController != null && _initializeControllerFuture != null) {
      return FutureBuilder<void>(
          key: _cameraViewKey, future: _initializeControllerFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done) {
              if (_cameraController != null && _cameraController!.value.isInitialized) {
                return CameraViewWidget(cameraController: _cameraController, initializeControllerFuture: _initializeControllerFuture);
              } else { return _buildCameraErrorPlaceholder("Camera failed"); }
            } else { return Container(color: Colors.black, child: const Center(child: CircularProgressIndicator(color: Colors.white))); }
          });
    } else { return _buildCameraErrorPlaceholder("Camera unavailable"); }
  }

  Widget _buildCameraErrorPlaceholder(String message) {
    return Container(key: ValueKey('placeholder_error_$message'), color: Colors.black, child: Center(child: Text(message, style: const TextStyle(color: Colors.red))));
  }

  Widget _buildFeaturePageView() {
    return PageView.builder(
        controller: _pageController,
        itemCount: _features.length,
        physics: const ClampingScrollPhysics(),
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          if (index >= _features.length) return Center(child: Text("Error: Invalid page index $index", style: const TextStyle(color: Colors.red)));
          final feature = _features[index];

          switch (feature.id) {
            case 'barcode_scanner':
              return BarcodeScannerPage(key: const ValueKey('barcodeScanner'), barcodeApiService: _barcodeApiService, ttsService: _ttsService);
            case 'object_detection':
              return ObjectDetectionPage(detectionResult: _lastObjectResult);
            case 'hazard_detection':
              return HazardDetectionPage(detectionResult: _currentDisplayedHazardName, isHazardAlert: _isHazardAlertActive);
            case 'scene_detection':
              return SceneDetectionPage(detectionResult: _lastSceneTextResult);
            case 'text_detection':
              return TextDetectionPage(detectionResult: _lastSceneTextResult);
            case 'focus_mode':
              return FocusModePage(
                  key: const ValueKey('focusMode'),
                  focusedObject: _focusedObject,
                  isObjectDetectedInFrame: _isFocusObjectDetectedInFrame,
                  isObjectCentered: _isFocusObjectCentered,
                  isPrompting: _isFocusPromptActive);
            case 'supervision': // Added SuperVision case
              return SuperVisionPage(
                  key: const ValueKey('supervision'),
                  isLoading: _isSupervisionProcessing,
                  resultType: _supervisionResultType,
                  displayResult: _supervisionDisplayResult,
                  hazardName: _supervisionHazardName,
                  isHazardActive: _supervisionIsHazardActive);
            default:
              return Center(child: Text('Unknown Page: ${feature.id}', style: const TextStyle(color: Colors.white)));
          }
        });
  }

  Widget _buildSettingsButton() {
    return Align(alignment: Alignment.topRight, child: SafeArea(child: Padding(padding: const EdgeInsets.only(top: 10.0, right: 15.0), child: IconButton(icon: const Icon(Icons.settings, color: Colors.white, size: 32.0, shadows: [Shadow(blurRadius: 6.0, color: Colors.black54, offset: Offset(1.0, 1.0))]), onPressed: _navigateToSettingsPage, tooltip: 'Settings'))));
  }

  Widget _buildMainActionButton(FeatureConfig currentFeature) {
    final bool isRealtimeObjectOrHazard = currentFeature.id == objectDetectionFeature.id || currentFeature.id == hazardDetectionFeature.id;
    final bool isBarcodePage = currentFeature.id == barcodeScannerFeature.id;
    final bool isFocusActivePage = currentFeature.id == focusModeFeature.id;
    final bool isSuperVisionPage = currentFeature.id == supervisionFeature.id; // New

    VoidCallback? onTapAction;
    if (isSuperVisionPage) { // SuperVision tap action
        onTapAction = () {
            debugPrint("[Action Button] SuperVision tap - performing LLM analysis.");
            _performManualDetection(supervisionFeature.id); // This calls _performSuperVisionLlmAnalysis
        };
    } else if (isFocusActivePage) { // Focus tap action
        onTapAction = () {
            debugPrint("[Action Button] Focus tap - listening for object.");
            if (!_speechEnabled) { _showStatusMessage('Speech not available', isError: true); _initSpeech(); return; }
            if (_speechToText.isNotListening) _startListening(isForFocusObject: true);
            else _stopListening();
        };
    } else if (!isRealtimeObjectOrHazard && !isBarcodePage) { // Manual Trigger (Scene/Text)
        onTapAction = () {
            debugPrint("[Action Button] Manual detection tap for ${currentFeature.id}");
            _performManualDetection(currentFeature.id);
        };
    }
    // No tap action for realtime object/hazard or barcode.

    VoidCallback onLongPressAction = () {
      debugPrint("[Action Button] Long press - listening for general command.");
      if (!_speechEnabled) { _showStatusMessage('Speech not available', isError: true); _initSpeech(); return; }
      if (_speechToText.isNotListening) _startListening(isForFocusObject: false);
      else _stopListening();
    };

    IconData iconData = Icons.mic_none; // Default for listening
    if (_isListening) iconData = Icons.mic;
    else if (isFocusActivePage) iconData = Icons.filter_center_focus;
    else if (isSuperVisionPage) iconData = Icons.auto_awesome; // Icon for SuperVision
    else if (!isRealtimeObjectOrHazard && !isBarcodePage) iconData = Icons.play_arrow; // Manual trigger
    else iconData = Icons.camera_alt; // Default for object/hazard pages when not listening

    return ActionButton(
        onTap: onTapAction,
        onLongPress: onLongPressAction,
        isListening: _isListening,
        color: currentFeature.color,
        iconOverride: iconData);
  }
}