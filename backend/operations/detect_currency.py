import os

from model_config import *

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Keep if needed

import cv2
from PIL import Image

# use this link to test the currency https://www.centralbank.ae/en/our-operations/currency-and-coins/circulated-currency/


def detect_currency(image_np):
    """
    Detects currency using the custom YOLOv8 model (Best.pt).
    Returns the name and confidence of the most confident currency detection.
    """
    global currency_model, currency_class_names  # Ensure we are using the globally loaded ones

    if currency_model is None:
        logger.error(
            "Currency model (Best.pt) is not loaded. Cannot perform currency detection."
        )
        return {"status": "error", "message": "Currency model not loaded"}

    try:
        img_rgb = cv2.cvtColor(image_np, cv2.COLOR_BGR2RGB)
        img_pil = Image.fromarray(img_rgb)

        results = currency_model.predict(
            img_pil, conf=CURRENCY_DETECTION_CONFIDENCE, verbose=False
        )

        best_detection = None
        highest_confidence = 0.0

        if results and results[0].boxes:
            boxes = results[0].boxes
            # The model's own class names are in results[0].names
            # If currency_class_names list is loaded from file, it should match these.
            # For robustness, prioritize model's own names if currency_class_names is empty.
            model_internal_class_names = results[0].names

            for box in boxes:
                confidence = float(box.conf[0])
                class_id = int(box.cls[0])

                class_name = f"Unknown Currency (ID: {class_id})"  # Default
                if currency_class_names and 0 <= class_id < len(currency_class_names):
                    class_name = currency_class_names[class_id]
                elif model_internal_class_names and 0 <= class_id < len(
                    model_internal_class_names
                ):
                    class_name = model_internal_class_names[class_id]
                    if not currency_class_names:  # Log only once if we had to fallback
                        logger.warning(
                            f"Using internal model class name '{class_name}' for ID {class_id} as external class names were not loaded/matched."
                        )

                if confidence > highest_confidence:
                    highest_confidence = confidence
                    best_detection = {
                        "name": class_name,
                        "confidence": confidence,
                        # "box": box.xyxyn[0].tolist() # Optionally include box if needed
                    }

        if best_detection:
            logger.debug(
                f"Currency detection: {best_detection['name']} (Conf: {best_detection['confidence']:.3f})"
            )
            return {
                "status": "ok",
                "currency": best_detection["name"],
                "confidence": best_detection["confidence"],
            }
        else:
            logger.debug("No currency detected meeting confidence criteria.")
            return {"status": "none", "message": "No currency detected"}

    except Exception as e:
        logger.error(f"Error during currency detection: {e}", exc_info=True)
        return {"status": "error", "message": "Error in currency detection"}
