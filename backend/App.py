# backend/app.py

import os
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE" # Keep if needed

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
import pytesseract # For OCR
import torchvision.models as models # For Places365
import torchvision.transforms as transforms # For Places365
import requests
import time
import sys
from ultralytics import YOLO # Using YOLO from ultralytics for YOLO-World

# --- Ollama Configuration ---
OLLAMA_MODEL_NAME = os.environ.get("OLLAMA_MODEL", "gemma3:12b") # Using as a common default
OLLAMA_API_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434/api/generate")
OLLAMA_REQUEST_TIMEOUT = 360  # Seconds for Ollama request timeout

# --- Debug Configuration ---
SAVE_OCR_IMAGES = False  # Set to True to enable saving OCR debug images
OCR_IMAGE_SAVE_DIR = "ocr_debug_images"

if SAVE_OCR_IMAGES and not os.path.exists(OCR_IMAGE_SAVE_DIR):
    os.makedirs(OCR_IMAGE_SAVE_DIR)
    
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

logger.info(
    f"Ollama Configuration: Model='{OLLAMA_MODEL_NAME}', URL='{OLLAMA_API_URL}'"
)

template_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'templates'))
app = Flask(__name__, template_folder=template_dir)
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", max_http_buffer_size=20 * 1024 * 1024, async_mode='threading')


# --- Tesseract Configuration ---
try:
    if os.path.exists("/usr/bin/tesseract"):
        pytesseract.pytesseract.tesseract_cmd = r"/usr/bin/tesseract"
        logger.info("Using Tesseract path: /usr/bin/tesseract")
    elif os.path.exists("/opt/homebrew/bin/tesseract"): # Common path for tesseract on M1/M2/M3 Macs via Homebrew
        pytesseract.pytesseract.tesseract_cmd = r"/opt/homebrew/bin/tesseract"
        logger.info("Using Tesseract path: /opt/homebrew/bin/tesseract")
    elif os.path.exists("/usr/local/bin/tesseract"): # Common path for tesseract on Intel Macs or Linux via Homebrew
        pytesseract.pytesseract.tesseract_cmd = r"/usr/local/bin/tesseract"
        logger.info("Using Tesseract path: /usr/local/bin/tesseract")
    elif os.path.exists(r'C:\Program Files\Tesseract-OCR\tesseract.exe'): # Windows default
        pytesseract.pytesseract.tesseract_cmd = r'C:\Program Files\Tesseract-OCR\tesseract.exe'
        logger.info(r"Using Tesseract path: C:\Program Files\Tesseract-OCR\tesseract.exe")
    
    tesseract_version = pytesseract.get_tesseract_version()
    logger.info(f"Tesseract OCR Engine Version: {tesseract_version}")
    
    installed_langs = pytesseract.get_languages(config="")
    SUPPORTED_OCR_LANGS = set(installed_langs)
    logger.info(f"Dynamically detected Tesseract languages: {SUPPORTED_OCR_LANGS}")

except pytesseract.TesseractNotFoundError: 
    logger.error("TesseractNotFoundError: Tesseract is not installed or not in your PATH/configured path.")
    SUPPORTED_OCR_LANGS = {'eng'} # Fallback
except Exception as e: 
    logger.error(f"Error configuring Tesseract or getting languages: {e}")
    SUPPORTED_OCR_LANGS = {'eng'} # Fallback

DEFAULT_OCR_LANG = 'eng'
if DEFAULT_OCR_LANG not in SUPPORTED_OCR_LANGS and 'eng' in SUPPORTED_OCR_LANGS:
    logger.warning(f"Default OCR Lang '{DEFAULT_OCR_LANG}' configured but 'eng' is available. Using 'eng'.")
    DEFAULT_OCR_LANG = 'eng'
elif DEFAULT_OCR_LANG not in SUPPORTED_OCR_LANGS:
     logger.error(f"Default OCR Lang '{DEFAULT_OCR_LANG}' not in detected/defined list {SUPPORTED_OCR_LANGS}. OCR might fail if '{DEFAULT_OCR_LANG}' is requested and unavailable.")


# --- Database Configuration & Setup ---
DB_URI = os.environ.get('DATABASE_URL', 'mysql+pymysql://root:@127.0.0.1:3306/visualaiddb')
app.config['SQLALCHEMY_DATABASE_URI'] = DB_URI
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['SQLALCHEMY_ECHO'] = False 
db = SQLAlchemy(app)

def test_db_connection():
    try:
        with app.app_context():
            with db.engine.connect() as connection: connection.execute(db.text("SELECT 1")); logger.info("DB connection OK!"); return True
    except Exception as e: logger.error(f"DB connection failed: {e}", exc_info=False); return False
class User(db.Model):
    __tablename__ = 'users'; id = db.Column(db.Integer, primary_key=True); name = db.Column(db.String(255), nullable=False); email = db.Column(db.String(255), nullable=False, unique=True); password = db.Column(db.String(255), nullable=False); customization = db.Column(db.String(255), default='0' * 255)
with app.app_context():
    try: 
        db.create_all()
        if not test_db_connection():
            logger.warning("Database connection failed during startup. DB features may not work.")
    except Exception as e: logger.error(f"Error during initial DB setup: {e}", exc_info=True)

# --- Constants ---
OBJECT_DETECTION_CONFIDENCE = 0.55
MAX_OBJECTS_TO_RETURN = 4 # Increased slightly from 3 for potentially richer SuperVision results


# --- ML Model Loading ---
logger.info("Loading ML models...")
try:
    # --- Load YOLO-World Model 
    logger.info("Loading YOLO-World model...")
    yolo_model_path = 'yolov8x-worldv2.pt' # Ensure this model is available
    yolo_model = YOLO(yolo_model_path)
    logger.info(f"YOLO-World model loaded from {yolo_model_path}.")


    TARGET_CLASSES = [
        'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck', 'boat',
        'traffic light', 'fire hydrant', 'stop sign', 'parking meter', 'bench', 'bird', 'cat', 'dog',
        'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe', 'backpack', 'umbrella',
        'handbag', 'tie', 'suitcase', 'frisbee', 'skis', 'snowboard', 'sports ball', 'kite',
        'baseball bat', 'baseball glove', 'skateboard', 'surfboard', 'tennis racket', 'bottle',
        'wine glass', 'cup', 'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple', 'sandwich',
        'orange', 'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair', 'couch',
        'potted plant', 'bed', 'dining table', 'toilet', 'tv', 'laptop', 'mouse', 'remote',
        'keyboard', 'cell phone', 'microwave', 'oven', 'toaster', 'sink', 'refrigerator', 'book',
        'clock', 'vase', 'scissors', 'teddy bear', 'hair drier', 'toothbrush', 'traffic cone', 
        'pen', 'stapler', 'monitor', 'speaker', 'desk lamp', 'trash can', 'bin', 'stairs', 'door', 
        'window', 'picture frame', 'whiteboard', 'projector', 'ceiling fan', 'pillow', 'blanket', 
        'towel', 'soap', 'shampoo', 'power outlet', 'light switch', 'keys', 'screwdriver', 'hammer',
        'wrench', 'pliers', 'wheelchair', 'crutches', 'walker', 'cane', 'plate', 'mug', 'wallet',
        'glasses', 'sunglasses', 'watch', 'jacket', 'shirt', 'pants', 'shorts', 'shoes', 'hat',
        'gloves', 'scarf', 'computer monitor', 'desk', 'cabinet', 'shelf', 'drawer', 'curtain',
        'radiator', 'air conditioner', 'fan', 'newspaper', 'magazine', 'letter', 'envelope',
        'box', 'bag', 'basket', 'mop', 'broom', 'bucket', 'fire extinguisher', 'first aid kit',
        'exit sign', 'ramp', 'elevator', 'escalator', 'lion', 'tiger', 'leopard', 'donkey', 'mule',
        'goat','pig', 'duck', 'turkey', 'chicken', 'rabbit', 'fish', 'turtle', 'frog', 'toad',
        'snake', 'lizard', 'spider', 'insect', 'crab', 'lobster', 'octopus', 'starfish', 'shrimp',
        'squid', 'clam', 'oyster', 'mussel', 'scallop', 'whale', 'shark', 'ray', 'fishbowl',
        'aquarium', 'pond', 'lake', 'river', 'ocean', 'beach', 'ship', 'submarine', 'scooter',
        'stroller', 'rollerblades', 'kayak', 'canoe', 'paddleboard', 'bookshelf', 'document',
        'paper', 'folder', 'file', 'briefcase', 'tablet', 'phone', 'headphones', 'microphone',
        'printer', 'scanner', 'fax', 'copier', 'camera', 'video camera', 'television',
        'screen', 'DVD', 'CD', 'video game', 'controller', 'guitar', 'piano'
    ]
    logger.info(f"Setting {len(TARGET_CLASSES)} target classes for YOLO-World.")
    yolo_model.set_classes(TARGET_CLASSES)
    logger.info("YOLO-World classes set.")

    # --- Load Places365 Model ---
    def load_places365_model():
        logger.info("Loading Places365 model..."); model = models.resnet50(weights=None); model.fc = torch.nn.Linear(model.fc.in_features, 365); weights_filename = 'resnet50_places365.pth.tar'; weights_url = 'http://places2.csail.mit.edu/models_places365/resnet50_places365.pth.tar'
        if not os.path.exists(weights_filename): 
            logger.info(f"Downloading Places365 weights to {weights_filename}..."); 
            try:
                response = requests.get(weights_url, timeout=120); response.raise_for_status(); 
                with open(weights_filename, 'wb') as f: f.write(response.content); 
                logger.info("Places365 weights downloaded.")
            except requests.exceptions.RequestException as req_e:
                logger.error(f"Failed to download Places365 weights: {req_e}"); raise
        else: logger.debug(f"Found existing Places365 weights at {weights_filename}.")
        try:
            checkpoint = torch.load(weights_filename, map_location=torch.device('cpu')); state_dict = checkpoint.get('state_dict', checkpoint); state_dict = {k.replace('module.', ''): v for k, v in state_dict.items()}; model.load_state_dict(state_dict); logger.info("Places365 model weights loaded."); model.eval(); return model
        except Exception as load_e: logger.error(f"Error loading Places365 weights: {load_e}", exc_info=True); raise
    places_model = load_places365_model()

    # --- Load Places365 Labels ---
    places_labels = []; places_labels_filename = 'categories_places365.txt'; places_labels_url = 'https://raw.githubusercontent.com/csailvision/places365/master/categories_places365.txt'
    try:
        if not os.path.exists(places_labels_filename): 
            logger.info(f"Downloading Places365 labels to {places_labels_filename}..."); response = requests.get(places_labels_url, timeout=30); response.raise_for_status(); 
            with open(places_labels_filename, 'w', encoding='utf-8') as f: f.write(response.text); 
            logger.info("Places365 labels downloaded.")
        else: logger.debug(f"Using cached Places365 labels from {places_labels_filename}.")
        with open(places_labels_filename, 'r', encoding='utf-8') as f:
            for line in f:
                if line.strip(): parts = line.strip().split(' '); label = parts[0].split('/')[-1]; places_labels.append(label)
        if len(places_labels) != 365: logger.warning(f"Loaded {len(places_labels)} Places365 labels (expected 365).")
        logger.info(f"Loaded {len(places_labels)} Places365 labels.")
    except Exception as e: logger.error(f"Failed to load Places365 labels: {e}", exc_info=True); places_labels = [f"Label {i}" for i in range(365)]; logger.warning("Using fallback Places365 labels.")

    # --- Image Transforms for Scene Classification ---
    scene_transform = transforms.Compose([transforms.Resize((256, 256)), transforms.CenterCrop(224), transforms.ToTensor(), transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])])

    logger.info("All ML models loaded.")

except SystemExit as se: logger.critical(str(se)); sys.exit(1)
except FileNotFoundError as fnf_e: logger.critical(f"Required model file not found: {fnf_e}", exc_info=False); sys.exit(f"Missing file: {fnf_e}")
except Exception as e: logger.critical(f"FATAL ERROR DURING MODEL LOADING: {e}", exc_info=True); sys.exit(f"Model load failed: {e}")


# --- Detection Functions ---

# Using detect_objects for its structured output and focus mode capability
def detect_objects(image_np, focus_object=None):
    """
    Detects objects using YOLO-World.
    If focus_object is provided, returns details of the most confident match for that object.
    Otherwise, returns up to MAX_OBJECTS_TO_RETURN most confident objects.
    """
    try:
        img_rgb = cv2.cvtColor(image_np, cv2.COLOR_BGR2RGB)
        img_pil = Image.fromarray(img_rgb)
        results = yolo_model.predict(img_pil, conf=OBJECT_DETECTION_CONFIDENCE, verbose=False)
        all_detections = []
        if results and results[0].boxes:
            boxes = results[0].boxes
            class_id_to_name = results[0].names
            for box in boxes:
                confidence = float(box.conf[0])
                class_id = int(box.cls[0])
                if class_id in class_id_to_name:
                    class_name = class_id_to_name[class_id]
                    norm_box = box.xyxyn[0].tolist()
                    x1, y1, x2, y2 = norm_box
                    center_x = (x1 + x2) / 2.0; center_y = (y1 + y2) / 2.0
                    width = x2 - x1; height = y2 - y1
                    box_details = {'name': class_name, 'confidence': confidence, 'center_x': center_x, 'center_y': center_y, 'width': width, 'height': height}
                    all_detections.append((confidence, class_name, box_details))
                else: logger.warning(f"Unknown class ID {class_id} detected.")
        
        if focus_object:
            focus_object_lower = focus_object.lower()
            found_focus_detections = [(conf, details) for conf, name, details in all_detections if name.lower() == focus_object_lower]
            if not found_focus_detections:
                logger.debug(f"Focus mode: '{focus_object}' not found.")
                return {'status': 'not_found'}
            else:
                found_focus_detections.sort(key=lambda x: x[0], reverse=True)
                best_focus_conf, best_focus_details = found_focus_detections[0]
                logger.debug(f"Focus mode: Found '{focus_object}' (Conf: {best_focus_conf:.3f}) at center ({best_focus_details['center_x']:.2f}, {best_focus_details['center_y']:.2f})")
                return {'status': 'found', 'detection': best_focus_details}
        else: # Normal mode
            if not all_detections:
                logger.debug("Normal mode: No objects detected.")
                return {'status': 'none'}
            else:
                all_detections.sort(key=lambda x: x[0], reverse=True)
                top_detections_data = [details for conf, name, details in all_detections[:MAX_OBJECTS_TO_RETURN]]
                log_summary = ", ".join([f"{d['name']}({d['confidence']:.2f})" for d in top_detections_data])
                logger.debug(f"Normal mode: Top {len(top_detections_data)} results: {log_summary}")
                return {'status': 'ok', 'detections': top_detections_data}
    except Exception as e:
        logger.error(f"Error during object detection (Focus: {focus_object}): {e}", exc_info=True)
        return {'status': 'error', 'message': "Error in object detection"}

# Using detect_scene
def detect_scene(image_np):
    try:
        img_rgb = cv2.cvtColor(image_np, cv2.COLOR_BGR2RGB); img_pil = Image.fromarray(img_rgb); img_tensor = scene_transform(img_pil).unsqueeze(0)
        device = next(places_model.parameters()).device; img_tensor = img_tensor.to(device)
        with torch.no_grad(): outputs = places_model(img_tensor); probabilities = torch.softmax(outputs, dim=1)[0]; top_prob, top_catid = torch.max(probabilities, 0)
        if 0 <= top_catid.item() < len(places_labels): 
            predicted_label = places_labels[top_catid.item()].replace("_", " "); confidence = top_prob.item()
            logger.debug(f"Scene detection: {predicted_label} (Conf: {confidence:.3f})"); return predicted_label
        else: logger.warning(f"Places365 ID {top_catid.item()} out of bounds."); return "Unknown Scene"
    except Exception as e: logger.error(f"Scene detection error: {e}", exc_info=True); return "Error in scene detection"

# Using detect_text, with Tesseract config improvements and image saving
def detect_text(image_np, language_code=DEFAULT_OCR_LANG):
    logger.debug(f"Starting Tesseract OCR for lang: '{language_code}'...")
    validated_lang = language_code
    if language_code not in SUPPORTED_OCR_LANGS:
        logger.warning(f"Requested lang '{language_code}' not in supported list {SUPPORTED_OCR_LANGS}. Falling back to '{DEFAULT_OCR_LANG}'.")
        validated_lang = DEFAULT_OCR_LANG
        if validated_lang not in SUPPORTED_OCR_LANGS:
            logger.error(f"Default language '{DEFAULT_OCR_LANG}' is also not available. OCR cannot proceed.")
            return "Error: OCR Language Not Available"

    if SAVE_OCR_IMAGES:
        try:
            timestamp = time.strftime("%Y%m%d-%H%M%S"); filename = os.path.join(OCR_IMAGE_SAVE_DIR, f"ocr_input_{timestamp}_{validated_lang}.png")
            save_img = image_np; 
            if len(image_np.shape) == 3 and image_np.shape[2] == 4: save_img = cv2.cvtColor(image_np, cv2.COLOR_BGRA2BGR)
            elif len(image_np.shape) == 2: save_img = cv2.cvtColor(image_np, cv2.COLOR_GRAY2BGR)
            cv2.imwrite(filename, save_img); logger.debug(f"Saved OCR input image to: {filename}")
        except Exception as save_e: logger.error(f"Failed to save debug OCR image: {save_e}")

    try:
        gray_img = cv2.cvtColor(image_np, cv2.COLOR_BGR2GRAY) if len(image_np.shape) == 3 else image_np
        img_pil = Image.fromarray(gray_img)
        custom_config = f"-l {validated_lang} --oem 3 --psm 6" 
        logger.debug(f"Using Tesseract config: {custom_config}")
        detected_text = pytesseract.image_to_string(img_pil, config=custom_config)
        result_str = detected_text.strip()
        if not result_str: logger.debug(f"Tesseract ({validated_lang}): No text found."); return "No text detected"
        else: 
            result_str = "\n".join([line.strip() for line in result_str.splitlines() if line.strip()]) # Clean up
            log_text = result_str.replace('\n', ' ').replace('\r', '')[:100]; 
            logger.debug(f"Tesseract ({validated_lang}) OK: Found '{log_text}...'"); return result_str
    except pytesseract.TesseractNotFoundError: logger.error("Tesseract executable not found."); return "Error: OCR Engine Not Found"
    except pytesseract.TesseractError as tess_e:
        logger.error(f"TesseractError ({validated_lang}): {tess_e}", exc_info=False); error_str = str(tess_e).lower()
        if "failed loading language" in error_str or "could not initialize tesseract" in error_str or "data file not found" in error_str:
            logger.error(f"Missing Tesseract language data for '{validated_lang}'.")
            return f"Error: Missing OCR language data for '{validated_lang}'"
        else: return f"Error during text detection ({validated_lang})"
    except Exception as e: logger.error(f"Unexpected OCR error ({validated_lang}): {e}", exc_info=True); return f"Error during text detection ({validated_lang})"


# --- Helper Function for Ollama Interaction ---
def get_llm_feature_choice(image_np, client_sid="Unknown"):
    logger.info(f"[{client_sid}] Requesting feature choice from Ollama ({OLLAMA_MODEL_NAME})...")
    start_time = time.time()
    try:
        is_success, buffer = cv2.imencode(".jpg", image_np)
        if not is_success: logger.error(f"[{client_sid}] Failed to encode image to JPEG for Ollama."); return None
        image_base64 = base64.b64encode(buffer.tobytes()).decode("utf-8")
        
        # Updated prompt to include focus_detection and align with frontend expectations
        prompt = (
            "Analyze the provided image. Based *only* on the main content, "
            "which of the following analysis types is MOST appropriate? "
            "Choose exactly ONE:\n"
            "- 'object_detection': If the image focuses on identifying multiple general items or objects.\n"
            "- 'hazard_detection': If the image seems to contain items that could be hazards (e.g., a car, a stop sign, a knife). The system will then verify.\n"
            "- 'focus_detection': If the user would likely want to find a *specific single object* in the scene (e.g. find my keys, find the cup).\n"
            "- 'scene_detection': If the image primarily shows an overall environment, location, or setting.\n"
            "- 'text_detection': If the image contains significant readable text (like a document, sign, or label).\n"
            "Respond with ONLY the chosen identifier string (e.g., 'scene_detection') and nothing else."
        )
        payload = { "model": OLLAMA_MODEL_NAME, "prompt": prompt, "images": [image_base64], "stream": False, "options": {"temperature": 0.3} }
        
        logger.debug(f"[{client_sid}] Sending request to Ollama: {OLLAMA_API_URL}")
        response = requests.post(OLLAMA_API_URL, json=payload, headers={"Content-Type": "application/json"}, timeout=OLLAMA_REQUEST_TIMEOUT)
        response.raise_for_status()
        
        response_data = response.json()
        llm_response_text = response_data.get("response", "").strip().lower().replace("'", "").replace("\"", "") # Clean response
        logger.debug(f"[{client_sid}] Raw response from Ollama: '{llm_response_text}'")
        
        chosen_feature = None
        # These are the feature IDs the frontend's `sendImageForProcessing` `processingType` will use.
        valid_features = ["object_detection", "hazard_detection", "scene_detection", "text_detection", "focus_detection"] 
        
        if llm_response_text in valid_features:
            chosen_feature = llm_response_text
        else:
            logger.warning(f"[{client_sid}] Ollama response '{llm_response_text}' not exact. Searching keywords.")
            for feature in valid_features:
                if feature in llm_response_text: # Simpler keyword check
                    if chosen_feature is None: chosen_feature = feature; logger.info(f"[{client_sid}] Found keyword '{feature}'.")
                    else: logger.warning(f"[{client_sid}] Multiple keywords found. Using first: '{chosen_feature}'."); break
        
        if chosen_feature:
            elapsed_time = time.time() - start_time
            logger.info(f"[{client_sid}] Ollama chose feature: '{chosen_feature}' in {elapsed_time:.2f}s.")
            return chosen_feature
        else:
            logger.error(f"[{client_sid}] Failed to extract valid feature from Ollama: '{llm_response_text}'"); return None
    except requests.exceptions.Timeout: logger.error(f"[{client_sid}] Ollama request timed out."); return None
    except requests.exceptions.ConnectionError: logger.error(f"[{client_sid}] Could not connect to Ollama at {OLLAMA_API_URL}."); return None
    except requests.exceptions.RequestException as req_e:
        logger.error(f"[{client_sid}] Error during Ollama API request: {req_e}", exc_info=True)
        if req_e.response is not None: logger.error(f"[{client_sid}] Ollama response body (error): {req_e.response.text}")
        return None
    except Exception as e: logger.error(f"[{client_sid}] Unexpected error during Ollama interaction: {e}", exc_info=True); return None


# --- WebSocket Handlers ---
@socketio.on('connect')
def handle_connect(): logger.info(f'Client connected: {request.sid}'); emit('response', {'event': 'connect', 'result': {'status': 'connected', 'id': request.sid}}) # Connect response
@socketio.on('disconnect')
def handle_disconnect(): logger.info(f'Client disconnected: {request.sid}')

@socketio.on('message')
def handle_message(data):
    client_sid = request.sid; start_time = time.time(); 
    detection_type_from_payload = "unknown"; final_response_payload = None

    try:
        if not isinstance(data, dict):
            logger.warning(f"Invalid data format from {client_sid}. Expected dict."); 
            emit('response', {'result': {'status': 'error', 'message': 'Invalid data format'}}); return

        image_data = data.get('image')
        # This is 'type' from frontend's sendImageForProcessing `processingType`
        detection_type_from_payload = data.get('type') 
        # This is 'request_type' for SuperVision's llm_route
        supervision_request_type = data.get('request_type') 
        
        if not image_data or not detection_type_from_payload:
            logger.warning(f"Missing 'image' or 'type' from {client_sid}."); 
            emit('response', {'result': {'status': 'error', 'message': "Missing 'image' or 'type'"}}); return

        # --- Image Decoding ---
        try:
            if image_data.startswith("data:image"): header, encoded = image_data.split(",", 1)
            else: encoded = image_data
            image_bytes = base64.b64decode(encoded)
            image_np = cv2.imdecode(np.frombuffer(image_bytes, np.uint8), cv2.IMREAD_COLOR)
            if image_np is None: raise ValueError("cv2.imdecode returned None.")
            logger.debug(f"[{client_sid}] Image decoded. Shape: {image_np.shape}")
        except Exception as decode_err:
            logger.error(f"Image decode error for {client_sid}: {decode_err}", exc_info=True); 
            emit('response', {'result': {'status': 'error', 'message': 'Invalid image data'}}); return
        
        # --- Routing Logic ---
        # **SuperVision LLM Route**
        if detection_type_from_payload == 'supervision' and supervision_request_type == 'llm_route':
            logger.info(f"Handling SuperVision LLM routing request from {client_sid}...")
            chosen_feature_by_llm = get_llm_feature_choice(image_np, client_sid)
            
            # This will be the string result for SuperVisionPage
            supervision_string_result = "Error: LLM feature execution failed" 
            
            if chosen_feature_by_llm:
                logger.info(f"[{client_sid}] LLM selected: {chosen_feature_by_llm}. Running detection...")
                try:
                    if chosen_feature_by_llm == 'object_detection' or chosen_feature_by_llm == 'hazard_detection':
                        # Call detect_objects, which returns a dict
                        obj_dict_result = detect_objects(image_np) 
                        if obj_dict_result.get('status') == 'ok' and obj_dict_result.get('detections'):
                            names = [d['name'] for d in obj_dict_result['detections']]
                            supervision_string_result = ", ".join(names) if names else "No objects detected by SuperVision"
                        elif obj_dict_result.get('status') == 'none':
                            supervision_string_result = "No objects detected by SuperVision"
                        else: # error or other status
                            supervision_string_result = obj_dict_result.get('message', f"Object/Hazard detection issue for SuperVision: {obj_dict_result.get('status')}")
                    
                    elif chosen_feature_by_llm == 'scene_detection':
                        supervision_string_result = detect_scene(image_np)
                    
                    elif chosen_feature_by_llm == 'text_detection':
                        # For LLM-chosen text detection, use default language.
                        # Frontend sends language only for direct text_detection.
                        supervision_string_result = detect_text(image_np, DEFAULT_OCR_LANG)

                    elif chosen_feature_by_llm == 'focus_detection':
                        # LLM chose focus_detection. SuperVision cannot directly fulfill this without an object.
                        # It should ideally not choose this, or we need a way to prompt user via SuperVision page.
                        # For now, treat as a "suggestion" that focus might be useful.
                        supervision_string_result = "Image might be suitable for Focus Mode. Try Focus Mode page to select an object."
                        # Or, run general object detection as a fallback for SuperVision:
                        # obj_dict_result = detect_objects(image_np)
                        # if obj_dict_result.get('status') == 'ok' and obj_dict_result.get('detections'):
                        #     names = [d['name'] for d in obj_dict_result['detections']]
                        #     supervision_string_result = ", ".join(names) if names else "No objects detected by SuperVision"
                        # else: supervision_string_result = "Object analysis complete for SuperVision."
                        # chosen_feature_by_llm = 'object_detection' # Override feature_id if falling back

                    else: # Should not happen if get_llm_feature_choice validates
                        logger.error(f"[{client_sid}] Invalid feature '{chosen_feature_by_llm}' from LLM.")
                        supervision_string_result = "Error: Invalid analysis type by LLM"

                    final_response_payload = {
                        'result': supervision_string_result, 
                        'feature_id': chosen_feature_by_llm, 
                        'is_from_supervision_llm': True
                    }
                except Exception as exec_e:
                    logger.error(f"[{client_sid}] Error exec selected LLM feature '{chosen_feature_by_llm}': {exec_e}", exc_info=True)
                    final_response_payload = {'result': f"Error running {chosen_feature_by_llm}", 'feature_id': chosen_feature_by_llm, 'is_from_supervision_llm': True}
            else: # Ollama interaction failed
                logger.error(f"[{client_sid}] Failed to get feature choice from Ollama.")
                final_response_payload = {'result': "Error: Smart analysis failed (LLM issue)", 'feature_id': "supervision_error", 'is_from_supervision_llm': True}
        
        # **Direct Feature Requests (Object, Scene, Text, Focus)**
        else:
            logger.info(f"Processing direct request '{detection_type_from_payload}' from {client_sid}")
            # This is the output from the detection function, could be dict or string.
            detection_function_output = "Error: Unknown processing error" 
            
            if detection_type_from_payload == 'object_detection':
                detection_function_output = detect_objects(image_np)
            elif detection_type_from_payload == 'focus_detection':
                focus_object_name = data.get('focus_object')
                if not focus_object_name:
                    logger.warning(f"Direct focus_detection from {client_sid} missing 'focus_object'.")
                    detection_function_output = {'status': 'error', 'message': "Missing 'focus_object' for focus detection"}
                else:
                    detection_function_output = detect_objects(image_np, focus_object=focus_object_name)
            elif detection_type_from_payload == 'scene_detection':
                scene_label = detect_scene(image_np) # Returns string
                # Wrap for consistency with frontend expectation for direct scene/text
                if "Error" in scene_label: detection_function_output = {'status': 'error', 'message': scene_label}
                elif "Unknown" in scene_label: detection_function_output = {'status': 'none', 'scene': scene_label}
                else: detection_function_output = {'status': 'ok', 'scene': scene_label}
            elif detection_type_from_payload == 'text_detection':
                requested_language = data.get('language', DEFAULT_OCR_LANG).lower()
                validated_language = requested_language if requested_language in SUPPORTED_OCR_LANGS else DEFAULT_OCR_LANG
                if validated_language != requested_language: logger.warning(f"Client {client_sid} invalid lang '{requested_language}', using '{DEFAULT_OCR_LANG}'.")
                text_result_str = detect_text(image_np, language_code=validated_language) # Returns string
                # Wrap for consistency
                if "Error" in text_result_str: detection_function_output = {'status': 'error', 'message': text_result_str}
                elif "No text detected" in text_result_str: detection_function_output = {'status': 'none', 'text': text_result_str}
                else: detection_function_output = {'status': 'ok', 'text': text_result_str}
            elif detection_type_from_payload == 'hazard_detection': # Frontend sends this for Hazard Page
                # Hazard page relies on object detection results
                detection_function_output = detect_objects(image_np)
            else:
                logger.warning(f"Unsupported direct type '{detection_type_from_payload}' from {client_sid}")
                detection_function_output = {'status': 'error', 'message': f"Unsupported type '{detection_type_from_payload}'"}
            
            # For direct requests, frontend expects the style: result contains the function's output directly.
            # The is_from_supervision_llm will be absent (or false).
            final_response_payload = {'result': detection_function_output} 
            # Optionally, could add 'feature_id': detection_type_from_payload if frontend needs it for direct calls

        # --- Emit the final response ---
        if final_response_payload:
            processing_time = time.time() - start_time
            log_result_summary = str(final_response_payload.get('result', "N/A"))
            if isinstance(final_response_payload.get('result'), dict):
                log_result_summary = f"Dict keys: {list(final_response_payload['result'].keys())}"
            log_result_short = (log_result_summary[:100] + "...") if len(log_result_summary) > 100 else log_result_summary
            
            log_type = final_response_payload.get('feature_id', detection_type_from_payload)
            log_origin = "Supervision(LLM)" if final_response_payload.get('is_from_supervision_llm') else "Direct"

            logger.info(f"Completed '{log_type}' ({log_origin}) for {client_sid} in {processing_time:.3f}s. Result summary: '{log_result_short}'")
            emit('response', final_response_payload)
        else:
            logger.error(f"[{client_sid}] Failed to generate a response payload for type '{detection_type_from_payload}'. This indicates a code flow error.")
            emit('response', {'result': {'status': 'error', 'message': 'Server Error: Failed to process request.'}})

    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(f"Unhandled error in handle_message (type: '{detection_type_from_payload}') for {client_sid} after {processing_time:.3f}s: {e}", exc_info=True)
        try:
            error_resp = {'result': {'status': 'error', 'message': 'Internal server error during processing.'}}
            if detection_type_from_payload == 'supervision' and supervision_request_type == 'llm_route':
                 error_resp['feature_id'] = "supervision_error"
                 error_resp['is_from_supervision_llm'] = True
            emit('response', error_resp)
        except Exception as emit_e: logger.error(f"Failed to emit error response to {client_sid}: {emit_e}")


@socketio.on_error_default
def default_error_handler(e):
    client_sid = request.sid if request else "UnknownSID"
    logger.error(f'Unhandled WebSocket Error for SID {client_sid}: {e}', exc_info=True)
    try:
        if client_sid != "UnknownSID": 
            emit('response', {'result': {'status': 'error', 'message': 'Internal WebSocket error.'}}, room=client_sid)
    except Exception as emit_err: logger.error(f"Failed emit default error response to {client_sid}: {emit_err}")

# --- HTTP Routes (Keep as is, mostly placeholders) ---
@app.route('/')
def home(): 
    test_html_path = os.path.join(template_dir, 'test.html')
    return render_template('test.html') if os.path.exists(test_html_path) else "VisionAid Backend (Integrated) is running."

@app.route('/update_customization', methods=['POST'])
def update_customization(): logger.warning("Route /update_customization hit (not implemented)."); return jsonify({"status":"not_implemented"}), 501
@app.route('/get_user_info', methods=['GET'])
def get_user_info(): logger.warning("Route /get_user_info hit (not implemented)."); return jsonify({"status":"not_implemented"}), 501
@app.route('/add_test_user', methods=['POST'])
def add_test_user(): logger.warning("Route /add_test_user hit (not implemented)."); return jsonify({"status":"not_implemented"}), 501


# --- Main Execution Point ---
if __name__ == '__main__':
    logger.info("Starting Flask-SocketIO server (Integrated Version)...")
    host_ip = os.environ.get('FLASK_HOST', '0.0.0.0')
    port_num = int(os.environ.get('FLASK_PORT', 5000))
    debug_mode = os.environ.get('FLASK_DEBUG', 'False').lower() in ('true', '1', 't')
    use_reloader = debug_mode 

    logger.info(f"Server listening on http://{host_ip}:{port_num} (Debug: {debug_mode}, Reloader: {use_reloader})")
    logger.info(f" * Ollama Model: {OLLAMA_MODEL_NAME}, URL: {OLLAMA_API_URL}")

    try:
        socketio.run(app, debug=debug_mode, host=host_ip, port=port_num, use_reloader=use_reloader, allow_unsafe_werkzeug=True if use_reloader else False)
    except OSError as os_e:
        if "Address already in use" in str(os_e): logger.critical(f"Port {port_num} is already in use on {host_ip}.")
        else: logger.critical(f"Failed to start server due to OS Error: {os_e}", exc_info=True)
        sys.exit(1)
    except Exception as run_e: logger.critical(f"Failed to start server: {run_e}", exc_info=True); sys.exit(1)
    finally: logger.info("Server shutdown.")