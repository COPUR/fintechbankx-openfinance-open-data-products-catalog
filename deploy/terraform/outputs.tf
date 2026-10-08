output "workload_role_arn" {
  description = "IRSA role for the Helm value serviceAccount.roleArn."
  value       = aws_iam_role.workload.arn
}

output "jdbc_url" {
  description = "Helm value config.DB_URL: TLS with server-certificate and host-name verification against the RDS CA bundle the chart mounts from the platform ConfigMap rds-ca-bundle."
  value       = "jdbc:postgresql://${aws_rds_cluster.database.endpoint}:5432/${local.database}?sslmode=verify-full&sslrootcert=/etc/fintechbankx/rds-ca/global-bundle.pem"
}

output "reader_endpoint" {
  description = "Aurora reader endpoint for reporting and reconciliation queries."
  value       = aws_rds_cluster.database.reader_endpoint
}

output "app_db_secret_name" {
  description = "Helm value externalSecret.remoteSecretName."
  value       = aws_secretsmanager_secret.app_database.name
}

output "migration_db_secret_name" {
  description = "Helm value externalSecret.migrationRemoteSecretName."
  value       = aws_secretsmanager_secret.migration_database.name
}

output "import_db_secret_name" {
  description = "Credential for db/import/import-products.sh (operators only)."
  value       = aws_secretsmanager_secret.import_database.name
}

output "master_user_secret_arn" {
  description = "RDS-managed admin credential, for the DBA bootstrap only."
  value       = aws_rds_cluster.database.master_user_secret[0].secret_arn
}

output "log_group_name" {
  value = module.service_base.cloudwatch_log_group_name
}

output "postgresql_log_group_arn" {
  description = "PostgreSQL log group (pgaudit, guard messages). Read access belongs to the security and DBA roles only; scope their IAM read grants (logs:GetLogEvents, FilterLogEvents, StartQuery) to this ARN."
  value       = aws_cloudwatch_log_group.postgresql.arn
}
