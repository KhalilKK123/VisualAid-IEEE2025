# backend/app.py

import os
from model_config import *
from ollama import *
from operations.detect_objects import *
from operations.detect_scene import *
from operations.detect_text import *
from operations.detect_currency import *
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Keep if needed

from flask import Flask, request, jsonify, render_template
from flask_cors import CORS
from flask_socketio import SocketIO, emit
import cv2
import numpy as np
import base64
import logging
import time
import sys

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

if "OLLAMA_MODEL_NAME" in globals() and "OLLAMA_API_URL" in globals():
    logger.info(
        f"Ollama Configuration: Model='{OLLAMA_MODEL_NAME}', URL='{OLLAMA_API_URL}'"
    )
else:
    logger.warning(
        "Ollama configuration (OLLAMA_MODEL_NAME, OLLAMA_API_URL) not found in model_config.py or globals."
    )


template_dir = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "templates")
)
app = Flask(__name__, template_folder=template_dir)
CORS(app)
socketio = SocketIO(
    app,
    cors_allowed_origins="*",
    max_http_buffer_size=20 * 1024 * 1024,  # 20MB
    max_http_buffer_size=20 * 1024 * 1024,  # 20MB
    async_mode="threading",
)


# --- WebSocket Handlers ---
@socketio.on("connect")
def handle_connect():
    logger.info(f"Client connected: {request.sid}")
    emit(
        "response",
        {"event": "connect", "result": {"status": "connected", "id": request.sid}},
    )


@socketio.on("disconnect")
def handle_disconnect():
    logger.info(f"Client disconnected: {request.sid}")


@socketio.on("message")
def handle_message(data):
    client_sid = request.sid
    start_time = time.time()
    detection_type_from_payload = "unknown"
    supervision_request_type = None  # Initialize
    supervision_request_type = None
    final_response_payload = None

    try:
        if not isinstance(data, dict):
            logger.warning(
                f"Invalid data format from {client_sid}. Expected dict, got {type(data)}."
            )
            logger.warning(
                f"Invalid data format from {client_sid}. Expected dict, got {type(data)}."
            )
            emit(
                "response",
                {"result": {"status": "error", "message": "Invalid data format"}},
            )
            return

        image_data = data.get("image")
        detection_type_from_payload = data.get("type")
        supervision_request_type = data.get(
            "request_type"
        )  # Will be None if not present
        supervision_request_type = data.get(
            "request_type"
        )  # Will be None if not present

        if not image_data or not detection_type_from_payload:
            logger.warning(
                f"Missing 'image' or 'type' from {client_sid}. Payload: {data}"
            )
            logger.warning(
                f"Missing 'image' or 'type' from {client_sid}. Payload: {data}"
            )
            emit(
                "response",
                {"result": {"status": "error", "message": "Missing 'image' or 'type'"}},
            )
            return

        try:
            if image_data.startswith("data:image"):
                _, encoded = image_data.split(",", 1)
            else:
                encoded = image_data  # Assume it's already base64 if no prefix
                encoded = image_data  # Assume it's already base64 if no prefix
            image_bytes = base64.b64decode(encoded)
            image_np_buffer = np.frombuffer(image_bytes, np.uint8)
            image_np = cv2.imdecode(image_np_buffer, cv2.IMREAD_COLOR)

            if image_np is None:
                raise ValueError(
                    "cv2.imdecode returned None. Image data might be corrupt or not a supported format."
                )
                raise ValueError(
                    "cv2.imdecode returned None. Image data might be corrupt or not a supported format."
                )
            logger.debug(f"[{client_sid}] Image decoded. Shape: {image_np.shape}")
        except Exception as decode_err:
            logger.error(
                f"Image decode error for {client_sid}: {decode_err}", exc_info=True
            )
            emit(
                "response",
                {"result": {"status": "error", "message": "Invalid image data"}},
            )
            return

        if (
            detection_type_from_payload == "supervision"
            and supervision_request_type == "llm_route"
        ):
            logger.info(
                f"Handling SuperVision LLM routing request from {client_sid}..."
            )
            # Ensure OLLAMA_MODEL_NAME and OLLAMA_API_URL are available for get_llm_feature_choice
            # These should be imported from model_config.py
            chosen_feature_by_llm = get_llm_feature_choice(
                image_np, client_sid
            )  # Pass client_sid if used by the function
            chosen_feature_by_llm = get_llm_feature_choice(image_np, client_sid)
            supervision_string_result = "Error: LLM feature execution failed"

            if chosen_feature_by_llm:
                logger.info(
                    f"[{client_sid}] LLM selected: {chosen_feature_by_llm}. Running detection..."
                )
                try:
                    if (
                        chosen_feature_by_llm == "object_detection"
                        or chosen_feature_by_llm == "hazard_detection"
                    ):
                        obj_dict_result = detect_objects(image_np)
                        if obj_dict_result.get(
                            "status"
                        ) == "ok" and obj_dict_result.get("detections"):
                        if obj_dict_result.get(
                            "status"
                        ) == "ok" and obj_dict_result.get("detections"):
                            names = [d["name"] for d in obj_dict_result["detections"]]
                            supervision_string_result = (
                                ", ".join(names)
                                if names
                                else "No objects detected by SuperVision"
                            )
                        elif obj_dict_result.get("status") == "none":
                            supervision_string_result = (
                                "No objects detected by SuperVision"
                            )
                            supervision_string_result = (
                                "No objects detected by SuperVision"
                            )
                        else:
                            supervision_string_result = obj_dict_result.get(
                                "message",
                                f"Object/Hazard detection issue for SuperVision: {obj_dict_result.get('status')}",
                            )
                    elif chosen_feature_by_llm == "scene_detection":
                        scene_label = detect_scene(image_np)
                        if "Error" in scene_label or "Unknown" in scene_label:
                            supervision_string_result = f"Scene analysis: {scene_label}"
                        else:
                            supervision_string_result = (
                                f"The scene is likely a {scene_label}."
                            )
                            supervision_string_result = (
                                f"The scene is likely a {scene_label}."
                            )
                    elif chosen_feature_by_llm == "text_detection":
                        # detect_text returns a string of detected text or an error/no text message
                        text_content = detect_text(
                            image_np, DEFAULT_OCR_LANG
                        )  # DEFAULT_OCR_LANG from model_config
                        # DEFAULT_OCR_LANG should be available from `from model_config import *`
                        text_content = detect_text(image_np, DEFAULT_OCR_LANG)
                        if "Error" in text_content:
                            supervision_string_result = f"Text analysis: {text_content}"
                            supervision_string_result = f"Text analysis: {text_content}"
                        elif "No text detected" in text_content:
                            supervision_string_result = "No text found in the image."
                        else:
                            supervision_string_result = (
                                f"The image contains the following text: {text_content}"
                            )
                            logger.info(
                                f"[{client_sid}] Text detected by OCR (Supervision), attempting LLM cleaning. Original length: {len(text_content)}"
                            )
                            cleaned_text = clean_text_with_llm(text_content, client_sid)
                            if cleaned_text:
                                supervision_string_result = cleaned_text
                                logger.info(
                                    f"[{client_sid}] Text cleaning successful (Supervision). Cleaned length: {len(cleaned_text)}"
                                )
                            else:
                                supervision_string_result = text_content
                                logger.warning(
                                    f"[{client_sid}] Text cleaning failed (Supervision). Using original OCR text."
                                )
                    elif chosen_feature_by_llm == "currency_detection":
                        currency_output = detect_currency(image_np)
                        if currency_output.get("status") == "ok":
                            supervision_string_result = f"Detected currency: {currency_output.get('currency', 'Unknown currency')}"
                        elif currency_output.get("status") == "none":
                            supervision_string_result = (
                                "No currency detected by SuperVision"
                            )
                            supervision_string_result = (
                                "No currency detected by SuperVision"
                            )
                        else:
                            supervision_string_result = currency_output.get(
                                "message", "Currency detection issue for SuperVision"
                            )
                    else:
                        logger.error(
                            f"[{client_sid}] Invalid feature '{chosen_feature_by_llm}' from LLM."
                        )
                        supervision_string_result = (
                            "Error: Invalid analysis type by LLM"
                        )
                        supervision_string_result = (
                            "Error: Invalid analysis type by LLM"
                        )

                    final_response_payload = {
                        "result": supervision_string_result,
                        "feature_id": chosen_feature_by_llm,
                        "is_from_supervision_llm": True,
                    }
                except Exception as exec_e:
                    logger.error(
                        f"[{client_sid}] Error executing selected LLM feature '{chosen_feature_by_llm}': {exec_e}",
                        exc_info=True,
                    )
                    final_response_payload = {
                        "result": f"Error running {chosen_feature_by_llm}",
                        "feature_id": chosen_feature_by_llm,
                        "is_from_supervision_llm": True,
                    }
            else:
                logger.error(
                    f"[{client_sid}] Failed to get feature choice from Ollama."
                )
                final_response_payload = {
                    "result": "Error: Smart analysis failed (LLM issue)",
                    "feature_id": "supervision_error",
                    "is_from_supervision_llm": True,
                }
        else:  # Direct request (not LLM routed supervision)
        else:  # Direct request (not LLM routed supervision)
            logger.info(
                f"Processing direct request '{detection_type_from_payload}' from {client_sid}"
            )
            detection_function_output = {
                "status": "error",
                "message": "Error: Unknown processing error",
            }  # Default
            detection_function_output = {
                "status": "error",
                "message": "Error: Unknown processing error",
            }  # Default

            if detection_type_from_payload == "object_detection":
                detection_function_output = detect_objects(image_np)
            elif detection_type_from_payload == "focus_detection":
                focus_object_name = data.get("focus_object")
                if not focus_object_name:
                    logger.warning(
                        f"Direct focus_detection from {client_sid} missing 'focus_object'."
                    )
                    detection_function_output = {
                        "status": "error",
                        "message": "Missing 'focus_object' for focus detection",
                    }
                else:
                    detection_function_output = detect_objects(
                        image_np, focus_object=focus_object_name
                    )
            elif detection_type_from_payload == "scene_detection":
                scene_label = detect_scene(image_np)  # Returns a string
                if "Error" in scene_label:  # detect_scene indicates error with "Error"
                    detection_function_output = {
                        "status": "error",
                        "message": scene_label,
                    }
                elif (
                    "Unknown" in scene_label
                ):  # detect_scene indicates no confident detection with "Unknown"
                scene_label = detect_scene(image_np)
                if "Error" in scene_label:
                    detection_function_output = {
                        "status": "error",
                        "message": scene_label,
                    }
                elif "Unknown" in scene_label:
                    detection_function_output = {"status": "none", "scene": scene_label}
                else:
                    detection_function_output = {"status": "ok", "scene": scene_label}
            elif detection_type_from_payload == "text_detection":
                # DEFAULT_OCR_LANG and SUPPORTED_OCR_LANGS should be from model_config
                requested_language = data.get("language", DEFAULT_OCR_LANG).lower()
                validated_language = (
                    requested_language
                    if requested_language in SUPPORTED_OCR_LANGS
                    else DEFAULT_OCR_LANG
                )
                if validated_language != requested_language:
                    logger.warning(
                        f"Client {client_sid} invalid lang '{requested_language}', using '{DEFAULT_OCR_LANG}'."
                    )
                text_result_str = detect_text(
                    image_np, language_code=validated_language
                )  # Returns a string

                text_result_str = detect_text(
                    image_np, language_code=validated_language
                )
                if "Error" in text_result_str:
                    detection_function_output = {
                        "status": "error",
                        "message": text_result_str,
                    }
                    detection_function_output = {
                        "status": "error",
                        "message": text_result_str,
                    }
                elif "No text detected" in text_result_str:
                    detection_function_output = {
                        "status": "none",
                        "text": text_result_str,
                    }
                    detection_function_output = {
                        "status": "none",
                        "text": text_result_str,
                    }
                else:
                    detection_function_output = {
                        "status": "ok",
                        "text": text_result_str,
                    }
            elif (
                detection_type_from_payload == "hazard_detection"
            ):  # Assumes detect_objects handles this
                detection_function_output = detect_objects(
                    image_np
                )  # Or a specialized hazard function
                    logger.info(
                        f"[{client_sid}] Text detected by OCR (Direct), attempting LLM cleaning. Original length: {len(text_result_str)}"
                    )
                    cleaned_text = clean_text_with_llm(text_result_str, client_sid)
                    if cleaned_text:
                        detection_function_output = {
                            "status": "ok",
                            "text": cleaned_text,
                        }
                        logger.info(
                            f"[{client_sid}] Text cleaning successful (Direct). Cleaned length: {len(cleaned_text)}"
                        )
                    else:
                        detection_function_output = {
                            "status": "ok",
                            "text": text_result_str,
                            "warning": "Text cleaning by LLM failed, showing original OCR text.",
                        }
                        logger.warning(
                            f"[{client_sid}] Text cleaning failed (Direct). Using original OCR text."
                        )
            elif detection_type_from_payload == "hazard_detection":
                detection_function_output = detect_objects(image_np)
            elif detection_type_from_payload == "currency_detection":
                detection_function_output = detect_currency(image_np)  # Returns dict
                detection_function_output = detect_currency(image_np)
            else:
                logger.warning(
                    f"Unsupported direct type '{detection_type_from_payload}' from {client_sid}"
                )
                detection_function_output = {
                    "status": "error",
                    "message": f"Unsupported type '{detection_type_from_payload}'",
                }

            final_response_payload = {"result": detection_function_output}

        if final_response_payload:
            processing_time = time.time() - start_time
            log_result_summary = str(final_response_payload.get("result", "N/A"))
            if isinstance(final_response_payload.get("result"), dict):
                log_result_summary = (
                    f"Dict keys: {list(final_response_payload['result'].keys())}"
                )
            log_result_short = (
                (log_result_summary[:100] + "...")
                if len(log_result_summary) > 100
                else log_result_summary
            )
            log_type = final_response_payload.get(
                "feature_id", detection_type_from_payload
            )
            log_type = final_response_payload.get(
                "feature_id", detection_type_from_payload
            )
            log_origin = (
                "Supervision(LLM)"
                if final_response_payload.get("is_from_supervision_llm")
                else "Direct"
            )
            logger.info(
                f"Completed '{log_type}' ({log_origin}) for {client_sid} in {processing_time:.3f}s. Result summary: '{log_result_short}'"
            )
            emit("response", final_response_payload)
        else:
            logger.error(
                f"[{client_sid}] Failed to generate a response payload for type '{detection_type_from_payload}'."
            )
            emit(
                "response",
                {
                    "result": {
                        "status": "error",
                        "message": "Server Error: Failed to process request.",
                    }
                },
            )

    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(
            f"Unhandled error in handle_message (type: '{detection_type_from_payload}') for {client_sid} after {processing_time:.3f}s: {e}",
            exc_info=True,
        )
        try:
            error_resp = {
                "result": {
                    "status": "error",
                    "message": "Internal server error during processing.",
                }
            }
            if (
                detection_type_from_payload == "supervision"
                and supervision_request_type
                == "llm_route"  # Check supervision_request_type here
                and supervision_request_type == "llm_route"
            ):
                error_resp["feature_id"] = "supervision_error"
                error_resp["is_from_supervision_llm"] = True
            emit("response", error_resp)
        except Exception as emit_e:
            logger.error(f"Failed to emit error response to {client_sid}: {emit_e}")


@socketio.on_error_default
def default_error_handler(e):
    client_sid = request.sid if request else "UnknownSID"
    logger.error(f"Unhandled WebSocket Error for SID {client_sid}: {e}", exc_info=True)
    try:
        if client_sid != "UnknownSID":  # Avoid emitting if SID is not available
        if client_sid != "UnknownSID":
            emit(
                "response",
                {"result": {"status": "error", "message": "Internal WebSocket error."}},
                room=client_sid,  # Send to specific client if SID is known
                room=client_sid,  # Send to specific client if SID is known
            )
    except Exception as emit_err:
        logger.error(f"Failed emit default error response to {client_sid}: {emit_err}")


# --- HTTP Routes ---
@app.route("/")
def home():
    test_html_path = os.path.join(template_dir, "test.html")
    return (
        render_template("test.html")
        if os.path.exists(test_html_path)
        else "VisionAid Backend (Integrated) is running. Test page not found."
    )


@app.route("/update_customization", methods=["POST"])
def update_customization():
    logger.warning("Route /update_customization hit (not implemented).")
    return jsonify({"status": "not_implemented"}), 501


@app.route("/get_user_info", methods=["GET"])
def get_user_info():
    logger.warning("Route /get_user_info hit (not implemented).")
    return jsonify({"status": "not_implemented"}), 501


@app.route("/add_test_user", methods=["POST"])
def add_test_user():
    logger.warning("Route /add_test_user hit (not implemented).")
    return jsonify({"status": "not_implemented"}), 501


# --- Main Execution Point ---
if __name__ == "__main__":
    logger.info("Starting Flask-SocketIO server (Integrated Version)...")
    host_ip = os.environ.get("FLASK_HOST", "0.0.0.0")
    port_num = int(os.environ.get("FLASK_PORT", 5000))
    debug_mode = os.environ.get("FLASK_DEBUG", "False").lower() in ("true", "1", "t")
    use_reloader = debug_mode  # Typically reloader is used in debug mode
    use_reloader = debug_mode

    logger.info(
        f"Server listening on http://{host_ip}:{port_num} (Debug: {debug_mode}, Reloader: {use_reloader})"
    )

    # Log Ollama configuration if variables are available
    if "OLLAMA_MODEL_NAME" in globals() and "OLLAMA_API_URL" in globals():
        logger.info(f" * Ollama Model: {OLLAMA_MODEL_NAME}, URL: {OLLAMA_API_URL}")
    else:
        logger.info(
            " * Ollama Model: Not configured / variables not found in model_config"
        )

    # Log Ollama configuration
    # OLLAMA_MODEL_NAME, OLLAMA_TEXT_CLEANING_MODEL_NAME, OLLAMA_API_URL are defined globally
    logger.info(
        f" * Ollama Routing Model: {OLLAMA_MODEL_NAME}, Text Cleaning Model: {OLLAMA_TEXT_CLEANING_MODEL_NAME}, URL: {OLLAMA_API_URL}"
    )

    # Log Roboflow configuration for currency detection
    # ROBOFLOW_MODEL_ENDPOINT and CURRENCY_DETECTION_CONFIDENCE must be defined in model_config.py
    if (
        "ROBOFLOW_MODEL_ENDPOINT" in globals()
        and "CURRENCY_DETECTION_CONFIDENCE" in globals()
    ):
    # Assuming ROBOFLOW_MODEL_ENDPOINT and CURRENCY_DETECTION_CONFIDENCE are in model_config.py
    if (
        "ROBOFLOW_MODEL_ENDPOINT" in globals()
        and "CURRENCY_DETECTION_CONFIDENCE" in globals()
    ):
        logger.info(
            f" * Currency Detection: Roboflow API Endpoint='{ROBOFLOW_MODEL_ENDPOINT}', Client Confidence Threshold='{CURRENCY_DETECTION_CONFIDENCE}'"
        )
    else:
        logger.info(
            " * Currency Detection: Roboflow API Not configured / variables not found in model_config"
        )
        logger.info(
            " * Currency Detection: Roboflow API Not configured / variables not found in model_config"
        )

    try:
        socketio.run(
            app,
            debug=debug_mode,
            host=host_ip,
            port=port_num,
            use_reloader=use_reloader,
            allow_unsafe_werkzeug=True if use_reloader else False,
        )
    except OSError as os_e:
        if "Address already in use" in str(os_e):
            logger.critical(
                f"Port {port_num} is already in use on {host_ip}. Cannot start server."
            )
            logger.critical(
                f"Port {port_num} is already in use on {host_ip}. Cannot start server."
            )
        else:
            logger.critical(
                f"Failed to start server due to OS Error: {os_e}", exc_info=True
            )
        sys.exit(1)  # Exit if server cannot start
        sys.exit(1)
    except Exception as run_e:
        logger.critical(f"Failed to start server: {run_e}", exc_info=True)
        sys.exit(1)  # Exit if server cannot start
        sys.exit(1)
    finally:
        logger.info("Server shutdown.")
