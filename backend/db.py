import os

from App import *

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


DB_URI = os.environ.get(
    "DATABASE_URL", "mysql+pymysql://root:@127.0.0.1:3306/visualaiddb"
)
app.config["SQLALCHEMY_DATABASE_URI"] = DB_URI
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
app.config["SQLALCHEMY_ECHO"] = False
db = SQLAlchemy(app)


def test_db_connection():
    try:
        with app.app_context():
            with db.engine.connect() as connection:
                connection.execute(db.text("SELECT 1"))
                logger.info("DB connection OK!")
                return True
    except Exception as e:
        logger.error(f"DB connection failed: {e}", exc_info=False)
        return False


class User(db.Model):
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
