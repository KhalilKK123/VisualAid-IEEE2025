# backend/app.py

import os

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Keep if needed
SAVE_OCR_IMAGES = False  # Set to True to enable saving
OCR_IMAGE_SAVE_DIR = "ocr_debug_images"


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
from ultralytics import YOLO  # Using YOLO from ultralytics for YOLO-World


# --- Ollama Configuration ---
OLLAMA_MODEL_NAME = os.environ.get("OLLAMA_MODEL", "gemma3:12b")
OLLAMA_API_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434/api/generate")
OLLAMA_REQUEST_TIMEOUT = 60  # Seconds for Ollama request timeout

logger = logging.getLogger(__name__)  # Get logger instance early

logger.info(
    f"Ollama Configuration: Model='{OLLAMA_MODEL_NAME}', URL='{OLLAMA_API_URL}'"
)


if SAVE_OCR_IMAGES and not os.path.exists(OCR_IMAGE_SAVE_DIR):
    os.makedirs(OCR_IMAGE_SAVE_DIR)

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
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


# --- Tesseract Configuration ---
try:
    # Set path explicitly if needed (examples commented out)
    # pytesseract.pytesseract.tesseract_cmd = r'C:\Program Files\Tesseract-OCR\tesseract.exe' # Windows
    # Check if running inside Docker or specific environment
    if os.path.exists("/usr/bin/tesseract"):
        pytesseract.pytesseract.tesseract_cmd = (
            r"/usr/bin/tesseract"  # Common Linux path
        )
        logger.info("Using Tesseract path: /usr/bin/tesseract")
    elif os.path.exists("/home/linuxbrew/.linuxbrew/opt/tesseract/bin/tesseract"):
        pytesseract.pytesseract.tesseract_cmd = (
            r"/home/linuxbrew/.linuxbrew/opt/tesseract/bin/tesseract"  # macOS Brew
        )
        logger.info(
            "Using Tesseract path: /home/linuxbrew/.linuxbrew/opt/tesseract/bin/tesseract"
        )
    # Add more checks if needed (e.g., for Windows default path)
    # else:
    #    logger.warning("Tesseract path not explicitly set, relying on PATH.")

    tesseract_version = pytesseract.get_tesseract_version()
    logger.info(f"Tesseract OCR Engine Version: {tesseract_version}")
except pytesseract.TesseractNotFoundError:
    logger.error(
        "TesseractNotFoundError: Tesseract is not installed or not in your PATH/configured path."
    )
    # Optionally exit or disable OCR features if Tesseract is critical
    # sys.exit("Tesseract not found. Exiting.")
except Exception as e:
    logger.error(f"Error configuring Tesseract path or getting version: {e}")


# --- Database Configuration & Setup ---
DB_URI = os.environ.get(
    "DATABASE_URL", "mysql+pymysql://root:@127.0.0.1:3306/visualaiddb"
)
app.config["SQLALCHEMY_DATABASE_URI"] = DB_URI
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
app.config["SQLALCHEMY_ECHO"] = False
db = SQLAlchemy(app)


def test_db_connection():
    """Tests the database connection."""
    try:
        with app.app_context():
            with db.engine.connect() as connection:
                connection.execute(db.text("SELECT 1"))
                logger.info("Database connection successful!")
                return True
    except Exception as e:
        logger.error(f"Database connection failed: {e}", exc_info=False)
        return False


class User(db.Model):
    """Represents a user in the database."""

    __tablename__ = "users"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(255), nullable=False)
    email = db.Column(db.String(255), nullable=False, unique=True)
    password = db.Column(db.String(255), nullable=False)
    customization = db.Column(db.String(255), default="0" * 255)


with app.app_context():
    try:
        db.create_all()
        if not test_db_connection():
            logger.warning(
                "Database connection failed during startup. DB features may not work."
            )
    except Exception as e:
        logger.error(f"Error during initial DB setup: {e}", exc_info=True)


# --- ML Model Loading ---
logger.info("Loading ML models...")
try:
    # --- Load YOLO-World Model ---
    logger.info("Loading YOLO-World model...")
    # Using Medium Model for potentially better accuracy
    # Options: 'yolo_world_v2-s.pt', 'yolo_world_v2-m.pt', 'yolo_world_v2-l.pt'
    # yolo_model_path = 'yolov8x-worldv2.pt', you can download your preferred model from this link
    # https://huggingface.co/Bingsu/yolo-world-mirror/tree/main
    yolo_model_path = "yolov8x-worldv2.pt"
    yolo_model = YOLO(yolo_model_path)
    logger.info(f"YOLO-World model loaded from {yolo_model_path}.")

    # --- !!! IMPORTANT: Define the target classes for YOLO-World !!! ---
    # (Keep your existing TARGET_CLASSES list)
    TARGET_CLASSES = [
        # --- Standard COCO Classes ---
        "person",
        "bicycle",
        "car",
        "motorcycle",
        "airplane",
        "bus",
        "train",
        "truck",
        "boat",
        "traffic light",
        "fire hydrant",
        "stop sign",
        "parking meter",
        "bench",
        "bird",
        "cat",
        "dog",
        "horse",
        "sheep",
        "cow",
        "elephant",
        "bear",
        "zebra",
        "giraffe",
        "backpack",
        "umbrella",
        "handbag",
        "tie",
        "suitcase",
        "frisbee",
        "skis",
        "snowboard",
        "sports ball",
        "kite",
        "baseball bat",
        "baseball glove",
        "skateboard",
        "surfboard",
        "tennis racket",
        "bottle",
        "wine glass",
        "cup",
        "fork",
        "knife",
        "spoon",
        "bowl",
        "banana",
        "apple",
        "sandwich",
        "orange",
        "broccoli",
        "carrot",
        "hot dog",
        "pizza",
        "donut",
        "cake",
        "chair",
        "couch",
        "potted plant",
        "bed",
        "dining table",
        "toilet",
        "tv",
        "laptop",
        "mouse",
        "remote",
        "keyboard",
        "cell phone",
        "microwave",
        "oven",
        "toaster",
        "sink",
        "refrigerator",
        "book",
        "clock",
        "vase",
        "scissors",
        "teddy bear",
        "hair drier",
        "toothbrush",
        # --- Add MORE classes relevant to your application ---
        "traffic cone",
        "pen",
        "stapler",
        "monitor",
        "speaker",
        "desk lamp",
        "trash can",
        "bin",
        "stairs",
        "door",
        "window",
        "picture frame",
        "whiteboard",
        "projector",
        "ceiling fan",
        "pillow",
        "blanket",
        "towel",
        "soap",
        "shampoo",
        "power outlet",
        "light switch",
        "screwdriver",
        "hammer",
        "wrench",
        "pliers",
        "wheelchair",
        "crutches",
        "walker",
        "cane",
        "plate",
        "mug",
        "wallet",
        "keys",
        "glasses",
        "sunglasses",
        "watch",
        "jacket",
        "shirt",
        "pants",
        "shorts",
        "shoes",
        "hat",
        "gloves",
        "scarf",
        "computer monitor",
        "desk",
        "cabinet",
        "shelf",
        "drawer",
        "curtain",
        "radiator",
        "air conditioner",
        "fan",
        "newspaper",
        "magazine",
        "letter",
        "envelope",
        "box",
        "bag",
        "basket",
        "mop",
        "broom",
        "bucket",
        "fire extinguisher",
        "first aid kit",
        "exit sign",
        "ramp",
        "elevator",
        "escalator",
        # ... continue adding potentially hundreds of relevant classes ...
        "lion",
        "tiger",
        "leopard",
        "elephant",
        "giraffe",
        "zebra",
        "horse",
        "donkey",
        "mule",
        "goat",
        "sheep",
        "cow",
        "pig",
        "duck",
        "turkey",
        "chicken",
        "dog",
        "cat",
        "rabbit",
        "fish",
        "bird",
        "turtle",
        "frog",
        "toad",
        "snake",
        "lizard",
        "spider",
        "insect",
        "crab",
        "lobster",
        "octopus",
        "starfish",
        "shrimp",
        "squid",
        "clam",
        "oyster",
        "mussel",
        "scallop",
        "whale",
        "shark",
        "ray",
        "fishbowl",
        "aquarium",
        "pond",
        "lake",
        "river",
        "ocean",
        "beach",
        "ship",
        "boat",
        "submarine",
        "car",
        "truck",
        "bus",
        "train",
        "airplane",
        "helicopter",
        "bicycle",
        "motorcycle",
        "scooter",
        "wheelchair",
        "stroller",
        "skateboard",
        "rollerblades",
        "kayak",
        "canoe",
        "paddleboard",
        "bookshelf",
        "book",
        "magazine",
        "newspaper",
        "document",
        "paper",
        "folder",
        "file",
        "briefcase",
        "laptop",
        "computer",
        "tablet",
        "smartphone",
        "phone",
        "headphones",
        "speaker",
        "microphone",
        "keyboard",
        "mouse",
        "monitor",
        "printer",
        "scanner",
        "fax",
        "copier",
        "camera",
        "video camera",
        "television",
        "projector",
        "screen",
        "DVD",
        "CD",
        "video game",
        "controller",
        "guitar",
        "piano",
    ]
    logger.info(f"Setting {len(TARGET_CLASSES)} target classes for YOLO-World.")
    yolo_model.set_classes(TARGET_CLASSES)
    logger.info("YOLO-World classes set.")

    # --- Load Places365 Model (Scene Classification) ---
    def load_places365_model():
        logger.info("Loading Places365 model...")
        model = models.resnet50(weights=None)
        model.fc = torch.nn.Linear(model.fc.in_features, 365)
        weights_filename = "resnet50_places365.pth.tar"
        weights_url = (
            "http://places2.csail.mit.edu/models_places365/resnet50_places365.pth.tar"
        )
        if not os.path.exists(weights_filename):
            logger.info(f"Downloading Places365 weights to {weights_filename}...")
            try:
                response = requests.get(weights_url, timeout=120)
                response.raise_for_status()
                with open(weights_filename, "wb") as f:
                    f.write(response.content)
                logger.info("Places365 weights downloaded.")
            except requests.exceptions.RequestException as req_e:
                logger.error(f"Failed to download Places365 weights: {req_e}")
                raise
        else:
            logger.debug(f"Found existing Places365 weights at {weights_filename}.")
        try:
            checkpoint = torch.load(weights_filename, map_location=torch.device("cpu"))
            state_dict = checkpoint.get("state_dict", checkpoint)
            state_dict = {k.replace("module.", ""): v for k, v in state_dict.items()}
            model.load_state_dict(state_dict)
            logger.info("Places365 model weights loaded.")
            model.eval()
            return model
        except Exception as load_e:
            logger.error(f"Error loading Places365 weights: {load_e}", exc_info=True)
            raise

    places_model = load_places365_model()

    # --- Load Places365 Labels ---
    logger.info("Loading Places365 labels...")
    places_labels = []
    places_labels_filename = "categories_places365.txt"
    places_labels_url = "https://raw.githubusercontent.com/csailvision/places365/master/categories_places365.txt"
    try:
        if not os.path.exists(places_labels_filename):
            logger.info(f"Downloading Places365 labels to {places_labels_filename}...")
            response = requests.get(places_labels_url, timeout=30)
            response.raise_for_status()
            with open(places_labels_filename, "w", encoding="utf-8") as f:
                f.write(response.text)
            logger.info("Downloaded Places365 labels.")
        else:
            logger.debug(
                f"Using cached Places365 labels from {places_labels_filename}."
            )
        with open(places_labels_filename, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    parts = line.strip().split(" ")
                    label = parts[0].split("/")[-1]
                    places_labels.append(label)
        if len(places_labels) != 365:
            logger.warning(
                f"Loaded {len(places_labels)} Places365 labels (expected 365)."
            )
        logger.info(f"Loaded {len(places_labels)} Places365 labels.")
    except Exception as e:
        logger.error(f"Failed to load Places365 labels: {e}", exc_info=True)
        places_labels = [f"Label {i}" for i in range(365)]
        logger.warning("Using fallback Places365 labels.")

    # --- Tesseract Supported Languages ---
    try:
        installed_langs = pytesseract.get_languages(config="")
        SUPPORTED_OCR_LANGS = set(installed_langs)
        logger.info(f"Dynamically detected Tesseract languages: {SUPPORTED_OCR_LANGS}")
    except Exception as e:
        logger.warning(
            f"Could not dynamically get Tesseract languages ({e}). Using predefined list."
        )
        SUPPORTED_OCR_LANGS = {
            "eng",
            "ara",
            "fas",
            "urd",
            "uig",
            "hin",
            "mar",
            "nep",
            "rus",
            "chi_sim",
            "chi_tra",
            "jpn",
            "kor",
            "tel",
            "kan",
            "ben",
        }
    DEFAULT_OCR_LANG = "eng"
    if DEFAULT_OCR_LANG not in SUPPORTED_OCR_LANGS:
        logger.warning(
            f"Default OCR Lang '{DEFAULT_OCR_LANG}' not in detected/defined list {SUPPORTED_OCR_LANGS}. OCR might fail."
        )

    logger.info(f"Default Tesseract OCR language: {DEFAULT_OCR_LANG}")

    # --- Image Transforms for Scene Classification ---
    scene_transform = transforms.Compose(
        [
            transforms.Resize((256, 256)),
            transforms.CenterCrop(224),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ]
    )

    logger.info("All ML models and configurations loaded successfully.")

except SystemExit as se:
    logger.critical(str(se))
    sys.exit(1)
except FileNotFoundError as fnf_e:
    logger.critical(f"Required model file not found: {fnf_e}", exc_info=False)
    sys.exit(f"Missing file: {fnf_e}")
except Exception as e:
    logger.critical(f"FATAL ERROR DURING MODEL LOADING: {e}", exc_info=True)
    sys.exit(f"Failed model load: {e}")


# --- Detection Functions ---


def detect_objects(image_np):
    """
    Detects objects using YOLO-World and returns up to MAX_OBJECTS_TO_RETURN
    object names, sorted by confidence.

    Args:
        image_np (numpy.ndarray): The input image in BGR format (from OpenCV).

    Returns:
        str: A comma-separated string of the most confident detected object names
             (up to the limit), "No objects detected", or an error message.
    """
    # --- !!! CONTROL PARAMETER: Max number of objects to return !!! ---
    MAX_OBJECTS_TO_RETURN = 3  # Adjust this number as needed (e.g., 1, 3, 5)
    # --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

    try:
        img_rgb = cv2.cvtColor(image_np, cv2.COLOR_BGR2RGB)
        img_pil = Image.fromarray(img_rgb)

        # Perform inference - adjust confidence threshold as needed
        results = yolo_model.predict(img_pil, conf=0.5, verbose=False)

        detections_with_confidence = []  # List to store (confidence, name) tuples

        # Process results if any detections were made
        if results and results[0].boxes:
            boxes = results[0].boxes
            class_id_to_name = results[0].names  # Get class name mapping

            for box in boxes:
                confidence = float(box.conf[0])  # Get confidence score
                class_id = int(box.cls[0])  # Get class index

                if class_id in class_id_to_name:
                    class_name = class_id_to_name[class_id]
                    detections_with_confidence.append((confidence, class_name))
                else:
                    logger.warning(
                        f"Detected class ID {class_id} (conf: {confidence:.2f}) not in names map."
                    )

        # --- Sort, Limit, and Format ---
        if not detections_with_confidence:
            logger.debug("Object detection: No objects found above threshold.")
            return "No objects detected"
        else:
            # Sort by confidence in descending order (highest first)
            detections_with_confidence.sort(key=lambda x: x[0], reverse=True)

            # Limit the number of results
            top_detections = detections_with_confidence[:MAX_OBJECTS_TO_RETURN]

            # Extract just the names
            top_object_names = [name for conf, name in top_detections]

            result_str = ", ".join(top_object_names)
            # Log the top results with confidence for debugging
            log_details = ", ".join(
                [f"{name}({conf:.2f})" for conf, name in top_detections]
            )
            logger.debug(
                f"Object detection top {len(top_object_names)} results: {log_details}"
            )
            return result_str
        # --- --- --- --- --- --- --- ---

    except Exception as e:
        logger.error(f"Error during YOLO-World object detection: {e}", exc_info=True)
        return "Error in object detection"


def detect_scene(image_np):
    """Classifies the scene using Places365 model."""
    try:
        # Ensure image is RGB
        if image_np.shape[2] == 3:
            img_rgb = cv2.cvtColor(image_np, cv2.COLOR_BGR2RGB)
        else:
            logger.warning(
                "Input image for scene detection was not BGR, attempting conversion."
            )
            img_rgb = cv2.cvtColor(
                image_np,
                cv2.COLOR_GRAY2RGB if len(image_np.shape) == 2 else cv2.COLOR_BGRA2RGB,
            )

        img_pil = Image.fromarray(img_rgb)
        img_tensor = scene_transform(img_pil).unsqueeze(0)

        # Move tensor to the same device as the model
        device = next(places_model.parameters()).device
        img_tensor = img_tensor.to(device)

        with torch.no_grad():
            outputs = places_model(img_tensor)
            probabilities = torch.softmax(outputs, dim=1)[0]
            top_prob, top_catid = torch.max(probabilities, 0)

            predicted_index = top_catid.item()
            if 0 <= predicted_index < len(places_labels):
                predicted_label = places_labels[predicted_index].replace(
                    "_", " "
                )  # Replace underscores
                confidence = top_prob.item()
                result_str = f"{predicted_label}"  # Just return label name
                logger.debug(
                    f"Scene detection complete: {predicted_label} (Conf: {confidence:.3f})"
                )
                return result_str
            else:
                logger.warning(
                    f"Places365 predicted index {predicted_index} out of bounds (0-{len(places_labels)-1})."
                )
                return "Unknown Scene"
    except Exception as e:
        logger.error(f"Error during scene detection: {e}", exc_info=True)
        return "Error in scene detection"


def detect_text(image_np, language_code=DEFAULT_OCR_LANG):
    """Performs OCR using Tesseract."""
    logger.debug(f"Starting Tesseract OCR for lang: '{language_code}'...")

    # Validate language against actually available ones
    validated_lang = language_code
    if language_code not in SUPPORTED_OCR_LANGS:
        logger.warning(
            f"Requested lang '{language_code}' not in supported list {SUPPORTED_OCR_LANGS}. Falling back to '{DEFAULT_OCR_LANG}'."
        )
        validated_lang = DEFAULT_OCR_LANG
        # Double-check if even the default is available
        if validated_lang not in SUPPORTED_OCR_LANGS:
            logger.error(
                f"Default language '{DEFAULT_OCR_LANG}' is also not available. OCR cannot proceed."
            )
            return "Error: OCR Language Not Available"

    if SAVE_OCR_IMAGES:
        try:
            timestamp = time.strftime("%Y%m%d-%H%M%S")
            filename = os.path.join(
                OCR_IMAGE_SAVE_DIR,
                f"ocr_input_{timestamp}_{validated_lang}.png",  # Use validated lang in filename
            )
            # Ensure image is savable (e.g., BGR)
            save_img = image_np
            if len(image_np.shape) == 3 and image_np.shape[2] == 4:  # BGRA
                save_img = cv2.cvtColor(image_np, cv2.COLOR_BGRA2BGR)
            elif len(image_np.shape) == 2:  # Grayscale
                save_img = cv2.cvtColor(image_np, cv2.COLOR_GRAY2BGR)

            cv2.imwrite(filename, save_img)
            logger.debug(f"Saved OCR input image to: {filename}")
        except Exception as save_e:
            logger.error(f"Failed to save debug OCR image: {save_e}")

    try:
        # Tesseract generally works better with grayscale images
        if len(image_np.shape) == 3:
            gray_img = cv2.cvtColor(image_np, cv2.COLOR_BGR2GRAY)
        else:
            gray_img = image_np  # Assume it's already grayscale if not 3 channels

        # Optional: Apply some basic preprocessing for potentially better OCR
        # gray_img = cv2.threshold(gray_img, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1]
        # gray_img = cv2.medianBlur(gray_img, 3)

        img_pil = Image.fromarray(gray_img)  # Use grayscale PIL image

        # Specify OEM and PSM modes if needed, e.g., '--oem 3 --psm 6'
        custom_config = f"-l {validated_lang} --oem 3 --psm 6"
        logger.debug(f"Using Tesseract config: {custom_config}")
        detected_text = pytesseract.image_to_string(img_pil, config=custom_config)

        result_str = detected_text.strip()
        if not result_str:
            logger.debug(f"Tesseract ({validated_lang}): No text found.")
            return "No text detected"
        else:
            # Clean up common OCR noise (e.g., excessive newlines/spaces)
            result_str = "\n".join(
                [line.strip() for line in result_str.splitlines() if line.strip()]
            )
            log_text = result_str.replace("\n", " ").replace("\r", "")[:100]
            logger.debug(f"Tesseract ({validated_lang}) OK: Found '{log_text}...'")
            return result_str
    except pytesseract.TesseractNotFoundError:
        logger.error("Tesseract executable not found at configured path or in PATH.")
        return "Error: OCR Engine Not Found"
    except pytesseract.TesseractError as tess_e:
        logger.error(f"TesseractError ({validated_lang}): {tess_e}", exc_info=False)
        error_str = str(tess_e).lower()
        # Check for specific error messages indicating missing language data
        if (
            "failed loading language" in error_str
            or "could not initialize tesseract" in error_str
            or "data file not found" in error_str
            or f"load_system_dawg" in error_str  # Sometimes related to lang data
        ):
            logger.error(
                f"Missing Tesseract language data for '{validated_lang}'. Install the necessary package (e.g., tesseract-ocr-{validated_lang} on Debian/Ubuntu, or equivalent)."
            )
            # Don't automatically fallback here, as the fundamental issue is missing data pack.
            return f"Error: Missing OCR language data for '{validated_lang}'"
        else:
            # General Tesseract error
            return f"Error during text detection ({validated_lang})"
    except Exception as e:
        logger.error(f"Unexpected OCR error ({validated_lang}): {e}", exc_info=True)
        return f"Error during text detection ({validated_lang})"


# --- Helper Function for Ollama Interaction ---
def get_llm_feature_choice(image_np, client_sid="Unknown"):
    """
    Sends image to Ollama multimodal model and asks it to choose a feature.

    Args:
        image_np (numpy.ndarray): The input image (BGR format from OpenCV).
        client_sid (str): Identifier for logging.

    Returns:
        str: The chosen feature ID ('object_detection', 'scene_detection', 'text_detection')
             or None if failed.
    """
    logger.info(
        f"[{client_sid}] Requesting feature choice from Ollama ({OLLAMA_MODEL_NAME})..."
    )
    start_time = time.time()

    try:
        # 1. Encode image to Base64
        # Convert BGR numpy array back to image bytes (e.g., JPEG) then base64 encode
        is_success, buffer = cv2.imencode(".jpg", image_np)
        if not is_success:
            logger.error(f"[{client_sid}] Failed to encode image to JPEG for Ollama.")
            return None
        image_bytes = buffer.tobytes()
        image_base64 = base64.b64encode(image_bytes).decode("utf-8")

        # 2. Construct the prompt
        # Prompt asks the LLM to choose *only* the most relevant function ID
        prompt = (
            "Analyze the provided image. Based *only* on the main content, "
            "which of the following analysis types is MOST appropriate? "
            "Choose exactly ONE:\n"
            "- 'object_detection': If the image focuses on identifying specific items or objects.\n"
            "- 'hazard_detection': If the image focuses on identifying potentially hazardous or dangerous items or objects for a vision impaired person. For example, a stop sign. \n"
            "- 'scene_detection': If the image primarily shows an overall environment, location, or setting.\n"
            "- 'text_detection': If the image contains significant readable text (like a document, sign, or label).\n"
            "Respond with ONLY the chosen identifier string (e.g., 'scene_detection') and nothing else."
        )

        # 3. Prepare the request payload for Ollama /api/generate
        payload = {
            "model": OLLAMA_MODEL_NAME,
            "prompt": prompt,
            "images": [image_base64],
            "stream": False,  # Get the full response at once
            # Options can fine-tune behavior (e.g., temperature=0.3 for more deterministic choice)
            "options": {"temperature": 0.3},
        }

        # 4. Send the request to Ollama
        logger.debug(f"[{client_sid}] Sending request to Ollama: {OLLAMA_API_URL}")
        response = requests.post(
            OLLAMA_API_URL,
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=OLLAMA_REQUEST_TIMEOUT,
        )
        response.raise_for_status()  # Raise HTTPError for bad responses (4xx or 5xx)

        # 5. Process the response
        response_data = response.json()
        llm_response_text = response_data.get("response", "").strip().lower()
        logger.debug(f"[{client_sid}] Raw response from Ollama: '{llm_response_text}'")

        # 6. Extract the choice (be robust)
        chosen_feature = None
        valid_features = [
            "object_detection",
            "hazard_detection",
            "scene_detection",
            "text_detection",
        ]

        # Try direct match first (ideal case)
        if llm_response_text in valid_features:
            chosen_feature = llm_response_text
        else:
            # If LLM added extra text, try finding the keyword
            logger.warning(
                f"[{client_sid}] Ollama response wasn't an exact feature ID ('{llm_response_text}'). Searching for keywords."
            )
            for feature in valid_features:
                if f"'{feature}'" in llm_response_text or feature in llm_response_text:
                    # Basic check if it contains the feature name, might need refinement
                    # Example: If response is "I choose 'scene_detection'.", this should find it.
                    # Be careful not to misinterpret, e.g. if it says "don't use object_detection"
                    # A more robust approach might involve asking the LLM to format as JSON.
                    if chosen_feature is None:  # Take the first match found
                        chosen_feature = feature
                        logger.info(
                            f"[{client_sid}] Found keyword '{feature}' in Ollama response."
                        )
                    else:
                        logger.warning(
                            f"[{client_sid}] Found multiple keywords in Ollama response. Using first match: '{chosen_feature}'. Full response: '{llm_response_text}'"
                        )
                        break  # Stop after finding the first conflicting match

        if chosen_feature:
            elapsed_time = time.time() - start_time
            logger.info(
                f"[{client_sid}] Ollama chose feature: '{chosen_feature}' in {elapsed_time:.2f}s."
            )
            return chosen_feature
        else:
            logger.error(
                f"[{client_sid}] Failed to extract a valid feature choice from Ollama response: '{llm_response_text}'"
            )
            return None

    except requests.exceptions.Timeout:
        logger.error(
            f"[{client_sid}] Ollama request timed out after {OLLAMA_REQUEST_TIMEOUT} seconds."
        )
        return None
    except requests.exceptions.ConnectionError:
        logger.error(
            f"[{client_sid}] Could not connect to Ollama at {OLLAMA_API_URL}. Is Ollama running?"
        )
        return None
    except requests.exceptions.RequestException as req_e:
        logger.error(
            f"[{client_sid}] Error during Ollama API request: {req_e}", exc_info=True
        )
        # Log response body if available and indicates an error
        if req_e.response is not None:
            try:
                logger.error(
                    f"[{client_sid}] Ollama response body (error): {req_e.response.text}"
                )
            except Exception:
                pass  # Ignore errors reading the error response body
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
    """Handles new client connections."""
    logger.info(f"Client connected: {request.sid}")
    emit("response", {"result": "Connected to VisionAid backend", "event": "connect"})


@socketio.on("disconnect")
def handle_disconnect():
    """Handles client disconnections."""
    logger.info(f"Client disconnected: {request.sid}")


@socketio.on("message")
def handle_message(data):
    """Handles incoming messages for detection."""
    client_sid = request.sid
    start_time = time.time()
    detection_type = "unknown"
    request_type_from_payload = None
    final_response = None

    try:
        if not isinstance(data, dict):
            logger.warning(f"Invalid data format from {client_sid}. Expected dict.")
            emit("response", {"result": "Error: Invalid data format"})
            return

        image_data = data.get("image")
        detection_type = data.get("type")  # e.g., 'object_detection', 'supervision'
        request_type_from_payload = data.get("request_type")  # e.g., 'llm_route'

        if not image_data or not detection_type:
            logger.warning(f"Missing 'image' or 'type' from {client_sid}.")
            emit("response", {"result": "Error: Missing 'image' or 'type'"})
            return

        # --- Image Decoding ---
        try:
            if image_data.startswith("data:image"):
                header, encoded = image_data.split(",", 1)
            else:
                encoded = image_data  # Assume raw base64 if no header
            image_bytes = base64.b64decode(encoded)
            image_np = cv2.imdecode(
                np.frombuffer(image_bytes, np.uint8), cv2.IMREAD_COLOR  # Load as BGR
            )
            if image_np is None:
                raise ValueError(
                    "cv2.imdecode returned None. Invalid image data or format."
                )
            logger.debug(
                f"[{client_sid}] Image decoded successfully. Shape: {image_np.shape}"
            )
        except (base64.binascii.Error, ValueError) as decode_err:
            logger.error(f"Image decode error for {client_sid}: {decode_err}")
            emit("response", {"result": "Error: Invalid image data"})
            return
        except Exception as decode_e:
            logger.error(
                f"Unexpected image decode error for {client_sid}: {decode_e}",
                exc_info=True,
            )
            emit("response", {"result": "Error: Could not process image"})
            return

        # --- Routing Logic ---
        if detection_type == "supervision" and request_type_from_payload == "llm_route":
            logger.info(
                f"Handling SuperVision LLM routing request from {client_sid}..."
            )

            # --- Call Ollama to choose the feature ---
            chosen_feature_id = get_llm_feature_choice(image_np, client_sid)

            if chosen_feature_id:
                logger.info(
                    f"[{client_sid}] Ollama selected feature: {chosen_feature_id}. Running detection..."
                )
                result_from_chosen_model = "Error: Feature execution failed"
                try:
                    if chosen_feature_id == "object_detection":
                        result_from_chosen_model = detect_objects(image_np)
                    elif chosen_feature_id == "hazard_detection":
                        result_from_chosen_model = detect_objects(image_np)
                    elif chosen_feature_id == "scene_detection":
                        result_from_chosen_model = detect_scene(image_np)
                    elif chosen_feature_id == "text_detection":
                        # For LLM-chosen text detection, use default language initially.
                        # Future: Could try to get lang hint from LLM too.
                        result_from_chosen_model = detect_text(
                            image_np, DEFAULT_OCR_LANG
                        )
                    else:
                        # Should not happen if get_llm_feature_choice validates
                        logger.error(
                            f"[{client_sid}] Invalid feature '{chosen_feature_id}' returned by LLM function."
                        )
                        result_from_chosen_model = "Error: Invalid analysis type chosen"

                    # Format response for SuperVision
                    final_response = {
                        "result": result_from_chosen_model,
                        "feature_id": chosen_feature_id,
                        "is_from_supervision_llm": True,
                    }
                except Exception as exec_e:
                    logger.error(
                        f"[{client_sid}] Error executing selected feature '{chosen_feature_id}': {exec_e}",
                        exc_info=True,
                    )
                    final_response = {
                        "result": f"Error running {chosen_feature_id}",
                        "feature_id": chosen_feature_id,  # Still report what was attempted
                        "is_from_supervision_llm": True,
                    }
            else:
                # Ollama interaction failed (timeout, connection error, bad response etc.)
                logger.error(
                    f"[{client_sid}] Failed to get feature choice from Ollama."
                )
                final_response = {
                    "result": "Error: Smart analysis failed (LLM unavailable or error)",
                    "feature_id": "supervision_error",
                    "is_from_supervision_llm": True,
                }
            # --- End Ollama Interaction ---

        else:
            # --- Handle DIRECT feature requests (Object, Scene, Text) ---
            logger.info(
                f"Processing direct request '{detection_type}' from {client_sid}"
            )
            result = "Error: Unknown processing error"
            requested_language = DEFAULT_OCR_LANG

            if detection_type == "object_detection":
                result = detect_objects(image_np)
            elif detection_type == "scene_detection":
                result = detect_scene(image_np)
            elif detection_type == "text_detection":
                requested_language_from_payload = data.get(
                    "language", DEFAULT_OCR_LANG
                ).lower()
                # Validate requested language
                if requested_language_from_payload not in SUPPORTED_OCR_LANGS:
                    logger.warning(
                        f"Client {client_sid} requested invalid/unsupported lang '{requested_language_from_payload}'. Using '{DEFAULT_OCR_LANG}'."
                    )
                    requested_language = DEFAULT_OCR_LANG
                else:
                    requested_language = requested_language_from_payload
                logger.info(
                    f"[{client_sid}] Processing Text Detection with lang: '{requested_language}'"
                )
                result = detect_text(image_np, language_code=requested_language)
            # elif detection_type == "hazard_detection": # Example for future direct type
            #     logger.warning(f"Hazard detection is not yet implemented as a direct function. Use SuperVision.")
            #     result = "Error: Hazard detection unavailable directly"
            else:
                logger.warning(
                    f"Unsupported direct type '{detection_type}' received from {client_sid}"
                )
                result = f"Error: Unsupported analysis type '{detection_type}'"

            final_response = {
                "result": result,
                "feature_id": detection_type,
                # Explicitly set to false for direct requests
                "is_from_supervision_llm": False,
            }

        # --- Emit the final response ---
        if final_response:
            processing_time = time.time() - start_time
            log_result = str(final_response.get("result", "N/A"))
            log_result_short = (
                (log_result[:150] + "...") if len(log_result) > 150 else log_result
            )
            log_type = final_response.get("feature_id", detection_type)
            log_origin = (
                "Supervision(LLM)"
                if final_response.get("is_from_supervision_llm")
                else "Direct"
            )

            logger.info(
                f"Completed '{log_type}' ({log_origin}) for {client_sid} in {processing_time:.3f}s. Result: '{log_result_short}'"
            )
            emit("response", final_response)
        else:
            # This case should ideally be handled by error paths setting a final_response
            logger.error(
                f"[{client_sid}] Failed to generate a response object for type '{detection_type}'. This indicates a code flow error."
            )
            emit("response", {"result": "Server Error: Failed to process request."})

    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(
            f"Unhandled error processing message (type: '{detection_type}') for {client_sid} after {processing_time:.3f}s: {e}",
            exc_info=True,
        )
        try:
            # Try to send a generic error
            error_response = {"result": f"Server Error: An unexpected error occurred."}
            # Try to mark it as supervision if context suggests it
            if (
                detection_type == "supervision"
                and request_type_from_payload == "llm_route"
            ):
                error_response["feature_id"] = "supervision_error"
                error_response["is_from_supervision_llm"] = True
            else:
                error_response["feature_id"] = (
                    "general_error"  # Or use original detection_type
                )
                error_response["is_from_supervision_llm"] = False

            emit("response", error_response)
        except Exception as emit_e:
            logger.error(
                f"Failed to emit final error response to {client_sid}: {emit_e}"
            )


# --- Old Test page handlers (Keep empty or implement if test.html is used) ---
@socketio.on("detect-objects")
def handle_detect_objects_test(data):
    logger.warning(
        "Received 'detect-objects' event (likely from test.html) - handler not implemented."
    )
    pass


@socketio.on("detect-scene")
def handle_detect_scene_test(data):
    logger.warning(
        "Received 'detect-scene' event (likely from test.html) - handler not implemented."
    )
    pass


@socketio.on("ocr")
def handle_ocr_test(data):
    logger.warning(
        "Received 'ocr' event (likely from test.html) - handler not implemented."
    )
    pass


# --- Default SocketIO Error Handler ---
@socketio.on_error_default
def default_error_handler(e):
    client_sid = request.sid if request else "Unknown"
    logger.error(f"Unhandled WebSocket Error for SID {client_sid}: {e}", exc_info=True)
    try:
        if client_sid != "Unknown":
            emit(
                "response",
                {
                    "result": f"Server Error: Internal WebSocket error. Please reconnect or try again."
                },
                room=client_sid,
            )
    except Exception as emit_err:
        logger.error(
            f"Failed to emit default error response to {client_sid}: {emit_err}"
        )


# --- HTTP Routes (Keep placeholders or implement fully) ---
@app.route("/")
def home():
    # Point to the test page if it exists, otherwise simple message
    test_html_path = os.path.join(template_dir, "test.html")
    if os.path.exists(test_html_path):
        logger.info("Serving test.html for root request.")
        return render_template("test.html")
    else:
        logger.info("Serving basic status message for root request.")
        return "VisionAid Backend is running. Connect via WebSocket."


# --- Database Routes (Placeholders - Implement if needed) ---
@app.route("/update_customization", methods=["POST"])
def update_customization():
    logger.warning("Received request to unimplemented route: /update_customization")
    return jsonify({"error": "Not implemented"}), 501


@app.route("/get_user_info", methods=["GET"])
def get_user_info():
    logger.warning("Received request to unimplemented route: /get_user_info")
    return jsonify({"error": "Not implemented"}), 501


@app.route("/add_test_user", methods=["POST"])
def add_test_user():
    logger.warning("Received request to unimplemented route: /add_test_user")
    return jsonify({"error": "Not implemented"}), 501


# --- Main Execution Point ---
if __name__ == "__main__":
    logger.info("Starting VisionAid Flask-SocketIO server...")
    host_ip = os.environ.get("FLASK_HOST", "0.0.0.0")
    port_num = int(os.environ.get("FLASK_PORT", 5000))
    debug_mode = os.environ.get("FLASK_DEBUG", "False").lower() in ("true", "1", "t")
    use_reloader = debug_mode

    # Log effective settings
    logger.info(f" * Environment: {'development' if debug_mode else 'production'}")
    logger.info(f" * Debug Mode: {debug_mode}")
    logger.info(f" * Reloader: {use_reloader}")
    logger.info(f" * Running on: http://{host_ip}:{port_num}")
    logger.info(f" * WebSocket transport: enabled")
    logger.info(f" * Ollama Model: {OLLAMA_MODEL_NAME}")
    logger.info(f" * Ollama URL: {OLLAMA_API_URL}")

    try:
        socketio.run(
            app,
            host=host_ip,
            port=port_num,
            debug=debug_mode,
            use_reloader=use_reloader,
            allow_unsafe_werkzeug=(True if use_reloader else False),
        )
    except OSError as os_e:
        if "Address already in use" in str(os_e):
            logger.critical(
                f"Port {port_num} is already in use on {host_ip}. Stop the other process or use a different port."
            )
        else:
            logger.critical(
                f"Failed to start server due to OS Error: {os_e}", exc_info=True
            )
        sys.exit(1)
    except Exception as run_e:
        logger.critical(f"Failed to start server: {run_e}", exc_info=True)
        sys.exit(1)
    finally:
        logger.info("VisionAid server shutdown.")
