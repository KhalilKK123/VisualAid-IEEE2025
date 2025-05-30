import os

from model_config import *

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Keep if needed

import requests
import cv2
import base64
import time


# --- Ollama Configuration ---
OLLAMA_MODEL_NAME = os.environ.get("OLLAMA_MODEL", "gemma3:12b")  # For routing
OLLAMA_TEXT_CLEANING_MODEL_NAME = os.environ.get(
    "OLLAMA_TEXT_CLEANING_MODEL", "gemma3:latest"
)  # For text cleaning
OLLAMA_API_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434/api/generate")
OLLAMA_REQUEST_TIMEOUT = 60

logger.info(
    f"Ollama Configuration: Routing Model='{OLLAMA_MODEL_NAME}', Text Cleaning Model='{OLLAMA_TEXT_CLEANING_MODEL_NAME}', URL='{OLLAMA_API_URL}'"
)


# --- Helper Function for Ollama Interaction (Feature Choice) ---
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

        prompt = "You are an LLM that exists as middleware between the client and the server. The client is an application that helps  blind or partially blind user by providing them a camera that would take an image and send it over to the server. The server contains 5 machine learning models: object_detection, hazard_detection, scene_detection, text_detection, and text_detection. One of the models receives the image sent in by the client and outputs a response, which is then sent back to the client. Your job is to determine which model is best for the job. Simply reply with 'object_detection' if the image displayed is clearly centered and focused around a single object or thing, especially if the object in the image is close to the camera. Simply reply with 'hazard_detection' if the image shows something that could be dangerous to a user, like a stop sign or a knife or an animal. Simply reply with 'scene_detection' if the image is not focused on any particular thing and is instead showing an entire room or environment. Simply reply with 'text_detection' if the image has a lot of text clearly and legibly centered in the screen. Simply reply with 'currency_detection' if the image shows money of any kind."
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


# --- Helper Function for Ollama Text Cleaning ---
def clean_text_with_llm(raw_text, client_sid="Unknown"):
    logger.info(
        f"[{client_sid}] Requesting text cleaning from Ollama ({OLLAMA_TEXT_CLEANING_MODEL_NAME})..."
    )
    start_time = time.time()
    try:
        # old prompt
        # prompt = (
        #     "Analyze the provided image. Based *only* on the main content, "
        #     "which of the following analysis types is MOST appropriate? "
        #     "Choose exactly ONE:\n"
        #     "- 'object_detection': Only choose this mode if the image has an object or thing in the center of the screen, as if the user is displaying that item.\n"
        #     "- 'hazard_detection': If the image seems to contain items that could be hazards (e.g., a car, a stop sign, a knife, an animal). You have to be incredibly sure this could be a clear and obvious threat for a blind or partially blind person to select this option. \n"
        #     "- 'scene_detection': Only choose this mode if the center of the image is not focused on one particular object or thing and is instead taking a wide angle that doesn't have anything prominently displayed in the center and is showing a general scene.\n"
        #     "- 'text_detection': If the image contains significant readable text (like a document, sign, or label).\n"
        #     "- 'currency_detection': If the image clearly shows paper money.\n"
        #     "Respond with ONLY the chosen identifier string (e.g., 'scene_detection') and nothing else."
        # )

        prompt = (
            "The following is a piece of text scanned. This scan contains some errors, like random extra characters. Clean the text without changing much. Reply with only the cleaned text, in the same language you scanned it in, nothing else. If you got it in English, output it in English, and so on. Here is the text:\n"
            f"{raw_text}"
        )

        payload = {
            "model": OLLAMA_TEXT_CLEANING_MODEL_NAME,
            "prompt": prompt,
            "stream": False,
            "options": {
                "temperature": 0.2
            },  # Lower temperature for more deterministic cleaning
        }

        logger.debug(
            f"[{client_sid}] Sending text cleaning request to Ollama: {OLLAMA_API_URL}"
        )
        response = requests.post(
            OLLAMA_API_URL,
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=OLLAMA_REQUEST_TIMEOUT,
        )
        response.raise_for_status()

        response_data = response.json()
        cleaned_text = response_data.get("response", "").strip()

        if cleaned_text:
            elapsed_time = time.time() - start_time
            logger.info(
                f"[{client_sid}] Ollama cleaned text in {elapsed_time:.2f}s. Original length: {len(raw_text)}, Cleaned length: {len(cleaned_text)}"
            )
            # Log a snippet of original and cleaned for comparison if helpful
            # logger.debug(f"[{client_sid}] Original text snippet: '{raw_text[:100]}...'")
            # logger.debug(f"[{client_sid}] Cleaned text snippet: '{cleaned_text[:100]}...'")
            return cleaned_text
        else:
            logger.warning(
                f"[{client_sid}] Ollama returned empty response for text cleaning. Raw response: {response_data}"
            )
            return None  # Indicate cleaning didn't produce output, or return raw_text
    except requests.exceptions.Timeout:
        logger.error(f"[{client_sid}] Ollama text cleaning request timed out.")
        return None
    except requests.exceptions.ConnectionError:
        logger.error(
            f"[{client_sid}] Could not connect to Ollama at {OLLAMA_API_URL} for text cleaning."
        )
        return None
    except requests.exceptions.RequestException as req_e:
        logger.error(
            f"[{client_sid}] Error during Ollama text cleaning API request: {req_e}",
            exc_info=True,
        )
        if req_e.response is not None:
            logger.error(
                f"[{client_sid}] Ollama text cleaning response body (error): {req_e.response.text}"
            )
        return None
    except Exception as e:
        logger.error(
            f"[{client_sid}] Unexpected error during Ollama text cleaning: {e}",
            exc_info=True,
        )
        return None
