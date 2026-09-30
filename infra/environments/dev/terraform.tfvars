project_name = "atlas"
environment  = "dev"
aws_region   = "us-east-1"

availability_zones = ["us-east-1a", "us-east-1b"]

eks_cluster_version = "1.34"
eks_compute_type     = "fargate" # no idle EC2 node cost while you're iterating

bedrock_model_id           = "us.anthropic.claude-sonnet-4-6"
bedrock_embedding_model_id = "amazon.titan-embed-text-v2:0"
vector_store_type          = "OPENSEARCH_SERVERLESS"

enable_sagemaker_studio = false
