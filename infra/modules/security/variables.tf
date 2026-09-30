variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "app_secret_config" {
  description = "Non-sensitive placeholder keys created in Secrets Manager; real values are set out-of-band (console, CI secret, or `aws secretsmanager put-secret-value`), never committed to state-visible tfvars."
  type        = map(string)
  default = {
    api_key_salt = "REPLACE_ME"
  }
}
