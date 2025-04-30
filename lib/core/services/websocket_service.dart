// lib/core/services/websocket_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

const String _serverUrl = 'http://xyz:5000';

class WebSocketService {
  IO.Socket? _socket;
  bool _isConnected = false;

  final StreamController<Map<String, dynamic>> _responseController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get responseStream => _responseController.stream;
  bool get isConnected => _isConnected;

  WebSocketService() {}

  void connect() {
    if (_isConnected && _socket != null) {
      debugPrint('[SocketIOClient] Already connected.');
      return;
    }

    debugPrint('[SocketIOClient] Attempting to connect to $_serverUrl...');

    // --- Disconnect previous socket if any ---
    _disposeSocket();
    try {
      // --- Create Socket.IO Client Instance ---
      _socket = IO.io(_serverUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
        'forceNew': true,
      });

      // --- Register Event Listeners ---
      _socket?.onConnect((_) {
        _isConnected = true;
        debugPrint('[SocketIOClient] Connected: ${_socket?.id}');
      });

      _socket?.on('response', (data) {
        if (data is Map<String, dynamic>) {
          if (kDebugMode) {
            debugPrint('[SocketIOClient] Event "response" received: $data');
          }
          _responseController.add(data);
        } else if (data != null) {
          // Handle cases where backend might send non-map data unexpectedly
          debugPrint(
              '[SocketIOClient] Received non-map data for "response": ${data.runtimeType} - $data');
          _responseController
              .add({'event': 'raw_response', 'data': data.toString()});
        } else {
          debugPrint(
              '[SocketIOClient] Received null data for "response" event.');
        }
      });

      _socket?.onConnectError((error) {
        _isConnected = false;
        debugPrint('[SocketIOClient] Connection Error: $error');
        _responseController
            .add({'event': 'error', 'message': 'Connection Error: $error'});
        _disposeSocket();
      });

      _socket?.onError((error) {
        debugPrint('[SocketIOClient] Socket Error: $error');
        _responseController
            .add({'event': 'error', 'message': 'Socket Error: $error'});
      });

      _socket?.onDisconnect((reason) {
        _isConnected = false;
        debugPrint('[SocketIOClient] Disconnected: $reason');
        _responseController.add({'event': 'disconnect', 'reason': reason});
        _disposeSocket();
      });

      // --- Initiate Connection ---
      _socket?.connect();
    } catch (e) {
      _isConnected = false;
      debugPrint('[SocketIOClient] Error initializing socket: $e');
      _responseController.add({
        'event': 'error',
        'message': 'Initialization failed: ${e.toString()}'
      });
    }
  }

  // --- Updated sendImageForProcessing ---
  Future<void> sendImageForProcessing(XFile imageFile, String featureId,
      {String? languageCode, String? requestType}) async {
    if (!(_isConnected && _socket != null)) {
      debugPrint('[SocketIOClient] Cannot send: Not connected.');
      _responseController.add(
          {'event': 'error', 'message': 'Cannot send request: Not connected.'});
      return;
    }

    try {
      final bytes = await imageFile.readAsBytes();
      final base64Image = base64Encode(bytes);

      final Map<String, dynamic> data = {
        'type': featureId,
        'image': base64Image,
        if (languageCode != null) 'language': languageCode,
        if (requestType != null) 'request_type': requestType,
      };

      _socket?.emit('message', data);

      debugPrint(
          '[SocketIOClient] Emitted "message". Type: $featureId, Lang: $languageCode, RequestType: $requestType');
    } catch (e) {
      debugPrint('[SocketIOClient] Error preparing/sending message: $e');
      _responseController.add({
        'event': 'error',
        'message': 'Error sending request: ${e.toString()}'
      });
    }
  }

  void _disposeSocket() {
    if (_socket != null) {
      debugPrint('[SocketIOClient] Disposing socket instance.');
      _socket?.disconnect();
      _socket?.dispose();
      _socket = null;
    }
    _isConnected = false;
  }

  void close() {
    debugPrint('[SocketIOClient] close() called, disposing connection.');
    _disposeSocket();
  }
}
