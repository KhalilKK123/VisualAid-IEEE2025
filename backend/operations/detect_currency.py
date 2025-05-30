import os
import cv2
import base64
import requests

# Import configurations from model_config.py
# This assumes model_config.py is in the same directory or accessible via PYTHONPATH
from model_config import (
    logger,
    ROBOFLOW_API_KEY,
    ROBOFLOW_MODEL_ENDPOINT,
    CURRENCY_DETECTION_CONFIDENCE
)

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Kept as in your original file

# Link for testing currency images (from your original file)
# https://www.centralbank.ae/en/our-operations/currency-and-coins/circulated-currency/


def detect_currency(image_np):
    """
    Detects currency using the Roboflow API.
    Returns the name and confidence of the most confident currency detection.
    Maintains the same output structure as the previous local model version.
    """

    # Check if Roboflow API credentials are set in model_config.py
    # Using the specific placeholder key for a more accurate check if it's unconfigured.
    
    # if not ROBOFLOW_API_KEY or ROBOFLOW_API_KEY == "Ey5qUJWyHf0BwJnIjXBv" or not ROBOFLOW_MODEL_ENDPOINT:
    #     logger.error(
    #         "Roboflow API Key or Model Endpoint is not properly configured in model_config.py. "
    #         "Cannot perform currency detection."
    #     )
    #     return {"status": "error", "message": "Currency detection API not configured"}

    try:
        # 1. Prepare the image for Roboflow API
        # Encode the image_np (which is a NumPy array, typically BGR from OpenCV) to JPEG format bytes
        success, img_encoded = cv2.imencode(".jpg", image_np)
        if not success:
            logger.error("Failed to encode image to JPEG format for API submission.")
            return {"status": "error", "message": "Image encoding failed"}

        # Base64 encode the JPEG bytes
        img_base64 = base64.b64encode(img_encoded).decode("utf-8")

        # 2. Make the API call to Roboflow
        # The Content-Type for sending raw base64 data in the body can sometimes be 'text/plain'
        # or 'application/octet-stream'. However, Roboflow's curl examples with `base64 | curl -d @-`
        # often work well when `requests` sends the string data directly, and
        # `application/x-www-form-urlencoded` is a common default for `curl -d`.
        # If Roboflow expects the raw base64 in the body, just data=img_base64 is fine.
        # Let's use a simple header or none if the API infers, or be explicit if required.
        # For the provided curl example `base64 YOUR_IMAGE.jpg | curl -d @- ...`,
        # the data is sent as the body. `requests` handles this with the `data` param.
        # `Content-Type: application/x-www-form-urlencoded` is what curl often uses for -d.
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        api_url = f"{ROBOFLOW_MODEL_ENDPOINT}?api_key={ROBOFLOW_API_KEY}"

        # Roboflow API might also support sending confidence as a query parameter,
        # e.g., &confidence=40 (percent) or &confidence=0.4 (decimal)
        # For now, we filter client-side using CURRENCY_DETECTION_CONFIDENCE
        # api_url += f"&confidence={int(CURRENCY_DETECTION_CONFIDENCE * 100)}" # If API takes %

        logger.debug(f"Sending request to Roboflow API: {ROBOFLOW_MODEL_ENDPOINT}")
        response = requests.post(api_url, data=img_base64, headers=headers, timeout=20) # Added timeout
        response.raise_for_status()  # Raise an HTTPError for bad responses (4XX or 5XX)

        api_result = response.json()
        logger.debug(f"Received Roboflow API response: {api_result}")


        best_detection = None
        highest_confidence = 0.0

        # Check if 'predictions' key exists and is a list
        if "predictions" in api_result and isinstance(api_result["predictions"], list):
            for detection in api_result["predictions"]:
                try:
                    confidence = float(detection["confidence"])
                    class_name = str(detection["class"]) # Roboflow provides the class name

                    # Apply the client-side confidence threshold from model_config.py
                    if confidence < CURRENCY_DETECTION_CONFIDENCE:
                        continue

                    if confidence > highest_confidence:
                        highest_confidence = confidence
                        best_detection = {
                            "name": class_name,
                            "confidence": confidence,
                            # "box" data could be extracted here if needed, similar to original:
                            # "box": [detection.get('x'), detection.get('y'), detection.get('width'), detection.get('height')]
                        }
                except (KeyError, ValueError) as e:
                    logger.warning(f"Skipping malformed detection object: {detection}. Error: {e}")
                    continue
        else:
            logger.debug("No 'predictions' field or empty predictions in Roboflow API response.")


        if best_detection:
            logger.debug(
                f"Currency detection (Roboflow): {best_detection['name']} (Conf: {best_detection['confidence']:.3f})"
            )
            return {
                "status": "ok",
                "currency": best_detection["name"],
                "confidence": best_detection["confidence"],
            }
        else:
            logger.debug("No currency detected meeting confidence criteria via Roboflow.")
            return {"status": "none", "message": "No currency detected"}

    except requests.exceptions.Timeout:
        logger.error("Error during currency detection: Roboflow API request timed out.", exc_info=True)
        return {"status": "error", "message": "API request timed out"}
    except requests.exceptions.HTTPError as http_err:
        # Log more details for HTTP errors
        error_message = f"HTTP error occurred: {http_err}."
        try:
            # Attempt to get more detailed error from response body if available
            error_details = http_err.response.json()
            error_message += f" Details: {error_details.get('message', http_err.response.text)}"
        except ValueError: # If response body is not JSON
            error_message += f" Details: {http_err.response.text}"
        logger.error(f"Error during currency detection: {error_message}", exc_info=True)
        return {"status": "error", "message": "API request failed with HTTP error"}
    except requests.exceptions.RequestException as req_e:
        logger.error(f"Error during currency detection: Roboflow API request failed: {req_e}", exc_info=True)
        return {"status": "error", "message": "API request failed"}
    except Exception as e:
        logger.error(f"An unexpected error occurred during currency detection: {e}", exc_info=True)
        return {"status": "error", "message": "Error in currency detection"}

# Example usage (for testing this script directly)
if __name__ == "__main__":
    # Ensure logger is configured if running standalone for testing
    # (model_config should already configure it, but this is a fallback for direct script run)
    if not logger.hasHandlers():
        import logging
        logging.basicConfig(level=logging.DEBUG,
                            format="%(asctime)s - %(name)s - %(levelname)s - %(message)s")
        logger.info("Basic logger configured for standalone test.")

    logger.info("--- Testing detect_currency_roboflow.py ---")
    # Create a dummy numpy image (e.g., 640x480, 3 channels, black)
    # For a real test, replace this with cv2.imread("your_currency_image.jpg")
    import numpy as np
    dummy_image_np = np.zeros((480, 640, 3), dtype=np.uint8)
    cv2.putText(dummy_image_np, "Test Image", (50, 240), cv2.FONT_HERSHEY_SIMPLEX, 2, (255, 255, 255), 3)


    if ROBOFLOW_API_KEY == "Ey5qUJWyHf0BwJnIjXBv":
        logger.warning("Using a placeholder Roboflow API key from model_config.py. "
                       "The API call might fail or return empty results if this key is not valid for the endpoint.")

    print("\nAttempting detection with a dummy image (expect 'No currency detected' or an API error if key is invalid):")
    detection_result = detect_currency(dummy_image_np)
    print(f"Detection Result: {detection_result}")

    # To test with a real image:
    # 1. Save a currency image (e.g., from the Central Bank link) as `test_aed_note.jpg`
    #    in the same directory as this script.
    # 2. Uncomment and run the following:
    # logger.info("\n--- Testing with a real image (test_aed_note.jpg) ---")
    # test_image_path = "test_aed_note.jpg"
    # try:
    #     real_image_np = cv2.imread(test_image_path)
    #     if real_image_np is None:
    #         logger.error(f"Could not load image from '{test_image_path}'. Make sure the file exists.")
    #     else:
    #         logger.info(f"Successfully loaded image: {test_image_path}")
    #         real_detection_result = detect_currency(real_image_np)
    #         print(f"Real Image Detection Result: {real_detection_result}")
    # except Exception as e:
    #     logger.error(f"Error during real image test: {e}")

    print("\n--- Test Complete ---")