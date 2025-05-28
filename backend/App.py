# backend/app.py

import os

from model_config import *
from operations.detect_objects import *
from operations.detect_scene import *
from operations.detect_text import *
from operations.detect_currency import *

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Keep if needed

from flask import Flask, request, jsonify, render_template
from flask_cors import CORS
from flask_socketio import SocketIO, emit
from flask_sqlalchemy import SQLAlchemy
import cv2
import numpy as np
import torch
import io
import base64
import logging
from PIL import Image
import pytesseract  # For OCR
import torchvision.models as models  # For Places365
import torchvision.transforms as transforms  # For Places365
import requests
import time
import sys
from ultralytics import YOLO  # Using YOLO from ultralytics


logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

logger.info(
    f"Ollama Configuration: Model='{OLLAMA_MODEL_NAME}', URL='{OLLAMA_API_URL}'"
)

template_dir = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "templates")
)
app = Flask(__name__, template_folder=template_dir)
CORS(app)
socketio = SocketIO(
    app,
    cors_allowed_origins="*",
    max_http_buffer_size=20 * 1024 * 1024,
    async_mode="threading",
)


# --- Helper Function for Ollama Interaction ---
def get_llm_feature_choice(image_np, client_sid="Unknown"):
    logger.info(
        f"[{client_sid}] Requesting feature choice from Ollama ({OLLAMA_MODEL_NAME})..."
    )
    start_time = time.time()
    try:
        is_success, buffer = cv2.imencode(".jpg", image_np)
        if not is_success:
            logger.error(f"[{client_sid}] Failed to encode image to JPEG for Ollama.")
            return None
        image_base64 = base64.b64encode(buffer.tobytes()).decode("utf-8")

        prompt = (
            "Analyze the provided image. Based *only* on the main content, "
            "which of the following analysis types is MOST appropriate? "
            "Choose exactly ONE:\n"
            "- 'object_detection': If the image focuses on identifying multiple general items or objects.\n"
            "- 'hazard_detection': If the image seems to contain items that could be hazards (e.g., a car, a stop sign, a knife). The system will then verify.\n"
            "- 'scene_detection': If the image primarily shows an overall environment, location, or setting.\n"
            "- 'text_detection': If the image contains significant readable text (like a document, sign, or label).\n"
            "- 'currency_detection': If the image clearly shows paper money or coins.\n"  # Added currency_detection
            "Respond with ONLY the chosen identifier string (e.g., 'scene_detection') and nothing else."
        )
        payload = {
            "model": OLLAMA_MODEL_NAME,
            "prompt": prompt,
            "images": [image_base64],
            "stream": False,
            "options": {"temperature": 0.3},
        }

        logger.debug(f"[{client_sid}] Sending request to Ollama: {OLLAMA_API_URL}")
        response = requests.post(
            OLLAMA_API_URL,
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=OLLAMA_REQUEST_TIMEOUT,
        )
        response.raise_for_status()

        response_data = response.json()
        llm_response_text = (
            response_data.get("response", "")
            .strip()
            .lower()
            .replace("'", "")
            .replace('"', "")
        )
        logger.debug(f"[{client_sid}] Raw response from Ollama: '{llm_response_text}'")

        chosen_feature = None
        valid_features = [
            "object_detection",
            "hazard_detection",
            "scene_detection",
            "text_detection",
            "currency_detection",
        ]  # Added currency_detection

        if llm_response_text in valid_features:
            chosen_feature = llm_response_text
        else:
            logger.warning(
                f"[{client_sid}] Ollama response '{llm_response_text}' not exact. Searching keywords."
            )
            for feature in valid_features:
                if feature in llm_response_text:
                    if chosen_feature is None:
                        chosen_feature = feature
                        logger.info(f"[{client_sid}] Found keyword '{feature}'.")
                    else:
                        logger.warning(
                            f"[{client_sid}] Multiple keywords found. Using first: '{chosen_feature}'."
                        )
                        break

        if chosen_feature:
            elapsed_time = time.time() - start_time
            logger.info(
                f"[{client_sid}] Ollama chose feature: '{chosen_feature}' in {elapsed_time:.2f}s."
            )
            return chosen_feature
        else:
            logger.error(
                f"[{client_sid}] Failed to extract valid feature from Ollama: '{llm_response_text}'"
            )
            return None
    except requests.exceptions.Timeout:
        logger.error(f"[{client_sid}] Ollama request timed out.")
        return None
    except requests.exceptions.ConnectionError:
        logger.error(f"[{client_sid}] Could not connect to Ollama at {OLLAMA_API_URL}.")
        return None
    except requests.exceptions.RequestException as req_e:
        logger.error(
            f"[{client_sid}] Error during Ollama API request: {req_e}", exc_info=True
        )
        if req_e.response is not None:
            logger.error(
                f"[{client_sid}] Ollama response body (error): {req_e.response.text}"
            )
        return None
    except Exception as e:
        logger.error(
            f"[{client_sid}] Unexpected error during Ollama interaction: {e}",
            exc_info=True,
        )
        return None


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
    final_response_payload = None

    try:
        if not isinstance(data, dict):
            logger.warning(f"Invalid data format from {client_sid}. Expected dict.")
            emit(
                "response",
                {"result": {"status": "error", "message": "Invalid data format"}},
            )
            return

        image_data = data.get("image")
        detection_type_from_payload = data.get("type")
        supervision_request_type = data.get("request_type")

        if not image_data or not detection_type_from_payload:
            logger.warning(f"Missing 'image' or 'type' from {client_sid}.")
            emit(
                "response",
                {"result": {"status": "error", "message": "Missing 'image' or 'type'"}},
            )
            return

        try:
            if image_data.startswith("data:image"):
                header, encoded = image_data.split(",", 1)
            else:
                encoded = image_data
            image_bytes = base64.b64decode(encoded)
            image_np = cv2.imdecode(
                np.frombuffer(image_bytes, np.uint8), cv2.IMREAD_COLOR
            )
            if image_np is None:
                raise ValueError("cv2.imdecode returned None.")
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
                        else:
                            supervision_string_result = obj_dict_result.get(
                                "message",
                                f"Object/Hazard detection issue for SuperVision: {obj_dict_result.get('status')}",
                            )
                    elif chosen_feature_by_llm == "scene_detection":
                        supervision_string_result = detect_scene(image_np)
                    elif chosen_feature_by_llm == "text_detection":
                        supervision_string_result = detect_text(
                            image_np, DEFAULT_OCR_LANG
                        )
                    elif chosen_feature_by_llm == "currency_detection":  # Added
                        currency_output = detect_currency(image_np)  # Returns dict
                        if currency_output.get("status") == "ok":
                            supervision_string_result = currency_output.get(
                                "currency", "Unknown currency"
                            )
                        elif currency_output.get("status") == "none":
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

                    final_response_payload = {
                        "result": supervision_string_result,
                        "feature_id": chosen_feature_by_llm,
                        "is_from_supervision_llm": True,
                    }
                except Exception as exec_e:
                    logger.error(
                        f"[{client_sid}] Error exec selected LLM feature '{chosen_feature_by_llm}': {exec_e}",
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
        else:
            logger.info(
                f"Processing direct request '{detection_type_from_payload}' from {client_sid}"
            )
            detection_function_output = "Error: Unknown processing error"

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
                )
                if "Error" in text_result_str:
                    detection_function_output = {
                        "status": "error",
                        "message": text_result_str,
                    }
                elif "No text detected" in text_result_str:
                    detection_function_output = {
                        "status": "none",
                        "text": text_result_str,
                    }
                else:
                    detection_function_output = {
                        "status": "ok",
                        "text": text_result_str,
                    }
            elif detection_type_from_payload == "hazard_detection":
                detection_function_output = detect_objects(image_np)
            elif detection_type_from_payload == "currency_detection":  # Added
                detection_function_output = detect_currency(
                    image_np
                )  # Returns dict with status, currency, confidence
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
                f"[{client_sid}] Failed to generate a response payload for type '{detection_type_from_payload}'. This indicates a code flow error."
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
        if client_sid != "UnknownSID":
            emit(
                "response",
                {"result": {"status": "error", "message": "Internal WebSocket error."}},
                room=client_sid,
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
        else "VisionAid Backend (Integrated) is running."
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
    use_reloader = debug_mode

    logger.info(
        f"Server listening on http://{host_ip}:{port_num} (Debug: {debug_mode}, Reloader: {use_reloader})"
    )
    logger.info(f" * Ollama Model: {OLLAMA_MODEL_NAME}, URL: {OLLAMA_API_URL}")
    logger.info(
        f" * Currency Model Path: {CURRENCY_MODEL_PATH}, Classes: {CURRENCY_CLASS_NAMES_PATH}, Confidence: {CURRENCY_DETECTION_CONFIDENCE}"
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
            logger.critical(f"Port {port_num} is already in use on {host_ip}.")
        else:
            logger.critical(
                f"Failed to start server due to OS Error: {os_e}", exc_info=True
            )
        sys.exit(1)
    except Exception as run_e:
        logger.critical(f"Failed to start server: {run_e}", exc_info=True)
        sys.exit(1)
    finally:
        logger.info("Server shutdown.")
