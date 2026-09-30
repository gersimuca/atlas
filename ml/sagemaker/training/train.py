"""Trains the document classifier that tags incoming documents during
ingestion (contract / invoice / support_ticket / report).

Written for SageMaker script mode: reads hyperparameters from argv, training
data from the channel SageMaker mounts at SM_CHANNEL_TRAIN, and writes the
model artifact to SM_MODEL_DIR (which SageMaker then tars up to
model.tar.gz in S3). Runs the same way locally (`python train.py --train
./data --model-dir ./out`) as it does inside a real training job — nothing
here is Glue-specific or SageMaker-specific beyond reading those env vars,
which is exactly the point of script mode.

Intentionally simple (TF-IDF + logistic regression, not a fine-tuned
transformer): this document-type classification task doesn't need one, and a
model this cheap to train and serve is the right choice before reaching for
something heavier.
"""

import argparse
import json
import os
from pathlib import Path

import joblib
import pandas as pd
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, f1_score
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--train", type=str, default=os.environ.get("SM_CHANNEL_TRAIN", "./data"))
    parser.add_argument("--model-dir", type=str, default=os.environ.get("SM_MODEL_DIR", "./out"))
    parser.add_argument("--max-features", type=int, default=5000)
    parser.add_argument("--C", type=float, default=1.0, help="Inverse regularization strength")
    parser.add_argument("--test-size", type=float, default=0.2)
    parser.add_argument("--random-state", type=int, default=42)
    return parser.parse_args()


def load_training_data(train_dir: str) -> pd.DataFrame:
    """Expects one or more CSVs with columns: text, label — SageMaker
    concatenates every file it finds in the channel, so a single combined
    export or several per-department exports both work."""
    train_path = Path(train_dir)
    csv_files = sorted(train_path.glob("*.csv"))
    if not csv_files:
        raise FileNotFoundError(f"No CSV files found under {train_dir}")
    frames = [pd.read_csv(f) for f in csv_files]
    df = pd.concat(frames, ignore_index=True)
    if not {"text", "label"}.issubset(df.columns):
        raise ValueError("Training data must have 'text' and 'label' columns")
    return df.dropna(subset=["text", "label"])


def main() -> None:
    args = parse_args()
    df = load_training_data(args.train)

    x_train, x_test, y_train, y_test = train_test_split(
        df["text"], df["label"], test_size=args.test_size, random_state=args.random_state, stratify=df["label"]
    )

    pipeline = Pipeline(
        [
            ("tfidf", TfidfVectorizer(max_features=args.max_features, ngram_range=(1, 2), stop_words="english")),
            ("classifier", LogisticRegression(C=args.C, max_iter=1000, class_weight="balanced")),
        ]
    )
    pipeline.fit(x_train, y_train)

    predictions = pipeline.predict(x_test)
    metrics = {
        "accuracy": accuracy_score(y_test, predictions),
        "f1_weighted": f1_score(y_test, predictions, average="weighted"),
        "n_train": len(x_train),
        "n_test": len(x_test),
        "classes": sorted(df["label"].unique().tolist()),
    }
    print(f"Evaluation metrics: {json.dumps(metrics, indent=2)}")

    model_dir = Path(args.model_dir)
    model_dir.mkdir(parents=True, exist_ok=True)
    joblib.dump(pipeline, model_dir / "model.joblib")
    (model_dir / "metrics.json").write_text(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
