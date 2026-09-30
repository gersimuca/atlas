"""Defines the document-classifier MLOps pipeline: train -> evaluate ->
register (only if the evaluation clears a quality bar).

Why this isn't a Terraform resource: SageMaker Pipelines are a DAG-as-code
concept, not a declarative infrastructure resource — there's no
`aws_sagemaker_pipeline` in the Terraform AWS provider, and trying to force
a Python-defined workflow through HCL would fight the tool rather than use
it. Terraform's job (infra/modules/sagemaker) is the scaffolding this
depends on: the execution role and the model package group the last step
registers into. This file's job is the workflow itself, deployed with:

    python pipeline_definition.py --upsert

typically run from CI whenever this file or the training/evaluation scripts
change, and the pipeline is triggered either on that schedule or by new
labeled data landing in the silver zone.
"""

import argparse
import os

import sagemaker
from sagemaker.processing import ProcessingInput, ProcessingOutput, ScriptProcessor
from sagemaker.sklearn.estimator import SKLearn
from sagemaker.workflow.condition_step import ConditionStep
from sagemaker.workflow.conditions import ConditionGreaterThanOrEqualTo
from sagemaker.workflow.functions import JsonGet
from sagemaker.workflow.parameters import ParameterFloat, ParameterString
from sagemaker.workflow.pipeline import Pipeline
from sagemaker.workflow.pipeline_context import PipelineSession
from sagemaker.workflow.properties import PropertyFile
from sagemaker.workflow.step_collections import RegisterModel
from sagemaker.workflow.steps import ProcessingStep, TrainingStep


def build_pipeline(
    role_arn: str,
    pipeline_name: str,
    model_package_group_name: str,
    train_data_s3_uri: str,
    test_data_s3_uri: str,
    default_bucket: str | None = None,
) -> Pipeline:
    session = PipelineSession(default_bucket=default_bucket)

    instance_type = ParameterString(name="TrainingInstanceType", default_value="ml.m5.large")
    min_accuracy = ParameterFloat(name="MinAccuracyThreshold", default_value=0.80)
    train_data = ParameterString(name="TrainDataS3Uri", default_value=train_data_s3_uri)
    test_data = ParameterString(name="TestDataS3Uri", default_value=test_data_s3_uri)

    # --- Train ---
    estimator = SKLearn(
        entry_point="train.py",
        source_dir=os.path.join(os.path.dirname(__file__), "..", "training"),
        role=role_arn,
        instance_type=instance_type,
        instance_count=1,
        framework_version="1.2-1",
        sagemaker_session=session,
        hyperparameters={"max-features": 5000, "C": 1.0},
    )
    train_step = TrainingStep(
        name="TrainDocumentClassifier",
        step_args=estimator.fit({"train": train_data}),
    )

    # --- Evaluate ---
    evaluator = ScriptProcessor(
        image_uri=estimator.training_image_uri(),
        command=["python3"],
        role=role_arn,
        instance_type="ml.m5.large",
        instance_count=1,
        sagemaker_session=session,
    )
    evaluation_report = PropertyFile(
        name="EvaluationReport", output_name="evaluation", path="evaluation.json"
    )
    evaluate_step = ProcessingStep(
        name="EvaluateDocumentClassifier",
        step_args=evaluator.run(
            code=os.path.join(os.path.dirname(__file__), "..", "..", "evaluation", "evaluate.py"),
            inputs=[
                ProcessingInput(
                    source=train_step.properties.ModelArtifacts.S3ModelArtifacts,
                    destination="/opt/ml/processing/model",
                ),
                ProcessingInput(source=test_data, destination="/opt/ml/processing/test"),
            ],
            outputs=[ProcessingOutput(output_name="evaluation", source="/opt/ml/processing/evaluation")],
        ),
        property_files=[evaluation_report],
    )

    # --- Register, only if accuracy clears the bar ---
    register_step = RegisterModel(
        name="RegisterDocumentClassifier",
        estimator=estimator,
        model_data=train_step.properties.ModelArtifacts.S3ModelArtifacts,
        content_types=["application/json"],
        response_types=["application/json"],
        inference_instances=["ml.m5.large", "ml.t2.medium"],
        transform_instances=["ml.m5.large"],
        model_package_group_name=model_package_group_name,
        approval_status="PendingManualApproval",  # a human still approves promotion to the live endpoint
    )

    condition_step = ConditionStep(
        name="CheckEvaluationAccuracy",
        conditions=[
            ConditionGreaterThanOrEqualTo(
                left=JsonGet(
                    step_name=evaluate_step.name,
                    property_file=evaluation_report,
                    json_path="classification_metrics.accuracy.value",
                ),
                right=min_accuracy,
            )
        ],
        if_steps=[register_step],
        else_steps=[],  # falls through silently — a real pipeline would also notify on regression here
    )

    return Pipeline(
        name=pipeline_name,
        parameters=[instance_type, min_accuracy, train_data, test_data],
        steps=[train_step, evaluate_step, condition_step],
        sagemaker_session=session,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--upsert", action="store_true", help="Create or update the pipeline definition in SageMaker")
    parser.add_argument("--start", action="store_true", help="Also start a pipeline execution after upserting")
    args = parser.parse_args()

    pipeline = build_pipeline(
        role_arn=os.environ["SAGEMAKER_EXECUTION_ROLE_ARN"],
        pipeline_name="atlas-document-classifier",
        model_package_group_name=os.environ["MODEL_PACKAGE_GROUP_NAME"],
        train_data_s3_uri=os.environ["TRAIN_DATA_S3_URI"],
        test_data_s3_uri=os.environ["TEST_DATA_S3_URI"],
    )

    if args.upsert:
        pipeline.upsert(role_arn=os.environ["SAGEMAKER_EXECUTION_ROLE_ARN"])
        print(f"Upserted pipeline: {pipeline.name}")

    if args.start:
        execution = pipeline.start()
        print(f"Started execution: {execution.arn}")
