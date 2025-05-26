import 'package:flutter/material.dart';
import '../core/models/feature_config.dart';

// --- Feature Definitions ---

const FeatureConfig supervisionFeature = FeatureConfig(
  id: 'supervision',
  title: 'SuperVision',
  color: Colors.purple, // Distinct color
  voiceCommandKeywords: [
    'page 1',
    'first page',
    'super vision',
    'supervision',
    'analyze all',
    'smart analyze',
    'everything',
    'look at everything',
    'tell me everything',
    'comprehensive scan',
    'full analysis',
    'general mode',
    'overview',
    'what do you see',
    'start default mode'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig objectDetectionFeature = FeatureConfig(
  id: 'object_detection',
  title: 'Object Detection',
  color: Colors.blue,
  voiceCommandKeywords: [
    'page 2',
    'second page',
    'object detection',
    'detect object',
    'objects',
    'object',
    'identify objects',
    'what are these objects',
    'find objects',
    'recognize objects',
    'list objects',
    'what is this',
    'object identifier',
    'tell me what is in front of me'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig hazardDetectionFeature = FeatureConfig(
  id: 'hazard_detection',
  title: 'Hazard Detection',
  color: Colors.orangeAccent,
  voiceCommandKeywords: [
    'page 3',
    'third page',
    'hazard',
    'danger',
    'alert',
    'hazards',
    'hazard detection',
    'detect danger',
    'scan for hazards',
    'look for obstacles',
    'is it safe',
    'safety check',
    'warn me',
    'check for dangers',
    'obstacle detection',
    'alert me to danger'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig focusModeFeature = FeatureConfig(
  id: 'focus_mode',
  title: 'Metal Detector',
  color: Colors.deepPurpleAccent,
  voiceCommandKeywords: [
    'page 4',
    'fourth page',
    'focus mode',
    'focus',
    'find object',
    'find',
    'locate',
    'object finder',
    'Metal Detection',
    'metal detector',
    'metal',
    'search for',
    'pinpoint',
    'where is',
    'item finder',
    'specific object'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig sceneDetectionFeature = FeatureConfig(
  id: 'scene_detection',
  title: 'Scene Description',
  color: Colors.green,
  voiceCommandKeywords: [
    'page 5',
    'fifth page',
    'scene detection',
    'describe scene',
    'scene',
    'room',
    'describe my surroundings',
    'what does it look like here',
    'tell me about this place',
    'environment description',
    'describe the environment',
    'where am I',
    'scene recognition',
    'explain what you see'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig textDetectionFeature = FeatureConfig(
  id: 'text_detection',
  title: 'Text Recognition',
  color: Colors.red,
  voiceCommandKeywords: [
    'page 6',
    'sixth page',
    'text detection',
    'read text',
    'text',
    'read',
    'read this for me',
    'what does this say',
    'scan text',
    'recognize text',
    'text reader',
    'read aloud',
    'OCR',
    'read the sign',
    'read document'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig currencyDetectionFeature = FeatureConfig(
  id: 'currency_detection',
  title: 'Currency Detection',
  color: Color.fromARGB(255, 206, 136, 159),
  voiceCommandKeywords: [
    'page 7',
    'seventh page',
    'currency detection',
    'currency',
    'money',
    'scan currency',
    'identify money',
    'what bill is this',
    'recognize currency',
    'money identifier',
    'check money',
    'scan bill',
    'cash',
    'banknote',
    'how much is this',
    'how much money is this'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig barcodeScannerFeature = FeatureConfig(
  id: 'barcode_scanner',
  title: 'Barcode Scanner',
  color: Colors.teal,
  voiceCommandKeywords: [
    'page 8',
    'eighth page',
    'barcode',
    'scan code',
    'scanner',
    'scan barcode',
    'scan product',
    'scan item',
    'scan package'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

// --- List of Available Features (Order matters for page index in PageView) ---

final List<FeatureConfig> availableFeatures = [
  supervisionFeature, // Index 0
  objectDetectionFeature, // Index 1
  hazardDetectionFeature, // Index 2
  focusModeFeature, // Index 3
  sceneDetectionFeature, // Index 4
  textDetectionFeature, // Index 5
  currencyDetectionFeature, // Index 6 (new and added by me)
  barcodeScannerFeature, // Index 7 (former index 6)
];

// --- Placeholder Builder Function ---
// Since pages are now built conditionally in HomeScreen's PageView builder,
// these pageBuilder functions in FeatureConfig are primarily for completeness
// or if used by other parts of the app. A simple placeholder is sufficient.
Widget _buildPlaceholderPage(BuildContext context) {
  // This function is less relevant now as HomeScreen handles page creation.
  // Returning a simple placeholder.
  return const Center(
      child: Text("Loading feature...", style: TextStyle(color: Colors.white)));
}

// Specific build functions are not strictly necessary here if HomeScreen's PageView.builder
// directly instantiates the correct page widget based on feature.id.
// Keeping them as simple placeholders for consistency or potential future use.
Widget _buildSupervisionPage(BuildContext context) => const Placeholder();
Widget _buildObjectDetectionPage(BuildContext context) => const Placeholder();
Widget _buildHazardDetectionPage(BuildContext context) => const Placeholder();
Widget _buildFocusModePage(BuildContext context) => const Placeholder();
Widget _buildSceneDetectionPage(BuildContext context) => const Placeholder();
Widget _buildTextDetectionPage(BuildContext context) => const Placeholder();
Widget _buildCurrencyDetectionPage(BuildContext context) => const Placeholder();
Widget _buildBarcodeScannerPage(BuildContext context) => const Placeholder();
