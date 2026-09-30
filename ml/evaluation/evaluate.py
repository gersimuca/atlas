"""Runs as a SageMaker Processing job step in the pipeline (see
ml/sagemaker/pipeline/pipeline_definition.py). Loads the freshly trained
model artifact and a held-out test set, computes metrics, and writes them in
the property-file shape SageMaker Pipelines' ConditionStep can read a
specific field out of — that's what decides whether the model actually gets
registered, not just whether training "succeeded".
"""

import json
import tarfile
from pathlib import Path

import joblib
import pandas as pd
from sklearn.metrics import accuracy_score, f1_score, precision_score, recall_score

MODEL_DIR = Path("/opt/ml/processing/model")
TEST_DIR = Path("/opt/ml/processing/test")
OUTPUT_DIR = Path("/opt/ml/processing/evaluation")


def _extract_model_artifact() -> Path:
    tarball = next(MODEL_DIR.glob("*.tar.gz"))
    extract_to = MODEL_DIR / "extracted"
    extract_to.mkdir(exist_ok=True)
    with tarfile.open(tarball) as tar:
        tar.extractall(extract_to)
    return extract_to / "model.joblib"


def main() -> None:
    model = joblib.load(_extract_model_artifact())

    test_csv = next(TEST_DIR.glob("*.csv"))
    test_df = pd.read_csv(test_csv).dropna(subset=["text", "label"])

    predictions = model.predict(test_df["text"])

    report = {
        "classification_metrics": {
            "accuracy": {"value": accuracy_score(test_df["label"], predictions)},
            "f1_weighted": {"value": f1_score(test_df["label"], predictions, average="weighted")},
            "precision_weighted": {"value": precision_score(test_df["label"], predictions, average="weighted", zero_division=0)},
            "recall_weighted": {"value": recall_score(test_df["label"], predictions, average="weighted", zero_division=0)},
        }
    }

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUTPUT_DIR / "evaluation.json").write_text(json.dumps(report, indent=2))
    print(f"Evaluation report: {json.dumps(report, indent=2)}")


if __name__ == "__main__":
    main()
