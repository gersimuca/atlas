project_name = "atlas"
environment  = "prod"
aws_region   = "us-east-1"

availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
single_nat_gateway  = false # one NAT per AZ — no single point of failure

eks_cluster_version = "1.34"
eks_compute_type     = "managed_node_group" # Karpenter-managed, autoscaling EC2 capacity

bedrock_model_id           = "us.anthropic.claude-sonnet-4-6"
bedrock_embedding_model_id = "amazon.titan-embed-text-v2:0"
vector_store_type          = "OPENSEARCH_SERVERLESS"

enable_sagemaker_studio = true
