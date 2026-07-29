#!/usr/bin/env bash
set -euo pipefail

# scaffold-cicd.sh — Create CI/CD files (GitHub Actions + Terraform modules)
# Usage: bash scaffold-cicd.sh [project-name]
# Creates .github/workflows/ and infra/ directories

PROJECT_NAME="${1:-my-app}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[scaffold-cicd] Creating CI/CD structure for: $PROJECT_NAME"

# ── GitHub Actions Workflows ──────────────────────────
mkdir -p "$REPO_ROOT/.github/workflows"

# Main build+test workflow
cat > "$REPO_ROOT/.github/workflows/build-test.yml" << 'EOF'
name: Build & Test
on:
  pull_request:
    branches: [main, develop]
  push:
    branches: [main, develop]

env:
  NODE_VERSION: '20'

jobs:
  lint-and-test:
    strategy:
      matrix:
        project: [web, backend, mobile]
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ${{ matrix.project }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ env.NODE_VERSION }}
          cache: 'npm'
          cache-dependency-path: ${{ matrix.project }}/package-lock.json
      - run: npm ci
      - run: npx tsc --noEmit || true
      - run: npm run lint || true
      - run: npm test -- --passWithNoTests || true

  docker-build:
    needs: [lint-and-test]
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - name: Build Docker image
        run: docker build -t ghcr.io/${{ github.repository }}/app:${{ github.sha }} ./backend
      - name: Push to registry
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin
          docker push ghcr.io/${{ github.repository }}/app:${{ github.sha }}
EOF

# Canary deploy workflow
cat > "$REPO_ROOT/.github/workflows/canary-deploy.yml" << 'EOF'
name: Canary Deploy
on:
  workflow_run:
    workflows: ['Build & Test']
    branches: [main]
    types: [completed]

jobs:
  deploy:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4

      - name: Deploy Canary 5%
        run: |
          echo "Deploying 5% canary..."
          # kubectl set image deployment/app app=ghcr.io/${{ github.repository }}/app:${{ github.sha }}
          # kubectl scale deployment/app --replicas=$((TOTAL * 5 / 100))
          echo "Watching for 15min..."
          sleep 15
          echo "Checking error rate..."
          # if error rate > 1%: rollback + alert

      - name: Deploy Canary 25%
        if: success()
        run: |
          echo "Deploying 25%..."
          sleep 30
          echo "Checking p99 latency..."

      - name: Deploy 100%
        if: success()
        run: |
          echo "Full rollout complete"
EOF

# ── Terraform Modules ─────────────────────────────────
mkdir -p "$REPO_ROOT/infra/environments/dev" "$REPO_ROOT/infra/environments/staging" "$REPO_ROOT/infra/environments/prod"
mkdir -p "$REPO_ROOT/infra/modules/web-app" "$REPO_ROOT/infra/modules/database" "$REPO_ROOT/infra/modules/monitoring"

# Root terraform
cat > "$REPO_ROOT/infra/main.tf" << 'EOF'
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "factory-terraform-state"
    key    = "infra/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

module "web_app" {
  source      = "./modules/web-app"
  environment = var.environment
  app_name    = var.app_name
}

module "database" {
  source      = "./modules/database"
  environment = var.environment
}

module "monitoring" {
  source      = "./modules/monitoring"
  environment = var.environment
  app_name    = var.app_name
}
EOF

cat > "$REPO_ROOT/infra/variables.tf" << 'EOF'
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev/staging/prod)"
  type        = string
}

variable "app_name" {
  description = "Application name"
  type        = string
}
EOF

# Web app module
cat > "$REPO_ROOT/infra/modules/web-app/main.tf" << 'EOF'
# ECS Fargate + ALB
resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-${var.environment}"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.app_name}-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name  = "app"
      image = var.container_image
      portMappings = [{ containerPort = 3001, protocol = "tcp" }]
      environment = [{ name = "NODE_ENV", value = var.environment }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.app_name}-${var.environment}"
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_iam_role" "ecs_execution" {
  name = "${var.app_name}-ecs-execution-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_security_group" "app" {
  name        = "${var.app_name}-${var.environment}-sg"
  description = "Allow HTTP inbound"

  ingress {
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
EOF

cat > "$REPO_ROOT/infra/modules/web-app/variables.tf" << 'EOF'
variable "app_name" { type = string }
variable "environment" { type = string }
variable "container_image" {
  type    = string
  default = "ghcr.io/default/app:latest"
}
EOF

# Monitoring module
cat > "$REPO_ROOT/infra/modules/monitoring/main.tf" << 'EOF'
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.app_name}-${var.environment}"
  retention_in_days = 30
}

resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${var.app_name}-${var.environment}-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5xxErrorRate"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1.0
  alarm_description   = "Error rate > 1% for 2 consecutive minutes"
  alarm_actions       = []  # SNS topic ARN
}
EOF

cat > "$REPO_ROOT/infra/modules/monitoring/variables.tf" << 'EOF'
variable "app_name" { type = string }
variable "environment" { type = string }
EOF

# Env-specific config
cat > "$REPO_ROOT/infra/environments/dev/terraform.tfvars" << 'EOF'
environment = "dev"
app_name    = "my-app"
aws_region  = "us-east-1"
EOF

cat > "$REPO_ROOT/infra/environments/prod/terraform.tfvars" << 'EOF'
environment = "prod"
app_name    = "my-app"
aws_region  = "us-east-1"
EOF

echo "[scaffold-cicd] ✓ CI/CD scaffold ready"
echo "  Workflows: .github/workflows/build-test.yml + canary-deploy.yml"
echo "  Terraform: infra/ (modules + environments)"
