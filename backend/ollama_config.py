import os

from model_config import *

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Keep if needed

import requests
import cv2
import base64
import time


# --- Ollama Configuration ---
OLLAMA_MODEL_NAME = os.environ.get("OLLAMA_MODEL", "gemma3:12b")
OLLAMA_API_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434/api/generate")
OLLAMA_REQUEST_TIMEOUT = 60

logger.info(
    f"Ollama Configuration: Model='{OLLAMA_MODEL_NAME}', URL='{OLLAMA_API_URL}'"
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
        ]

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
