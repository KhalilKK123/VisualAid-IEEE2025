from flask import Flask, request, jsonify, render_template
from flask_cors import CORS
from flask_socketio import SocketIO, emit
import cv2
import numpy as np
import torch
import os
import io
import base64
import logging
from PIL import Image
import easyocr
import torchvision.models as models
import torchvision.transforms as transforms
import requests

app = Flask(__name__)
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*")

# Configure logging
logging.basicConfig(level=logging.DEBUG)

# YOLOv5 model for object detection
yolo_model = torch.hub.load('ultralytics/yolov5', 'yolov5n', device='cpu')

# Places365 model for scene detection
def load_places365_model():
    model = models.resnet50(weights=None)
    model.fc = torch.nn.Linear(model.fc.in_features, 365)
    weights_path = 'resnet50_places365.pth.tar'
    if not os.path.exists(weights_path):
        response = requests.get('http://places2.csail.mit.edu/models_places365/resnet50_places365.pth.tar')
        with open(weights_path, 'wb') as f:
            f.write(response.content)
    checkpoint = torch.load(weights_path, map_location='cpu')
    state_dict = {k.replace('module.', ''): v for k, v in checkpoint['state_dict'].items()}
    model.load_state_dict(state_dict)
    return model.eval()

places_model = load_places365_model()

#  Places365 labels
places_labels = []
response = requests.get('https://raw.githubusercontent.com/csailvision/places365/master/categories_places365.txt')
for line in response.text.split('\n'):
    if line:
        places_labels.append(' '.join(line.split(' ')[0].split('/')[2:]))

# EasyOCR reader
ocr_reader = easyocr.Reader(['en'])

# Common image transforms for scene detection
scene_transform = transforms.Compose([
    transforms.Resize((256, 256)),
    transforms.CenterCrop(224),
    transforms.ToTensor(),
    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
])

@app.route('/')
def home():
    return render_template('index.html')

@socketio.on('detect-objects')
def handle_object_detection(data):
    try:
        img_data = data.get('image')
        header, encoded = img_data.split(',', 1)
        img_bytes = base64.b64decode(encoded)
        img = Image.open(io.BytesIO(img_bytes))
        results = yolo_model(img)
        detections = results.pandas().xyxy[0][['name', 'confidence']].to_dict(orient='records')
        emit('object-detection-result', {'success': True, 'detections': detections})
    except Exception as e:
        emit('object-detection-result', {'success': False, 'error': str(e)})

@socketio.on('detect-scene')
def handle_scene_detection(data):
    try:
        img_data = data.get('image')
        header, encoded = img_data.split(',', 1)
        img_bytes = base64.b64decode(encoded)
        img = Image.open(io.BytesIO(img_bytes))
        img_tensor = scene_transform(img).unsqueeze(0)
        with torch.no_grad():
            outputs = places_model(img_tensor)
        _, preds = torch.topk(outputs, 5)
        predictions = [{
            'scene': places_labels[idx],
            'confidence': float(outputs[0][idx])
        } for idx in preds[0].tolist()]
        emit('scene-detection-result', {'success': True, 'predictions': predictions})
    except Exception as e:
        emit('scene-detection-result', {'success': False, 'error': str(e)})

@socketio.on('ocr')
def handle_ocr(data):
    try:
        image_data = data.get('image', '')
        header, encoded = image_data.split(',', 1)
        image_bytes = base64.b64decode(encoded)
        np_array = np.frombuffer(image_bytes, np.uint8)
        image = cv2.imdecode(np_array, cv2.IMREAD_COLOR)
        results = ocr_reader.readtext(image)
        detected_text = ' '.join([text[1] for text in results]) if results else ''
        emit('ocr-result', {'success': True, 'detected_text': detected_text})
    except Exception as e:
        emit('ocr-result', {'success': False, 'error': str(e)})

if __name__ == '__main__':
    socketio.run(app, debug=True)