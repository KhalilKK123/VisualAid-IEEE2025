import os

from model_config import *

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Keep if needed

import cv2
from PIL import Image
import pytesseract  # For OCR
import time


def detect_text(image_np, language_code=DEFAULT_OCR_LANG):
    logger.debug(f"Starting Tesseract OCR for lang: '{language_code}'...")
    validated_lang = language_code
    if language_code not in SUPPORTED_OCR_LANGS:
        logger.warning(
            f"Requested lang '{language_code}' not in supported list {SUPPORTED_OCR_LANGS}. Falling back to '{DEFAULT_OCR_LANG}'."
        )
        validated_lang = DEFAULT_OCR_LANG
        if validated_lang not in SUPPORTED_OCR_LANGS:
            logger.error(
                f"Default language '{DEFAULT_OCR_LANG}' is also not available. OCR cannot proceed."
            )
            return "Error: OCR Language Not Available"

    if SAVE_OCR_IMAGES:
        try:
            timestamp = time.strftime("%Y%m%d-%H%M%S")
            filename = os.path.join(
                OCR_IMAGE_SAVE_DIR, f"ocr_input_{timestamp}_{validated_lang}.png"
            )
            save_img = image_np
            if len(image_np.shape) == 3 and image_np.shape[2] == 4:
                save_img = cv2.cvtColor(image_np, cv2.COLOR_BGRA2BGR)
            elif len(image_np.shape) == 2:
                save_img = cv2.cvtColor(image_np, cv2.COLOR_GRAY2BGR)
            cv2.imwrite(filename, save_img)
            logger.debug(f"Saved OCR input image to: {filename}")
        except Exception as save_e:
            logger.error(f"Failed to save debug OCR image: {save_e}")

    try:
        gray_img = (
            cv2.cvtColor(image_np, cv2.COLOR_BGR2GRAY)
            if len(image_np.shape) == 3
            else image_np
        )
        img_pil = Image.fromarray(gray_img)
        custom_config = f"-l {validated_lang} --oem 3 --psm 6"
        logger.debug(f"Using Tesseract config: {custom_config}")
        detected_text = pytesseract.image_to_string(img_pil, config=custom_config)
        result_str = detected_text.strip()
        if not result_str:
            logger.debug(f"Tesseract ({validated_lang}): No text found.")
            return "No text detected"
        else:
            result_str = "\n".join(
                [line.strip() for line in result_str.splitlines() if line.strip()]
            )
            log_text = result_str.replace("\n", " ").replace("\r", "")[:100]
            logger.debug(f"Tesseract ({validated_lang}) OK: Found '{log_text}...'")
            print(f"AAAAAAAAAAAAAAAAAAAAAAAAAAAAA ({result_str})")
            return result_str
    except pytesseract.TesseractNotFoundError:
        logger.error("Tesseract executable not found.")
        return "Error: OCR Engine Not Found"
    except pytesseract.TesseractError as tess_e:
        logger.error(f"TesseractError ({validated_lang}): {tess_e}", exc_info=False)
        error_str = str(tess_e).lower()
        if (
            "failed loading language" in error_str
            or "could not initialize tesseract" in error_str
            or "data file not found" in error_str
        ):
            logger.error(f"Missing Tesseract language data for '{validated_lang}'.")
            return f"Error: Missing OCR language data for '{validated_lang}'"
        else:
            return f"Error during text detection ({validated_lang})"
    except Exception as e:
        logger.error(f"Unexpected OCR error ({validated_lang}): {e}", exc_info=True)
        return f"Error during text detection ({validated_lang})"
