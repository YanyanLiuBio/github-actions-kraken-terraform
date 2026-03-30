###############################################################################
# bootstrap/github_oidc_role.tf
# Run once manually before using GitHub Actions workflows.
# After apply, put the role_arn output into GitHub secret AWS_ROLE_ARN
###############################################################################

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket = "seqwell-terraform-state-storage"
    key    = "projects/kraken_ec2/bootstrap/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" { region = "us-east-2" }

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions" {
  name = "github-actions-kraken-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:YanyanLiuBio/YOUR_KRAKEN_REPO:*" }
      }
    }]
  })
}

locals {
  policies = [
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
    "arn:aws:iam::aws:policy/AmazonSSMFullAccess",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
  ]
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  for_each   = toset(local.policies)
  role       = aws_iam_role.github_actions.name
  policy_arn = each.value
}

output "role_arn" {
  value = aws_iam_role.github_actions.arn
}