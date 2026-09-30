"""Inference handlers for the SKLearn SageMaker container's four-function
contract (model_fn/input_fn/predict_fn/output_fn). Used both by the
real-time endpoint the ingestion-worker calls and by batch transform jobs.
"""

import json
from pathlib import Path

import joblib


def model_fn(model_dir: str):
    return joblib.load(Path(model_dir) / "model.joblib")


def input_fn(request_body: str, request_content_type: str):
    if request_content_type != "application/json":
        raise ValueError(f"Unsupported content type: {request_content_type}")
    payload = json.loads(request_body)
    # Accept either a raw {"text": "..."} payload or the {"s3_uri": "..."}
    # shape the ingestion worker sends — text extraction from s3_uri is
    # assumed to have already happened upstream in a real deployment; this
    # keeps the handler focused on the model itself.
    return payload.get("text", "")


def predict_fn(input_text: str, model):
    predicted_label = model.predict([input_text])[0]
    probabilities = model.predict_proba([input_text])[0]
    confidence = float(max(probabilities))
    return {"predicted_label": predicted_label, "confidence": confidence}


def output_fn(prediction: dict, response_content_type: str) -> str:
    if response_content_type != "application/json":
        raise ValueError(f"Unsupported content type: {response_content_type}")
    return json.dumps(prediction)
