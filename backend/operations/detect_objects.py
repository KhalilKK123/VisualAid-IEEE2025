import os

from model_config import *

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"  # Keep if needed

import cv2
from PIL import Image


def detect_objects(image_np, focus_object=None):
    try:
        img_rgb = cv2.cvtColor(image_np, cv2.COLOR_BGR2RGB)
        img_pil = Image.fromarray(img_rgb)
        results = yolo_model.predict(
            img_pil, conf=OBJECT_DETECTION_CONFIDENCE, verbose=False
        )
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
                    center_x = (x1 + x2) / 2.0
                    center_y = (y1 + y2) / 2.0
                    width = x2 - x1
                    height = y2 - y1
                    box_details = {
                        "name": class_name,
                        "confidence": confidence,
                        "center_x": center_x,
                        "center_y": center_y,
                        "width": width,
                        "height": height,
                    }
                    all_detections.append((confidence, class_name, box_details))
                else:
                    logger.warning(
                        f"Unknown class ID {class_id} detected by YOLO-World."
                    )

        if focus_object:
            focus_object_lower = focus_object.lower()
            found_focus_detections = [
                (conf, details)
                for conf, name, details in all_detections
                if name.lower() == focus_object_lower
            ]
            if not found_focus_detections:
                logger.debug(f"Focus mode: '{focus_object}' not found.")
                return {"status": "not_found"}
            else:
                found_focus_detections.sort(key=lambda x: x[0], reverse=True)
                best_focus_conf, best_focus_details = found_focus_detections[0]
                logger.debug(
                    f"Focus mode: Found '{focus_object}' (Conf: {best_focus_conf:.3f}) at center ({best_focus_details['center_x']:.2f}, {best_focus_details['center_y']:.2f})"
                )
                return {"status": "found", "detection": best_focus_details}
        else:  # Normal mode
            if not all_detections:
                logger.debug("Normal mode: No objects detected.")
                return {"status": "none"}
            else:
                all_detections.sort(key=lambda x: x[0], reverse=True)
                top_detections_data = [
                    details
                    for conf, name, details in all_detections[:MAX_OBJECTS_TO_RETURN]
                ]
                log_summary = ", ".join(
                    [f"{d['name']}({d['confidence']:.2f})" for d in top_detections_data]
                )
                logger.debug(
                    f"Normal mode: Top {len(top_detections_data)} results: {log_summary}"
                )
                return {"status": "ok", "detections": top_detections_data}
    except Exception as e:
        logger.error(
            f"Error during object detection (Focus: {focus_object}): {e}", exc_info=True
        )
        return {"status": "error", "message": "Error in object detection"}
