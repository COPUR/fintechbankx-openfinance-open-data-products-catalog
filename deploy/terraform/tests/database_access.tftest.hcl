# Plan-only checks of who may reach PostgreSQL (no AWS calls: mocked providers).
# Run: terraform init -backend=false && terraform test

mock_provider "aws" {
  # Mocked policy documents must still be JSON objects for the IAM resources.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}
mock_provider "random" {}

variables {
  aws_region                 = "me-central-1"
  environment                = "dev"
  vpc_id                     = "vpc-0123456789abcdef0"
  private_subnet_ids         = ["subnet-0123456789abcdef0", "subnet-0fedcba9876543210"]
  workload_security_group_id = "sg-0123456789abcdef0"
  eks_oidc_provider_arn      = "arn:aws:iam::111122223333:oidc-provider/oidc.eks.me-central-1.amazonaws.com/id/EXAMPLE"
  eks_oidc_provider_url      = "oidc.eks.me-central-1.amazonaws.com/id/EXAMPLE"
  identity_provider_url      = "https://identity.dev.example.internal/realms/fintechbankx"
  observability_endpoint     = "https://otel.dev.example.internal"
}

run "workload_only_by_default" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.postgres_from_operator) == 0
    error_message = "No operator ingress unless operator_security_group_ids is set."
  }
}

run "one_rule_per_operator_security_group" {
  command = plan

  variables {
    operator_security_group_ids = ["sg-0aaaabbbbccccdddd", "sg-0eeeeffff00001111"]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.postgres_from_operator) == 2
    error_message = "Expected one PostgreSQL ingress rule per operator security group."
  }

  assert {
    condition = alltrue([
      for rule in aws_vpc_security_group_ingress_rule.postgres_from_operator :
      rule.from_port == 5432 && rule.to_port == 5432 && rule.cidr_ipv4 == null && rule.cidr_ipv6 == null
    ])
    error_message = "Operator rules must admit 5432 by security group only, never by CIDR."
  }
}

run "refuses_a_cidr_as_operator_source" {
  command = plan

  variables {
    operator_security_group_ids = ["0.0.0.0/0"]
  }

  expect_failures = [var.operator_security_group_ids]
}

run "refuses_the_workload_group_as_operator_source" {
  command = plan

  variables {
    operator_security_group_ids = ["sg-0123456789abcdef0"]
  }

  expect_failures = [aws_vpc_security_group_ingress_rule.postgres_from_operator]
}

# The history guard (db/bootstrap/history-guard.sql) refuses the schema
# owner's DDL on the history; refusals, a disarmed guard and any DDL that does
# reach the history objects (pgaudit) must page someone (ADR-0001).
run "owner_ddl_is_logged_and_alarmed" {
  command = plan

  variables {
    alarm_topic_arn = "arn:aws:sns:me-central-1:111122223333:open-finance-oncall"
  }

  assert {
    condition = anytrue([
      for p in aws_rds_cluster_parameter_group.database.parameter : p.name == "log_statement" && p.value == "ddl"
    ])
    error_message = "Aurora must log every DDL statement (log_statement=ddl)."
  }

  assert {
    condition     = contains(aws_rds_cluster.database.enabled_cloudwatch_logs_exports, "postgresql")
    error_message = "PostgreSQL logs must reach CloudWatch for the DDL alarm."
  }

  assert {
    condition     = aws_cloudwatch_log_group.postgresql.name == "/aws/rds/cluster/dev-open-products-catalog-service-aurora/postgresql"
    error_message = "The log group must be the one RDS exports the cluster's PostgreSQL log to."
  }

  assert {
    condition = anytrue([
      for p in aws_rds_cluster_parameter_group.database.parameter :
      p.name == "shared_preload_libraries" && contains(split(",", p.value), "pgaudit") && p.apply_method == "pending-reboot"
    ])
    error_message = "pgaudit must be preloaded (applied at the next reboot)."
  }

  assert {
    condition = anytrue([
      for p in aws_rds_cluster_parameter_group.database.parameter : p.name == "pgaudit.log" && p.value == "ddl,role"
    ])
    error_message = "pgaudit must log DDL (including DDL nested in DO/EXECUTE) and role changes."
  }

  assert {
    condition = alltrue([
      for term in ["product_history guard", "sc_of_open_products_catalog.product_history", "append-only"] :
      strcontains(aws_cloudwatch_log_metric_filter.history_tamper.pattern, term)
    ])
    error_message = "The metric filter must catch guard refusals and disarming, pgaudit DDL lines on the history objects and rejected history changes."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.history_tamper.threshold == 1 && aws_cloudwatch_metric_alarm.history_tamper.alarm_actions == toset(["arn:aws:sns:me-central-1:111122223333:open-finance-oncall"])
    error_message = "One matching log line must page the on-call topic."
  }
}
