variable "aws_region" {
  type        = string
  description = "AWS region of the workload cell."
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "vpc_id" {
  type        = string
  description = "VPC of the EKS cluster that runs the service."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets in at least two Availability Zones for the Aurora cluster."

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Aurora needs subnets in at least two Availability Zones."
  }
}

variable "workload_security_group_id" {
  type        = string
  description = "Security group of the EKS nodes or pods allowed to reach PostgreSQL."
}

variable "operator_security_group_ids" {
  type        = list(string)
  description = "Security groups of in-VPC operator hosts or CI agents that run the DBA bootstrap and the catalogue import (runbook section 2). Each gets PostgreSQL (5432) ingress by security-group reference; there is never a CIDR or public path. Empty: only the workload reaches the database."
  default     = []

  validation {
    condition     = alltrue([for id in var.operator_security_group_ids : can(regex("^sg-[0-9a-f]{8}([0-9a-f]{9})?$", id))])
    error_message = "operator_security_group_ids takes security group ids (sg-...) only, never CIDRs: operator access to PostgreSQL is admitted by security group, not by address."
  }

  validation {
    condition     = length(distinct(var.operator_security_group_ids)) == length(var.operator_security_group_ids)
    error_message = "operator_security_group_ids has duplicates."
  }
}

variable "eks_oidc_provider_arn" {
  type        = string
  description = "IAM OIDC provider ARN of the EKS cluster (IRSA)."
}

variable "eks_oidc_provider_url" {
  type        = string
  description = "IAM OIDC provider URL of the EKS cluster without https:// (IRSA)."
}

variable "kubernetes_namespace" {
  type        = string
  description = "Namespace the Helm chart is installed in."
  default     = "open-finance"
}

variable "kubernetes_service_account" {
  type        = string
  description = "Service account name from the Helm chart."
  default     = "open-products-catalog-service"
}

variable "aurora_engine_version" {
  type        = string
  description = "Aurora PostgreSQL engine version."
  default     = "16.4"
}

variable "aurora_instance_count" {
  type        = number
  description = "Writer plus readers. Two or more places a reader in a second AZ for failover."
  default     = 2

  validation {
    condition     = var.aurora_instance_count >= 1
    error_message = "At least one Aurora instance is required."
  }
}

variable "aurora_min_capacity" {
  type        = number
  description = "Serverless v2 minimum ACUs."
  default     = 0.5
}

variable "aurora_max_capacity" {
  type        = number
  description = "Serverless v2 maximum ACUs."
  default     = 4
}

variable "backup_retention_days" {
  type        = number
  description = "Automated backup retention (point-in-time recovery window)."
  default     = 35

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "The catalogue is a system of record: keep 7 to 35 days of Aurora backups."
  }
}

variable "deletion_protection" {
  type        = bool
  description = "Protect the cluster from deletion."
  default     = true
}

variable "alarm_topic_arn" {
  type        = string
  description = "SNS topic for CloudWatch alarms; empty disables notifications."
  default     = ""
}

variable "database_schema" {
  type        = string
  description = "PostgreSQL schema of the service (Flyway schemas / default-schema). The history-tamper filter matches the schema-qualified history name in pgaudit lines."
  default     = "sc_of_open_products_catalog"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_]{0,62}$", var.database_schema))
    error_message = "database_schema must be a lower-case PostgreSQL identifier (a-z, 0-9, _; not starting with a digit; at most 63 characters)."
  }
}

variable "identity_provider_url" {
  type        = string
  description = "OIDC issuer of the platform Keycloak realm."
}

variable "observability_endpoint" {
  type        = string
  description = "OTLP or metrics endpoint of the platform observability stack."
}

variable "tags" {
  type        = map(string)
  description = "Additional tags (cost centre, data classification)."
  default     = {}
}
