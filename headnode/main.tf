###############################################################################
# main.tf – Nextflow Kraken head node
# Region : us-east-2
#
# What this creates:
#   - Security group (SSH in, all out)
#   - IAM role  nextflow-kraken-headnode-role  (SSM, ECR all repos, S3 any
#     bucket, Batch submit, CloudWatch Logs)
#   - m5.4xlarge EC2 with 200 GB gp3 root volume
#   - Bootstrap: Docker, Java 17, Nextflow, AWS CLI v2
#
# What this does NOT do:
#   - Write nextflow.config  →  see nextflow.config.md, copy manually after boot
#   - Attach the 500 GB shared data volume  →  see attach_shared_data.tf
###############################################################################

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  backend "s3" {
    bucket = "seqwell-terraform-state-storage"
    key    = "projects/kraken_ec2/headnode/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

###############################################################################
# Variables
###############################################################################
variable "ecr_region" {
  description = "AWS region where your ECR registry lives (may differ from us-east-2)"
  type        = string
  default     = "us-east-1"
}

variable "ecr_account_id" {
  description = "AWS account ID that owns the ECR registry"
  type        = string
  default     = "123456789012"   # replace with your account ID
}

###############################################################################
# Locals
###############################################################################
locals {
  ecr_all_repos_arn = "arn:aws:ecr:${var.ecr_region}:${var.ecr_account_id}:repository/*"
  ecr_registry_url  = "${var.ecr_account_id}.dkr.ecr.${var.ecr_region}.amazonaws.com"
}

###############################################################################
# AMI – latest Amazon Linux 2023
###############################################################################
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################################
# Security group
###############################################################################
resource "aws_security_group" "nf_sg" {
  name        = "nextflow-kraken-sg"
  description = "Nextflow Kraken head-node – SSH in, all out"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # restrict to your IP in production
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "nextflow-kraken-sg"
    Project = "nextflow-kraken"
  }
}

###############################################################################
# IAM role – nextflow-kraken-headnode-role
#
# Named with the "kraken" prefix to avoid collision with any existing
# nextflow-headnode-role already present in your account.
#
# S3   : any bucket – bucket is chosen at runtime in nextflow.config workDir
# Batch: no pre-specified job definition – Nextflow auto-registers one per
#        process container via batch:RegisterJobDefinition
# ECR  : all repos in the registry, scoped to ecr_region + ecr_account_id
###############################################################################
resource "aws_iam_role" "nf_role" {
  name = "nextflow-kraken-headnode-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Project = "nextflow-kraken" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.nf_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ecr_pull" {
  name = "nextflow-kraken-ecr-pull-all-repos"
  role = aws_iam_role.nf_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken cannot be scoped – AWS requires Resource: "*"
        Sid      = "ECRAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECRPullAllRepos"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = local.ecr_all_repos_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_any_bucket" {
  name = "nextflow-kraken-s3-any-bucket"
  role = aws_iam_role.nf_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketAccess"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "ObjectAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::*/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "batch_submit" {
  name = "nextflow-kraken-batch-submit"
  role = aws_iam_role.nf_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "BatchSubmitAndManage"
      Effect = "Allow"
      Action = [
        "batch:SubmitJob",
        "batch:DescribeJobs",
        "batch:DescribeJobDefinitions",
        "batch:DescribeJobQueues",
        "batch:RegisterJobDefinition",
        "batch:TerminateJob",
        "batch:CancelJob"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "nextflow-kraken-cloudwatch"
  role = aws_iam_role.nf_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CloudWatchLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ]
      Resource = "arn:aws:logs:us-east-2:*:log-group:/nextflow/*"
    }]
  })
}

resource "aws_iam_instance_profile" "nf_profile" {
  name = "nextflow-kraken-headnode-profile"
  role = aws_iam_role.nf_role.name
}

###############################################################################
# EC2 head node
###############################################################################
resource "aws_instance" "nextflow" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "m5.4xlarge"
  iam_instance_profile   = aws_iam_instance_profile.nf_profile.name
  vpc_security_group_ids = [aws_security_group.nf_sg.id]

  # key_name = "your-key-pair"   # uncomment to enable SSH key access

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 200
    delete_on_termination = true
    encrypted             = false
    tags = {
      Name    = "nextflow-kraken-root-200gb"
      Project = "nextflow-kraken"
    }
  }

  # Bootstrap installs tooling only.
  # nextflow.config is NOT written here – copy it manually from nextflow.config.md
  # after the instance is running.
  user_data = <<-USERDATA
    #!/bin/bash
    set -euxo pipefail

    dnf update -y

    # Docker
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user

    # Java 17 (required by Nextflow)
    dnf install -y java-17-amazon-corretto-headless

    # Nextflow
    curl -s https://get.nextflow.io | bash
    mv nextflow /usr/local/bin/nextflow
    chmod +x /usr/local/bin/nextflow

    # AWS CLI v2
    dnf install -y unzip
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip

    echo "Tooling bootstrap complete – copy nextflow.config from nextflow.config.md" \
      >> /var/log/user-data.log
  USERDATA

  tags = {
    Name    = "nextflow-kraken-headnode"
    Project = "nextflow-kraken"
  }
}

###############################################################################
# Outputs
###############################################################################
output "instance_id" {
  description = "Head node instance ID – use as InstanceId input to attach_shared_data.tf"
  value       = aws_instance.nextflow.id
}

output "instance_public_ip" {
  description = "Public IP of the head node"
  value       = aws_instance.nextflow.public_ip
}

output "availability_zone" {
  description = "AZ of the head node – EBS volume in attach_shared_data.tf must match"
  value       = aws_instance.nextflow.availability_zone
}

output "ecr_registry_url" {
  description = "ECR registry base URL – use as prefix in container directives"
  value       = local.ecr_registry_url
}

output "iam_role_name" {
  description = "Head node IAM role name"
  value       = aws_iam_role.nf_role.name
}




