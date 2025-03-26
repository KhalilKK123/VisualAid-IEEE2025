// BSD 3-Clause License

// Copyright (c) 2022, Julian Steenbakker
// All rights reserved.

// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:

// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.

// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.

// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.

// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:visual_aid_ui/backend_conn.dart';
import 'package:visual_aid_ui/barcode_api.dart';
import 'package:visual_aid_ui/tts.dart';

class BarcodeScannerScreen extends StatefulWidget {
  final Backend backend;
  final TTS tts;
  const BarcodeScannerScreen({
    super.key,
    required this.backend,
    required this.tts,
  });

  @override
  State<BarcodeScannerScreen> createState() =>
      _BarcodeScannerScreenState(backend: backend, tts: tts);
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final Backend backend;
  final TTS tts;

  _BarcodeScannerScreenState({required this.backend, required this.tts});

  Barcode? _barcode;
  String? output;

  @override
  void initState() {
    tts.initTts();
    super.initState();
  }

  Widget _buildBarcode(String? output) {
    if (output == null) {
      return const Text(
        'Scan something!',
        overflow: TextOverflow.fade,
        style: TextStyle(color: Colors.white),
      );
    }

    return Text(
      output,
      overflow: TextOverflow.fade,
      style: const TextStyle(color: Colors.white),
    );
  }

  void _handleBarcode(BarcodeCapture barcodes) async {
    var temp;
    if (mounted) {
      if (barcodes.barcodes.firstOrNull != _barcode) {
        _barcode = barcodes.barcodes.firstOrNull;
        temp = await connectToBarcodeApi(
          barcodes.barcodes.firstOrNull?.displayValue,
        );
        print("YOOOOOOOOOOOOOOO");
        setState(() {
          output = temp;
          tts.speak(output);
        });
      }
    }
  }

  Future<String?> connectToBarcodeApi(String? upc) async {
    return await BarcodeApi().getFoodItemByUPC(upc!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: _handleBarcode,
            controller: MobileScannerController(detectionTimeoutMs: 2000),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              alignment: Alignment.bottomCenter,
              height: 100,
              color: const Color.fromRGBO(0, 0, 0, 0.4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(child: Center(child: _buildBarcode(output))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    tts.stop();
    super.dispose();
  }
}
