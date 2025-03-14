from flask import Flask, request, jsonify, render_template
from flask_cors import CORS
from flask_socketio import SocketIO, emit
from flask_sqlalchemy import SQLAlchemy
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

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

template_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'templates'))
app = Flask(__name__, template_folder=template_dir)
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*")

# Modify the database configuration to add more detailed logging
app.config['SQLALCHEMY_DATABASE_URI'] = 'mysql+pymysql://root:@localhost:3306/visualaiddb'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['SQLALCHEMY_ECHO'] = True  # This will log all SQL statements
db = SQLAlchemy(app)

# Add a method to check database connection
def test_db_connection():
    try:
        # Attempt to get a connection and execute a simple query
        with db.engine.connect() as connection:
            result = connection.execute(db.text("SELECT 1"))
            
            # Print to both logger and standard output
            print(" DATABASE CONNECTED SUCCESSFULLY!")
            logger.info(" Database connection successful!")
            
            return True
    except Exception as e:
        # Print connection failure to both logger and standard output
        print(f"DATABASE CONNECTION FAILED: {e}")
        logger.error(f"Database connection failed: {e}")
        return False

# Add a method to list all users (for debugging)
def list_all_users():
    try:
        users = User.query.all()
        logger.info("All Users in Database:")
        for user in users:
            logger.info(f"ID: {user.id}, Name: {user.name}, Email: {user.email}")
    except Exception as e:
        logger.error(f"Error listing users: {e}")

class User(db.Model):
    __tablename__ = 'users'
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(255), nullable=False)
    email = db.Column(db.String(255), nullable=False, unique=True)
    password = db.Column(db.String(255), nullable=False)
    customization = db.Column(db.String(255), default='0' * 255)

with app.app_context():
    db.create_all()
    test_db_connection()  # This will print the connection status

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

# EasyOCR reader for the text detection
ocr_reader = easyocr.Reader(['en'])

# Common image transforms for scene detection to match resolution with the model input specification
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

@app.route('/update_customization', methods=['POST'])
def update_customization():
    try:
        data = request.json
        email = data.get('email')
        customization = data.get('customization')

        if not email or not customization:
            return jsonify({'success': False, 'message': 'Email and customization are required'}), 400

        customization = (customization + '0' * 255)[:255]

        user = User.query.filter_by(email=email).first()
        if not user:
            return jsonify({'success': False, 'message': 'User not found'}), 404

        user.customization = customization
        db.session.commit()

        return jsonify({'success': True, 'message': 'Customization updated successfully'}), 200

    except Exception as e:
        logger.error(f"Error updating customization: {str(e)}")
        return jsonify({'success': False, 'message': 'Internal server error'}), 500

@app.route('/get_user_info', methods=['GET'])
def get_user_info():
    try:
        email = request.args.get('email')
        logger.debug(f"Attempting to retrieve user with email: {email}")

        # First, test the database connection
        if not test_db_connection():
            return jsonify({
                'success': False, 
                'message': 'Database connection failed'
            }), 500

        # List all users for debugging
        list_all_users()

        # Try to find the user
        user = User.query.filter_by(email=email).first()
        
        if not user:
            logger.warning(f"No user found with email: {email}")
            return jsonify({
                'success': False, 
                'message': f'No user found with email: {email}'
            }), 404

        # Log found user details
        logger.info(f"User found: {user.name}, Email: {user.email}")

        return jsonify({
            'success': True,
            'name': user.name,
            'email': user.email,
            'customization': user.customization
        }), 200

    except Exception as e:
        logger.error(f"Unexpected error retrieving user info: {e}")
        return jsonify({
            'success': False, 
            'message': f'Unexpected error: {str(e)}'
        }), 500

@app.route('/add_test_user', methods=['POST'])
def add_test_user():
    try:
        data = request.json
        name = data.get('name')
        email = data.get('email')
        password = data.get('password')

        if not all([name, email, password]):
            return jsonify({
                'success': False, 
                'message': 'Name, email, and password are required'
            }), 400

        # Check if user already exists
        existing_user = User.query.filter_by(email=email).first()
        if existing_user:
            return jsonify({
                'success': False, 
                'message': 'User with this email already exists'
            }), 409

        # Create new user
        new_user = User(name=name, email=email, password=password)
        db.session.add(new_user)
        db.session.commit()

        logger.info(f"Test user added: {name}, {email}")
        return jsonify({
            'success': True, 
            'message': 'Test user added successfully'
        }), 201

    except Exception as e:
        db.session.rollback()
        logger.error(f"Error adding test user: {e}")
        return jsonify({
            'success': False, 
            'message': f'Error adding test user: {str(e)}'
        }), 500

if __name__ == '__main__':
    socketio.run(app, debug=True)