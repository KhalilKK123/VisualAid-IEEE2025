import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../../core/services/barcode_api_service.dart';
import '../../../../core/services/tts_service.dart';

class BarcodeScanningPage extends StatefulWidget {
  final TtsService ttsService;

  const BarcodeScanningPage({
    super.key,
    required this.ttsService,
  });

  @override
  State<BarcodeScanningPage> createState() => _BarcodeScanningPageState();
}

class _BarcodeScanningPageState extends State<BarcodeScanningPage> {
  final BarcodeApiService _barcodeApiService = BarcodeApiService();
  MobileScannerController? _scannerController;

  String _productInfo = 'Point camera at a barcode';
  String _lastScannedValue = '';
  bool _isProcessing = false;
  Timer? _resetScanTimer;

  @override
  void initState() {
    super.initState();
    _initializeScanner();
  }

  void _initializeScanner() {
    if (!mounted) return;
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
      detectionTimeoutMs: 2000,
    );
    debugPrint("[BarcodeScanningPage] MobileScannerController initialized.");
    widget.ttsService.speak(_productInfo);
  }

  @override
  void dispose() {
    debugPrint("[BarcodeScanningPage] Disposing...");
    _resetScanTimer?.cancel();
    _scannerController?.dispose();
    widget.ttsService.stop();
    super.dispose();
    debugPrint("[BarcodeScanningPage] Disposed.");
  }

  void _handleBarcode(BarcodeCapture capture) async {
    if (!mounted || _isProcessing) return;

    final scannedBarcode = capture.barcodes.firstOrNull;
    if (scannedBarcode == null || scannedBarcode.rawValue == null) return;

    final currentValue = scannedBarcode.rawValue!;
    if (currentValue.isEmpty || currentValue == _lastScannedValue) {
      return;
    }

    debugPrint('[BarcodeScanningPage] Scanned Barcode: $currentValue');
    _lastScannedValue = currentValue;
    _resetScanTimer?.cancel();

    setState(() {
      _isProcessing = true;
      _productInfo = 'Looking up barcode...';
    });
    widget.ttsService.speak(_productInfo);

    final result = await _barcodeApiService.getProductInfo(currentValue);

    if (mounted) {
      setState(() {
        _productInfo = result;
        _isProcessing = false;
      });
      widget.ttsService.speak(_productInfo);

      _resetScanTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) {
          debugPrint(
              '[BarcodeScanningPage] Resetting last scanned value after 5 seconds.');
          _lastScannedValue = '';
          setState(() {
            _productInfo = 'Point camera at a barcode';
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_scannerController == null) {
      return Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text("Initializing Scanner...",
                    style: TextStyle(color: Colors.white)),
              ],
            ),
          ));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: _handleBarcode,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              alignment: Alignment.center,
              height: 120,
              color: Colors.black.withOpacity(0.6),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isProcessing)
                    const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  if (!_isProcessing)
                    Text(
                      _productInfo,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        shadows: [
                          Shadow(
                            blurRadius: 4.0,
                            color: Colors.black54,
                            offset: Offset(1.0, 1.0),
                          ),
                        ],
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ),
          // Optional: Add Scanner Overlay (like a viewfinder rectangle)
          // Center(
          //   child: Container(
          //     width: MediaQuery.of(context).size.width * 0.7,
          //     height: 200,
          //     decoration: BoxDecoration(
          //       border: Border.all(color: Colors.red, width: 2),
          //       borderRadius: BorderRadius.circular(12),
          //     ),
          //   ),
          // ),
        ],
      ),
    );
  }
}
