# =============================================================================
# Infrastructure for Database CI/CD Pipeline (GitHub Actions)
# =============================================================================
# Provisions:
#   - VPC + two private subnets (see network.tf)
#   - OIDC identity provider for GitHub Actions (no static AWS keys)
#   - IAM role assumable by GitHub Actions workflows
#   - RDS PostgreSQL instances for staging and production
#   - Security groups with least-privilege access
#   - S3 bucket for database backups with lifecycle policies
#   - SSM Parameter Store for database credentials
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aws-ha-db"
      Environment = "shared"
      ManagedBy   = "terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC created by this module (private subnets use /24 slices inside it)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "github_org" {
  description = "GitHub org or username for OIDC trust (default is a placeholder — set to your real org before relying on GitHub Actions AssumeRole)"
  type        = string
  default     = "faizananwar532"
}

variable "github_repo" {
  description = "GitHub repository name for OIDC trust (default is a placeholder)"
  type        = string
  default     = "testrepo"
}

# Major version only — RDS selects the default minor for the region (avoids ambiguous engine-version lookups)
variable "postgres_engine_version" {
  type        = string
  default     = "15"
  description = "PostgreSQL engine version for RDS (e.g. 15 or 16)"
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Database passwords (generated — no tfvars required)
# -----------------------------------------------------------------------------

resource "random_password" "db_staging" {
  length  = 32
  special = false
}

resource "random_password" "db_production" {
  length  = 32
  special = false
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC Provider
# -----------------------------------------------------------------------------
# This allows GitHub Actions to assume an IAM role using short-lived tokens
# instead of storing long-lived AWS access keys as secrets.

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "github-actions-oidc"
  }
}

# -----------------------------------------------------------------------------
# IAM Role for GitHub Actions
# -----------------------------------------------------------------------------

resource "aws_iam_role" "github_actions" {
  name = "github-actions-db-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Only allow workflows from this specific repo
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = {
    Name = "github-actions-db-deploy"
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name = "github-actions-db-deploy-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BackupAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.db_backups.arn,
          "${aws_s3_bucket.db_backups.arn}/*"
        ]
      },
      {
        Sid    = "SSMParameterRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/cicd-pipeline/*"
      },
      {
        Sid    = "RDSDescribe"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Security Group — Database Access from GitHub Actions runners
# -----------------------------------------------------------------------------
# Note: GitHub-hosted runners use dynamic IPs. For production, consider
# self-hosted runners inside the VPC or use AWS RDS Proxy with IAM auth.

resource "aws_security_group" "database" {
  name        = "cicd-pipeline-database-sg"
  description = "Database access for CI/CD pipeline"
  vpc_id      = aws_vpc.main.id

  # Tighten this to runner/bastion SG CIDRs in production. GitHub-hosted runners
  # cannot reach private RDS without VPN, bastion, or self-hosted runners in this VPC.
  ingress {
    description = "PostgreSQL from VPC CIDR"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "cicd-pipeline-database-sg"
  }
}

# -----------------------------------------------------------------------------
# RDS Subnet Group
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "pipeline" {
  name        = "cicd-pipeline-db-subnet-group"
  description = "Subnet group for CI/CD pipeline databases"
  subnet_ids  = aws_subnet.private[*].id

  tags = {
    Name = "cicd-pipeline-db-subnet-group"
  }
}

# -----------------------------------------------------------------------------
# Staging Database
# -----------------------------------------------------------------------------

resource "aws_db_instance" "staging" {
  identifier = "cicd-pipeline-staging"

  engine               = "postgres"
  engine_version       = var.postgres_engine_version
  instance_class       = "db.t4g.micro"
  allocated_storage    = 20
  storage_type         = "gp3"
  storage_encrypted    = true

  db_name  = "appdb_staging"
  username = "dbadmin"
  password = random_password.db_staging.result
  port     = 5432

  multi_az               = false
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.pipeline.name
  vpc_security_group_ids = [aws_security_group.database.id]

  backup_retention_period = 1
  skip_final_snapshot     = true

  auto_minor_version_upgrade = true

  tags = {
    Name        = "cicd-pipeline-staging"
    Environment = "staging"
  }
}

# -----------------------------------------------------------------------------
# Production Database
# -----------------------------------------------------------------------------

# Same size as staging — suitable for testing / dev. For real production, increase instance_class, enable multi_az, deletion_protection, etc.
resource "aws_db_instance" "production" {
  identifier = "cicd-pipeline-production"

  engine               = "postgres"
  engine_version       = var.postgres_engine_version
  instance_class       = "db.t4g.micro"
  allocated_storage    = 20
  storage_type         = "gp3"
  storage_encrypted    = true

  db_name  = "appdb_production"
  username = "dbadmin"
  password = random_password.db_production.result
  port     = 5432

  multi_az               = false
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.pipeline.name
  vpc_security_group_ids = [aws_security_group.database.id]

  backup_retention_period = 1
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true
  skip_final_snapshot     = true
  deletion_protection     = false

  auto_minor_version_upgrade = true

  tags = {
    Name        = "cicd-pipeline-production"
    Environment = "production"
  }
}

# -----------------------------------------------------------------------------
# S3 Bucket for Database Backups
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "db_backups" {
  bucket = "cicd-pipeline-db-backups-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "cicd-pipeline-db-backups"
  }
}

resource "aws_s3_bucket_versioning" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# SSM Parameters for Database Credentials
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "db_staging_host" {
  name  = "/cicd-pipeline/staging/db-host"
  type  = "String"
  value = aws_db_instance.staging.endpoint
}

resource "aws_ssm_parameter" "db_prod_host" {
  name  = "/cicd-pipeline/production/db-host"
  type  = "String"
  value = aws_db_instance.production.endpoint
}

resource "aws_ssm_parameter" "db_staging_password" {
  name  = "/cicd-pipeline/staging/db-password"
  type  = "SecureString"
  value = random_password.db_staging.result
}

resource "aws_ssm_parameter" "db_prod_password" {
  name  = "/cicd-pipeline/production/db-password"
  type  = "SecureString"
  value = random_password.db_production.result
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions — add this as AWS_ROLE_ARN secret in GitHub"
  value       = aws_iam_role.github_actions.arn
}

output "staging_endpoint" {
  description = "Staging database endpoint"
  value       = aws_db_instance.staging.endpoint
}

output "production_endpoint" {
  description = "Production database endpoint"
  value       = aws_db_instance.production.endpoint
}

output "backup_bucket" {
  description = "S3 bucket for database backups"
  value       = aws_s3_bucket.db_backups.bucket
}

output "vpc_id" {
  description = "Created VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (two AZs) used by RDS"
  value       = aws_subnet.private[*].id
}

output "staging_db_password" {
  description = "Generated staging master password (copy to GitHub secret DB_STAGING_PASSWORD once)"
  value       = random_password.db_staging.result
  sensitive   = true
}

output "production_db_password" {
  description = "Generated production master password (copy to GitHub secret DB_PROD_PASSWORD once)"
  value       = random_password.db_production.result
  sensitive   = true
}
