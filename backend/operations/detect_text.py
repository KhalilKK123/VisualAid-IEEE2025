import os
import re
import unicodedata # Import unicodedata for character properties

from model_config import * # Assuming this correctly sets up logger, etc.
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Keep if needed

import cv2
from PIL import Image
import pytesseract
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

    # Ensure TESSDATA_PREFIX is set if it's not already,
    # especially important for custom language data
    # pytesseract.pytesseract.tesseract_cmd = r'C:\Program Files\Tesseract-OCR\tesseract.exe' # Example, set if Tesseract not in PATH
    # os.environ['TESSDATA_PREFIX'] = r'C:\Program Files\Tesseract-OCR\tessdata' # Example, set if tessdata not in default location


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
        custom_config = f"-l {validated_lang} --oem 3 --psm 6" # PSM 6 is generally good for uniform block of text
        logger.debug(f"Using Tesseract config: {custom_config}")
        detected_text = pytesseract.image_to_string(img_pil, config=custom_config)
        
        # --- Language-Agnostic Heuristic Filtering Starts Here ---
        filtered_lines = []
        for line in detected_text.splitlines():
            stripped_line = line.strip()
            if not stripped_line:
                continue

            # Heuristic 1: Filter out unprintable characters and control characters.
            # This is more robust than explicit a-zA-Z, allowing for any script.
            # We keep characters that are 'printable' (letters, numbers, symbols, punctuation, spaces)
            # and remove explicit control characters or unassigned ones.
            # Using unicodedata.category to be precise:
            # L (Letter), N (Number), P (Punctuation), S (Symbol), Zs (Space separator)
            # Other categories like C (Control) or M (Mark) might be noise.
            cleaned_line_chars = []
            for char in stripped_line:
                if unicodedata.category(char).startswith(('L', 'N', 'P', 'S', 'Z')):
                    cleaned_line_chars.append(char)
                elif char in ('\n', '\r', '\t'): # Allow common whitespace
                    cleaned_line_chars.append(char)
            
            cleaned_line = "".join(cleaned_line_chars)
            
            # Remove multiple spaces and strip leading/trailing whitespace
            cleaned_line = re.sub(r'\s+', ' ', cleaned_line).strip()

            if not cleaned_line: # After cleaning, if it's empty, skip
                continue

            # Heuristic 2: Character Ratio Check (more general than just 'alpha')
            # Check the proportion of 'meaningful' characters (letters, numbers, punctuation)
            # versus total characters. This helps filter lines with too many unassigned or
            # strange symbols that might slip past the initial cleaning.
            meaningful_chars = sum(
                1 for char in cleaned_line 
                if unicodedata.category(char).startswith(('L', 'N', 'P', 'S')) # Letters, Numbers, Punctuation, Symbols
            )
            total_chars = len(cleaned_line)
            
            # Tunable threshold for meaningful characters.
            # This needs to be carefully considered. For gibberish, this ratio will often be very low.
            # For actual text (even foreign scripts), it should be high.
            MEANINGFUL_CHAR_RATIO_THRESHOLD = 0.4 # At least 40% meaningful chars (can be adjusted)
            
            if total_chars > 0 and (meaningful_chars / total_chars) < MEANINGFUL_CHAR_RATIO_THRESHOLD:
                logger.debug(f"Discarding line due to low meaningful character ratio: '{cleaned_line}' (Ratio: {meaningful_chars/total_chars:.2f})")
                continue

            # Heuristic 3: Minimum line length check (after cleaning)
            # This is still valuable, as very short lines are often noise regardless of script.
            MIN_LINE_LENGTH = 2 # Adjusted to be more lenient for short words/codes
            if len(cleaned_line) < MIN_LINE_LENGTH:
                logger.debug(f"Discarding line due to short length: '{cleaned_line}' (Length: {len(cleaned_line)})")
                continue
            
            filtered_lines.append(cleaned_line)
        
        result_str = "\n".join(filtered_lines)
        # --- Language-Agnostic Heuristic Filtering Ends Here ---

        if not result_str:
            logger.debug(f"Tesseract ({validated_lang}): No meaningful text found after filtering.")
            return "No text detected"
        else:
            log_text = result_str.replace("\n", " ").replace("\r", "")[:100]
            logger.debug(f"Tesseract ({validated_lang}) OK: Found '{log_text}...' (Filtered)")
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