import os

from model_config import *

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


def detect_scene(image_np):
    try:
        img_rgb = cv2.cvtColor(image_np, cv2.COLOR_BGR2RGB)
        img_pil = Image.fromarray(img_rgb)
        img_tensor = scene_transform(img_pil).unsqueeze(0)
        device = next(places_model.parameters()).device
        img_tensor = img_tensor.to(device)
        with torch.no_grad():
            outputs = places_model(img_tensor)
            probabilities = torch.softmax(outputs, dim=1)[0]
            top_prob, top_catid = torch.max(probabilities, 0)
        if 0 <= top_catid.item() < len(places_labels):
            predicted_label = places_labels[top_catid.item()].replace("_", " ")
            confidence = top_prob.item()
            logger.debug(f"Scene detection: {predicted_label} (Conf: {confidence:.3f})")
            return predicted_label
        else:
            logger.warning(f"Places365 ID {top_catid.item()} out of bounds.")
            return "Unknown Scene"
    except Exception as e:
        logger.error(f"Scene detection error: {e}", exc_info=True)
        return "Error in scene detection"
