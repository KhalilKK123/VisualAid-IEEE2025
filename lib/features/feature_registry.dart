import 'package:flutter/material.dart';
import '../core/models/feature_config.dart';

const FeatureConfig supervisionFeature = FeatureConfig(
  id: 'supervision',
  title: 'SuperVision',
  color: Colors.purple, // Choose a distinct color
  voiceCommandKeywords: [
    'page 1',
    'first page',
    'super vision',
    'supervision',
    'analyze all',
    'everything'
  ],
  pageBuilder: _buildSupervisionPage,
);

const FeatureConfig objectDetectionFeature = FeatureConfig(
  id: 'object_detection',
  title: 'Object Detection',
  color: Colors.blue,
  voiceCommandKeywords: [
    'page 2',
    'second page',
    'object detection',
    'objects',
    'object'
  ],
  pageBuilder: _buildObjectDetectionPage,
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
    'hazard detection'
  ],
  pageBuilder: _buildHazardDetectionPage,
);

const FeatureConfig sceneDetectionFeature = FeatureConfig(
  id: 'scene_detection',
  title: 'Scene Detection',
  color: Colors.green,
  voiceCommandKeywords: [
    'page 4',
    'fourth page',
    'scene detection',
    'scene',
    'room'
  ],
  pageBuilder: _buildSceneDetectionPage,
);

const FeatureConfig textDetectionFeature = FeatureConfig(
  id: 'text_detection',
  title: 'Text Detection',
  color: Colors.red,
  voiceCommandKeywords: [
    'page 5',
    'fifth page',
    'text detection',
    'text',
    'read'
  ],
  pageBuilder: _buildTextDetectionPage,
);

const FeatureConfig barcodeScannerFeature = FeatureConfig(
  id: 'barcode_scanner',
  title: 'Barcode Scanner',
  color: Colors.teal,
  voiceCommandKeywords: [
    'page 6',
    'sixth page',
    'barcode',
    'scan code',
    'scanner'
  ],
  pageBuilder: _buildBarcodeScannerPage,
);

final List<FeatureConfig> availableFeatures = [
  supervisionFeature,
  objectDetectionFeature,
  hazardDetectionFeature,
  sceneDetectionFeature,
  textDetectionFeature,
  barcodeScannerFeature,
];

Widget _buildSupervisionPage(BuildContext context) {
  return const Placeholder();
}

Widget _buildObjectDetectionPage(BuildContext context) {
  return const Placeholder();
}

Widget _buildHazardDetectionPage(BuildContext context) {
  return const Placeholder();
}

Widget _buildSceneDetectionPage(BuildContext context) {
  return const Placeholder();
}

Widget _buildTextDetectionPage(BuildContext context) {
  return const Placeholder();
}

Widget _buildBarcodeScannerPage(BuildContext context) {
  return const Placeholder();
}
