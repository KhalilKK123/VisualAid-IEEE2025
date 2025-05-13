// lib/features/supervision/presentation/pages/supervision_page.dart
import 'package:flutter/material.dart';

class SuperVisionPage extends StatelessWidget {
  final bool isLoading;
  final String?
      resultType; // The ID ('object_detection', 'scene_detection', etc.)
  final String displayResult; // The main result string
  final String
      hazardName; // Specific hazard name if type is 'hazard_detection' or if found during 'object_detection'
  final bool isHazardActive; // Specific hazard active state

  const SuperVisionPage({
    Key? key,
    required this.isLoading,
    required this.resultType,
    required this.displayResult,
    required this.hazardName,
    required this.isHazardActive,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    debugPrint(
        "[SuperVisionPage Build] isLoading: $isLoading, resultType: $resultType, displayResult: '$displayResult', hazardName: '$hazardName', isHazardActive: $isHazardActive");

    return Container(
      // color: Colors.black.withOpacity(0.6),
      alignment: Alignment.center,
      padding: const EdgeInsets.only(
          top: 100.0, bottom: 100.0, left: 20.0, right: 20.0),
      child: Center(
        child: isLoading
            ? const CircularProgressIndicator(color: Colors.white)
            : _buildResultContent(context),
      ),
    );
  }

  Widget _buildResultContent(BuildContext context) {
    if (resultType == null || displayResult.isEmpty && hazardName.isEmpty) {
      return _buildPlaceholderText("Tap button to smart analyze");
    }

    // Display based on the type determined by the LLM
    switch (resultType) {
      case 'object_detection':
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildStyledText(displayResult, fontSize: 20),
            if (hazardName.isNotEmpty) ...[
              const SizedBox(height: 15),
              _buildHazardSection(hazardName, isHazardActive),
            ]
          ],
        );

      case 'hazard_detection':
        return _buildHazardSection(displayResult, isHazardActive);

      case 'scene_detection':
        return _buildStyledText(displayResult.replaceAll('_', ' '));

      case 'text_detection':
        return _buildStyledText(displayResult, fontSize: 18);

      case 'currency_detection':
        return _buildStyledText(displayResult);

      case 'supervision_error': // Handle specific error type from backend/home_screen
        return _buildStyledText(
            displayResult.isNotEmpty
                ? displayResult
                : "SuperVision analysis failed.",
            isError: true);

      default:
        return _buildStyledText(
            displayResult.isNotEmpty ? displayResult : "Analysis complete",
            isError: true);
    }
  }

  Widget _buildStyledText(String text,
      {double fontSize = 24, bool isError = false}) {
    return Text(
      text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.bold,
        color: isError ? Colors.redAccent : Colors.white,
        shadows: const [
          Shadow(
            blurRadius: 8.0,
            color: Colors.black87,
            offset: Offset(2.0, 2.0),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildPlaceholderText(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w500,
        color: Colors.white,
      ),
      textAlign: TextAlign.center,
    );
  }

  // Specific section for displaying hazard info (similar to HazardDetectionPage concept)
  Widget _buildHazardSection(String hazardText, bool isActive) {
    // Use displayResult passed in if type was hazard_detection, otherwise use hazardName found during object detection
    final String displayText = hazardText.isNotEmpty
        ? hazardText.replaceAll('_', ' ')
        : "No hazards detected"; // This fallback might not be shown if isActive requires hazardText to be non-empty
    final Color color = isActive
        ? Colors.yellowAccent
        : Colors
            .orangeAccent; // Keep orange even if not "fully active" from a global alert but still a hazard
    final FontWeight weight = isActive ? FontWeight.bold : FontWeight.bold;
    final double size = isActive ? 26 : 24;

    return Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.red.withOpacity(0.3)
              : Colors.orange.withOpacity(
                  0.2), // More distinct background for hazard section
          borderRadius: BorderRadius.circular(10.0),
          border: Border.all(
            color: color, // Use yellow or orange for border
            width: 2.0,
          ),
          boxShadow: isActive // Only show prominent shadow if globally active
              ? [
                  BoxShadow(
                    color: color.withOpacity(0.5),
                    blurRadius: 10.0,
                    spreadRadius: 2.0,
                  )
                ]
              : [
                  // Subtle shadow if just a listed hazard
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 5.0,
                    spreadRadius: 1.0,
                  )
                ],
        ),
        child: Center(
          child: Padding(
            padding:
                const EdgeInsets.only(top: 10, bottom: 10), // Adjusted padding
            child: Column(
              // Changed from top:200 to be more dynamic
              mainAxisSize: MainAxisSize.min, // Make column take minimum space
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: color,
                  size: size + 20, // Slightly smaller icon
                ),
                const SizedBox(height: 8),
                Text(
                  displayText.toUpperCase(), // Uppercase for emphasis
                  style: TextStyle(
                    fontSize: size,
                    fontWeight: weight,
                    color: Colors.white, // Keep text white for contrast
                    shadows: const [
                      Shadow(
                        blurRadius: 6.0,
                        color: Colors.black87,
                        offset: Offset(1.5, 1.5),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ));
  }
}
