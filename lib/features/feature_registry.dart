import 'package:flutter/material.dart';
import '../core/models/feature_config.dart';



// --- Feature Definitions ---

const FeatureConfig supervisionFeature = FeatureConfig(
  id: 'supervision',
  title: 'SuperVision',
  color: Colors.purple, // Distinct color
  voiceCommandKeywords: [
    'page 1', 'first page', 'super vision', 'supervision', 
    'analyze all', 'smart analyze', 'everything'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig objectDetectionFeature = FeatureConfig(
  id: 'object_detection',
  title: 'Object Detection',
  color: Colors.blue,
  voiceCommandKeywords: [
    'page 2', 'second page', 'object detection', 
    'detect object', 'objects', 'object'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig hazardDetectionFeature = FeatureConfig(
  id: 'hazard_detection',
  title: 'Hazard Detection',
  color: Colors.orangeAccent,
  voiceCommandKeywords: [
    'page 3', 'third page', 'hazard', 'danger', 
    'alert', 'hazards', 'hazard detection'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);


const FeatureConfig focusModeFeature = FeatureConfig(
  id: 'focus_mode',
  title: 'Object Finder',
  color: Colors.deepPurpleAccent, 
  voiceCommandKeywords: [
    'page 4', 'fourth page', 'focus mode', 'focus', 
    'find object', 'find', 'locate', 'object finder'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig sceneDetectionFeature = FeatureConfig(
  id: 'scene_detection',
  title: 'Scene Description',
  color: Colors.green,
  voiceCommandKeywords: [
    'page 5', 'fifth page', 'scene detection', 
    'describe scene', 'scene', 'room'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig textDetectionFeature = FeatureConfig(
  id: 'text_detection',
  title: 'Text Recognition',
  color: Colors.red,
  voiceCommandKeywords: [
    'page 6', 'sixth page', 'text detection', 
    'read text', 'text', 'read'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);

const FeatureConfig barcodeScannerFeature = FeatureConfig(
  id: 'barcode_scanner',
  title: 'Barcode Scanner',
  color: Colors.teal,
  voiceCommandKeywords: [
    'page 7', 'seventh page', 'barcode', 
    'scan code', 'scanner', 'scan barcode'
  ],
  pageBuilder: _buildPlaceholderPage, // Placeholder
);


// --- List of Available Features (Order matters for page index in PageView) ---

final List<FeatureConfig> availableFeatures = [
  supervisionFeature,       // Index 0 
  objectDetectionFeature,   // Index 1
  hazardDetectionFeature,   // Index 2
  focusModeFeature,         // Index 3 
  sceneDetectionFeature,    // Index 4
  textDetectionFeature,     // Index 5
  barcodeScannerFeature,    // Index 6
];


// --- Placeholder Builder Function ---
// Since pages are now built conditionally in HomeScreen's PageView builder,
// these pageBuilder functions in FeatureConfig are primarily for completeness
// or if used by other parts of the app. A simple placeholder is sufficient.
Widget _buildPlaceholderPage(BuildContext context) {
  // This function is less relevant now as HomeScreen handles page creation.
  // Returning a simple placeholder.
  return const Center(child: Text("Loading feature...", style: TextStyle(color: Colors.white)));
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
Widget _buildBarcodeScannerPage(BuildContext context) => const Placeholder();