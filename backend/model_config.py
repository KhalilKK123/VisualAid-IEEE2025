import os

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


# --- Ollama Configuration ---
OLLAMA_MODEL_NAME = os.environ.get("OLLAMA_MODEL", "gemma3:12b")
OLLAMA_API_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434/api/generate")
OLLAMA_REQUEST_TIMEOUT = 60

# --- Debug Configuration ---
SAVE_OCR_IMAGES = False
OCR_IMAGE_SAVE_DIR = "ocr_debug_images"

if SAVE_OCR_IMAGES and not os.path.exists(OCR_IMAGE_SAVE_DIR):
    os.makedirs(OCR_IMAGE_SAVE_DIR)

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

logger.info(
    f"Ollama Configuration: Model='{OLLAMA_MODEL_NAME}', URL='{OLLAMA_API_URL}'"
)

# --- Tesseract Configuration ---
try:
    if os.path.exists("/usr/bin/tesseract"):
        pytesseract.pytesseract.tesseract_cmd = r"/usr/bin/tesseract"
        logger.info("Using Tesseract path: /usr/bin/tesseract")
    elif os.path.exists("/opt/homebrew/bin/tesseract"):
        pytesseract.pytesseract.tesseract_cmd = r"/opt/homebrew/bin/tesseract"
        logger.info("Using Tesseract path: /opt/homebrew/bin/tesseract")
    elif os.path.exists("/usr/local/bin/tesseract"):
        pytesseract.pytesseract.tesseract_cmd = r"/usr/local/bin/tesseract"
        logger.info("Using Tesseract path: /usr/local/bin/tesseract")
    elif os.path.exists(r"C:\Program Files\Tesseract-OCR\tesseract.exe"):
        pytesseract.pytesseract.tesseract_cmd = (
            r"C:\Program Files\Tesseract-OCR\tesseract.exe"
        )
        logger.info(
            r"Using Tesseract path: C:\Program Files\Tesseract-OCR\tesseract.exe"
        )

    tesseract_version = pytesseract.get_tesseract_version()
    logger.info(f"Tesseract OCR Engine Version: {tesseract_version}")

    installed_langs = pytesseract.get_languages(config="")
    SUPPORTED_OCR_LANGS = set(installed_langs)
    logger.info(f"Dynamically detected Tesseract languages: {SUPPORTED_OCR_LANGS}")

except pytesseract.TesseractNotFoundError:
    logger.error(
        "TesseractNotFoundError: Tesseract is not installed or not in your PATH/configured path."
    )
    SUPPORTED_OCR_LANGS = {"eng"}
except Exception as e:
    logger.error(f"Error configuring Tesseract or getting languages: {e}")
    SUPPORTED_OCR_LANGS = {"eng"}

DEFAULT_OCR_LANG = "eng"
if DEFAULT_OCR_LANG not in SUPPORTED_OCR_LANGS and "eng" in SUPPORTED_OCR_LANGS:
    logger.warning(
        f"Default OCR Lang '{DEFAULT_OCR_LANG}' configured but 'eng' is available. Using 'eng'."
    )
    DEFAULT_OCR_LANG = "eng"
elif DEFAULT_OCR_LANG not in SUPPORTED_OCR_LANGS:
    logger.error(
        f"Default OCR Lang '{DEFAULT_OCR_LANG}' not in detected/defined list {SUPPORTED_OCR_LANGS}. OCR might fail if '{DEFAULT_OCR_LANG}' is requested and unavailable."
    )

# --- Constants ---
OBJECT_DETECTION_CONFIDENCE = 0.55
MAX_OBJECTS_TO_RETURN = 4
CURRENCY_DETECTION_CONFIDENCE = 0.6  # Adjustable confidence for your currency model
CURRENCY_MODEL_PATH = "Best.pt"  # Path to your trained currency model
CURRENCY_CLASS_NAMES_PATH = "aed_class_names.txt"  # Path to your class names file


# --- ML Model Loading ---
logger.info("Loading ML models...")
currency_model = None
currency_class_names = []

try:
    # --- Load YOLO-World Model ---
    logger.info("Loading YOLO-World model...")
    yolo_model_path = "models/yolov8x-worldv2.pt"
    yolo_model = YOLO(yolo_model_path)
    logger.info(f"YOLO-World model loaded from {yolo_model_path}.")

    TARGET_CLASSES = [  # Keeeping this extensive list as is
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
        "keys",
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
        "lion",
        "tiger",
        "leopard",
        "donkey",
        "mule",
        "goat",
        "pig",
        "duck",
        "turkey",
        "chicken",
        "rabbit",
        "fish",
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
        "submarine",
        "scooter",
        "stroller",
        "rollerblades",
        "kayak",
        "canoe",
        "paddleboard",
        "bookshelf",
        "document",
        "paper",
        "folder",
        "file",
        "briefcase",
        "tablet",
        "phone",
        "headphones",
        "microphone",
        "printer",
        "scanner",
        "fax",
        "copier",
        "camera",
        "video camera",
        "television",
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

    # --- Load Places365 Model ---
    def load_places365_model():
        logger.info("Loading Places365 model...")
        model = models.resnet50(weights=None)
        model.fc = torch.nn.Linear(model.fc.in_features, 365)
        weights_filename = "models/resnet50_places365.pth.tar"
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
    places_labels = []
    places_labels_filename = "models/categories_places365.txt"
    places_labels_url = "https://raw.githubusercontent.com/csailvision/places365/master/categories_places365.txt"
    try:
        if not os.path.exists(places_labels_filename):
            logger.info(f"Downloading Places365 labels to {places_labels_filename}...")
            response = requests.get(places_labels_url, timeout=30)
            response.raise_for_status()
            with open(places_labels_filename, "w", encoding="utf-8") as f:
                f.write(response.text)
            logger.info("Places365 labels downloaded.")
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
        places_labels = [f"Label {i}" for i in range(365)]  # Fallback
        logger.warning("Using fallback Places365 labels.")

    # --- Image Transforms for Scene Classification ---
    scene_transform = transforms.Compose(
        [
            transforms.Resize((256, 256)),
            transforms.CenterCrop(224),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ]
    )

    # --- Load Custom Currency Detection Model (Best.pt) ---
    if os.path.exists(CURRENCY_MODEL_PATH):
        logger.info(f"Loading custom currency model from: {CURRENCY_MODEL_PATH}")
        currency_model = YOLO(CURRENCY_MODEL_PATH)  # Assuming it's a YOLO model
        logger.info("Custom currency model loaded.")
        if os.path.exists(CURRENCY_CLASS_NAMES_PATH):
            try:
                with open(CURRENCY_CLASS_NAMES_PATH, "r") as f:
                    currency_class_names = [line.strip() for line in f if line.strip()]
                if currency_class_names:
                    logger.info(
                        f"Loaded {len(currency_class_names)} currency class names: {currency_class_names}"
                    )
                else:
                    logger.warning(
                        f"Currency class names file '{CURRENCY_CLASS_NAMES_PATH}' is empty."
                    )
            except Exception as e:
                logger.error(
                    f"Error loading currency class names from '{CURRENCY_CLASS_NAMES_PATH}': {e}"
                )
        else:
            logger.warning(
                f"Currency class names file not found: {CURRENCY_CLASS_NAMES_PATH}. Detection will use raw class IDs."
            )
    else:
        logger.error(f"Custom currency model NOT FOUND at: {CURRENCY_MODEL_PATH}")
        logger.warning("Currency detection feature will not be available.")

    logger.info("All ML models loaded (or attempted).")

except SystemExit as se:
    logger.critical(str(se))
    sys.exit(1)
except FileNotFoundError as fnf_e:
    logger.critical(f"Required model file not found: {fnf_e}", exc_info=False)
    sys.exit(f"Missing file: {fnf_e}")
except Exception as e:
    logger.critical(f"FATAL ERROR DURING MODEL LOADING: {e}", exc_info=True)
    sys.exit(f"Model load failed: {e}")
