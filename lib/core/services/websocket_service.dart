// lib/core/services/websocket_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class WebSocketService {
  // Ensure this URL points to your backend server IP/domain and port
  final String _serverUrl = 'http://xyz:5000'; // Using server URL
  // Example: final String _serverUrl = 'http://your-backend-domain.com';

  io.Socket? _socket;
  final StreamController<Map<String, dynamic>> _responseController =
      StreamController<Map<String, dynamic>>.broadcast();
  Timer? _connectionRetryTimer;
  bool _isConnected = false;
  bool _isConnecting = false;
  int _retrySeconds = 5; // Initial retry delay

  Stream<Map<String, dynamic>> get responseStream => _responseController.stream;
  bool get isConnected => _isConnected;

  void connect() {
    if (_isConnecting || _isConnected) {
      debugPrint('[WebSocketService] Connect called but already connecting/connected.');
      return;
    }

    _isConnecting = true;
    _closeExistingSocket(); 
    _cancelRetryTimer();
    debugPrint('[WebSocketService] Attempting Socket.IO connection to: $_serverUrl');

    try {
      _socket = io.io(_serverUrl, io.OptionBuilder()
          .setTransports(['websocket']) 
          .disableAutoConnect()        
          .enableReconnection()        
          .setTimeout(10000)           
          .setReconnectionDelay(2000)  
          .setReconnectionDelayMax(10000)
          .setRandomizationFactor(0.5) 
          .build());

      // --- Connection Event Handlers ---
      _socket!.onConnect((_) {
        debugPrint('[WebSocketService] Socket.IO connected: ID ${_socket?.id}');
        _isConnected = true;
        _isConnecting = false;
        _retrySeconds = 5; 
        _cancelRetryTimer(); 
        
        _responseController.add({'event': 'connect', 'result': {'status': 'connected', 'id': _socket?.id}});
      });

      _socket!.onConnectError((data) {
        debugPrint('[WebSocketService] Socket.IO Connection Error: $data');
        _isConnected = false;
        _isConnecting = false;
        
        _responseController.add({'event': 'connect_error', 'message': 'Connection Error: ${data ?? "Unknown"}'});
        _scheduleReconnect(isInitialFailure: true); 
      });

      _socket!.on('connect_timeout', (data) {
         debugPrint('[WebSocketService] Socket.IO Connection Timeout: $data');
         _isConnected = false;
         _isConnecting = false;
         _responseController.add({'event': 'connect_timeout', 'message': 'Connection Timeout'});
         _scheduleReconnect(isInitialFailure: true);
      });

      _socket!.onError((data) {
        debugPrint('[WebSocketService] Socket.IO Error: $data');
        _responseController.add({'event': 'error', 'message': 'Socket Error: ${data ?? "Unknown"}'});
         if (!_isConnected && !_isConnecting && _connectionRetryTimer == null) {
            debugPrint('[WebSocketService] Scheduling reconnect due to onError while disconnected.');
            _scheduleReconnect();
         }
      });

      _socket!.onDisconnect((reason) {
        debugPrint('[WebSocketService] Socket.IO disconnected: $reason');
         final wasConnected = _isConnected;
         _isConnected = false;
         _isConnecting = false;
         if (reason != 'io client disconnect' && wasConnected) {
           _responseController.add({'event': 'disconnect', 'message': 'Disconnected: ${reason ?? "Unknown reason"}'});
         }
         if (reason != 'io client disconnect') {
           _scheduleReconnect();
         } else {
             debugPrint('[WebSocketService] Manual disconnect requested, not scheduling reconnect.');
         }
      });
      // --- --- --- --- --- --- --- ---

      // --- Main Response Handler (Simplified for integrated backend) ---
      _socket!.on('response', (responseData) {
        // The integrated backend now sends the payload directly as a Map.
        // For SuperVision: {'result': 'string', 'feature_id': '...', 'is_from_supervision_llm': true}
        // For Direct/Focus: {'result': {'status':'ok', ...}}
        // debugPrint('[WebSocketService] Received "response" event data: $responseData');
        try {
          if (responseData is Map<String, dynamic>) {
            _responseController.add(responseData); // Pass the whole map directly to HomeScreen
          } else if (responseData != null) {
            debugPrint('[WebSocketService] Received unexpected non-map data on "response": $responseData');
            _responseController.add({
              'event': 'error', // Or a custom event type like 'format_error'
              'message': 'Received non-map data from server.',
              'original_data': responseData.toString()
            });
          } else {
            debugPrint('[WebSocketService] Received null data on "response" event.');
             _responseController.add({
              'event': 'error',
              'message': 'Received null data from server.'
            });
          }
        } catch (e, stackTrace) {
          debugPrint('[WebSocketService] Error processing "response" event data: $e');
          debugPrintStack(stackTrace: stackTrace);
          // Emit an error that HomeScreen can understand as a processing issue on the client side
          _responseController.add({'event': 'error', 'message': 'Client-side Data Processing Error: $e'});
        }
      });
      // --- --- --- --- --- --- --- ---

      // --- Reconnection Event Handlers (for logging/debugging) ---
      _socket!.on('reconnecting', (attempt) => debugPrint('[WebSocketService] Reconnecting attempt $attempt...'));
      _socket!.on('reconnect', (attempt) {
          debugPrint('[WebSocketService] Reconnected on attempt $attempt');
      });
      _socket!.on('reconnect_attempt', (attempt) { debugPrint('[WebSocketService] Reconnect attempt $attempt'); });
      _socket!.on('reconnect_error', (data) => debugPrint('[WebSocketService] Reconnect error: $data'));
      _socket!.on('reconnect_failed', (data) {
         debugPrint('[WebSocketService] Reconnect failed permanently (after max attempts): $data');
          _responseController.add({'event': 'reconnect_failed', 'message': 'Reconnect Failed Permanently'});
      });
      // --- --- --- --- --- --- --- ---

      _socket!.connect();

    } catch (e, stackTrace) {
      debugPrint('[WebSocketService] Error initializing Socket.IO client: $e');
      debugPrintStack(stackTrace: stackTrace);
      _isConnecting = false;
      _isConnected = false;
      _responseController.add({'event': 'error', 'message': 'Initialization Error: ${e.toString()}'});
      _scheduleReconnect(isInitialFailure: true); 
    }
  }

  /// Sends an image to the backend for processing.
  ///
  /// [imageFile]: The image captured by the camera.
  /// [processingType]: The type of processing requested (e.g., 'object_detection', 'scene_detection', 'text_detection', 'focus_detection', 'supervision').
  /// [languageCode]: Optional language code for 'text_detection'.
  /// [focusObject]: Optional object name for 'focus_detection'.
  /// [supervisionRequestType]: Optional, for 'supervision' type, e.g., 'llm_route'.
  void sendImageForProcessing({
    required XFile imageFile,
    required String processingType,
    String? languageCode,
    String? focusObject,
    String? supervisionRequestType, // New parameter for SuperVision
  }) async {
    if (!isConnected || _socket == null) {
      debugPrint('[WebSocketService] Cannot send image for $processingType: Not connected.');
      _responseController.add({'event': 'error', 'message': 'Cannot send: Not connected'});
      return;
    }

    String logDetails = "";
    if (processingType == 'text_detection' && languageCode != null) logDetails += "(Lang: $languageCode)";
    if (processingType == 'focus_detection' && focusObject != null) logDetails += " (Focus: $focusObject)";
    if (processingType == 'supervision' && supervisionRequestType != null) logDetails += " (Request: $supervisionRequestType)";
    debugPrint('[WebSocketService] Preparing image for $processingType $logDetails...');

    try {
      final bytes = await imageFile.readAsBytes();
      final base64Image = base64Encode(bytes);

      final payload = <String, dynamic>{
        'type': processingType, // This is the main 'type' the backend uses for routing
        'image': base64Image,
        // Conditionally add language for text_detection
        if (processingType == 'text_detection' && languageCode != null)
          'language': languageCode,
        // Conditionally add focus object for focus_detection
        if (processingType == 'focus_detection' && focusObject != null)
          'focus_object': focusObject,
        // Conditionally add supervision_request_type for supervision
        if (processingType == 'supervision' && supervisionRequestType != null)
          'request_type': supervisionRequestType, // Backend expects 'request_type'
      };

      final payloadSizeKB = (json.encode(payload).length / 1024).toStringAsFixed(1);
      debugPrint('[WebSocketService] Sending "message" event ($payloadSizeKB kB) with payload keys: ${payload.keys}');

      _socket!.emitWithAck('message', payload, ack: (ackData) {
         debugPrint('[WebSocketService] Server acknowledged "message" event. Ack data: $ackData');
      });

    } catch (e, stackTrace) {
      debugPrint('[WebSocketService] Error preparing/sending image for $processingType: $e');
      debugPrintStack(stackTrace: stackTrace, label: '[WebSocketService] Send Image Error StackTrace');
      _responseController.add({'event': 'error', 'message': 'Image send failed: ${e.toString()}'});
    }
  }

  void _scheduleReconnect({bool isInitialFailure = false}) {
    if (_connectionRetryTimer?.isActive ?? false) {
      return; 
    }
    _closeExistingSocket();

    final currentDelay = isInitialFailure ? 3 : _retrySeconds;
    debugPrint('[WebSocketService] Scheduling Socket.IO reconnect attempt in $currentDelay seconds...');

    _connectionRetryTimer = Timer(Duration(seconds: currentDelay), () {
      if (!isInitialFailure) {
        _retrySeconds = (_retrySeconds * 1.5).clamp(5, 60).toInt();
      }
      connect(); 
    });
  }

  void _cancelRetryTimer() {
    _connectionRetryTimer?.cancel();
    _connectionRetryTimer = null;
  }

  void _closeExistingSocket() {
    if (_socket != null) {
      debugPrint('[WebSocketService] Disposing existing Socket.IO socket (ID: ${_socket?.id})...');
      try {
        _socket!.dispose();
      } catch (e) {
         debugPrint('[WebSocketService] Exception disposing socket: $e');
      } finally {
         _socket = null; 
      }
    }
    _isConnected = false;
    _isConnecting = false;
  }

  /// Closes the WebSocket connection and releases resources.
  void close() {
    debugPrint('[WebSocketService] Closing service requested...');
    _cancelRetryTimer(); 

    if (_socket?.connected ?? false) {
      debugPrint('[WebSocketService] Manually disconnecting socket...');
      _socket!.disconnect();
    }
    _closeExistingSocket();

    if (!_responseController.isClosed) {
        _responseController.close();
    }
    debugPrint('[WebSocketService] Service closed.');
  }
}