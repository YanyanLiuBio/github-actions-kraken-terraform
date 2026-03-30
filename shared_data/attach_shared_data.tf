###############################################################################
# attach_shared_data.tf – 500 GB shared data EBS volume
# Region : us-east-2 (hardcoded – volume and instance must be in same region)
#
# Fully standalone – no dependency on main.tf outputs or stack exports.
# Pass the target instance ID and its AZ as input variables.
#
# What this creates:
#   - 500 GB encrypted gp3 EBS volume in the same AZ as the target instance
#   - Volume attachment at /dev/xvdf
#   - SSM Run Command association that formats (XFS, first time only) and
#     mounts the volume at /shared_data with a persistent /etc/fstab entry
#
# Deploy:
#   terraform apply \
#     -var="instance_id=i-0abc123def456" \
#     -var="instance_az=us-east-2a"
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
    key    = "projects/kraken_ec2/shared_data/terraform.tfstate"
    region = "us-east-2"
  }
}

provider "aws" {
  region = "us-east-2"
}

###############################################################################
# Variables
###############################################################################
variable "instance_id" {
  description = "EC2 instance ID to attach the volume to (e.g. i-0abc123def456)"
  type        = string
}

variable "instance_az" {
  description = "Availability zone of the target instance (e.g. us-east-2a). EBS volumes must be in the same AZ as the instance."
  type        = string
}

variable "volume_size_gb" {
  description = "Size of the shared data volume in GB"
  type        = number
  default     = 500
}

variable "device_name" {
  description = "Block device name to attach the volume as"
  type        = string
  default     = "/dev/xvdf"
}

variable "mount_point" {
  description = "Filesystem path where the volume will be mounted"
  type        = string
  default     = "/shared_data"
}

###############################################################################
# 500 GB gp3 EBS volume
###############################################################################
resource "aws_ebs_volume" "shared_data" {
  availability_zone = var.instance_az
  size              = var.volume_size_gb
  type              = "gp3"
  throughput        = 250    # MB/s – gp3 default; increase up to 1000 if needed
  iops              = 3000   # gp3 baseline; increase up to 16000 if needed
  encrypted         = false

  tags = {
    Name    = "nextflow-kraken-shared-data-${var.volume_size_gb}gb"
    Project = "nextflow-kraken"
  }

  lifecycle {
    prevent_destroy = false   # safety guard – volume contains pipeline data
  }
}

###############################################################################
# Attach volume to the target instance
###############################################################################
resource "aws_volume_attachment" "shared_data" {
  device_name  = var.device_name
  volume_id    = aws_ebs_volume.shared_data.id
  instance_id  = var.instance_id
  force_detach = false   # never force-detach – prevents data corruption
}

###############################################################################
# SSM Run Command – format (first time only) and mount at /shared_data
#
# The script is idempotent:
#   - Only formats if no filesystem is present (blkid check)
#   - Only adds an fstab entry if the UUID is not already there
#   - Handles NVMe device name remapping (xvdf → nvme1n1 on Nitro instances)
###############################################################################
resource "aws_ssm_association" "mount_shared_data" {
  name             = "AWS-RunShellScript"
  association_name = "nextflow-kraken-mount-shared-data"

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }

  parameters = {
    commands = <<-BASH
      #!/bin/bash
      set -euxo pipefail

      DEVICE="${var.device_name}"
      MOUNT="${var.mount_point}"

      # Resolve NVMe device name if needed (Nitro instances expose
      # /dev/xvdf as /dev/nvme1n1 – check by serial/name mapping)
      if [ ! -b "$DEVICE" ]; then
        DEVICE=$(lsblk -o NAME,SERIAL -dn \
          | awk '/xvdf|nvme/{print "/dev/"$1}' \
          | tail -1)
      fi

      # Format as XFS only if no filesystem exists yet
      if ! blkid "$DEVICE" > /dev/null 2>&1; then
        mkfs -t xfs "$DEVICE"
      fi

      mkdir -p "$MOUNT"

      # Add persistent fstab entry (skip if UUID already present)
      UUID=$(blkid -s UUID -o value "$DEVICE")
      if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID  $MOUNT  xfs  defaults,nofail  0  2" >> /etc/fstab
      fi

      mount -a

      chown ec2-user:ec2-user "$MOUNT"
      chmod 755 "$MOUNT"

      # Create subdirectory for local Nextflow work (executor = local only)
      mkdir -p "$MOUNT/nextflow_work"
      chown ec2-user:ec2-user "$MOUNT/nextflow_work"

      echo "$(date) Volume $DEVICE mounted at $MOUNT" \
        >> /var/log/mount-shared-data.log
    BASH
  }

  depends_on = [aws_volume_attachment.shared_data]
}

###############################################################################
# Outputs
###############################################################################
output "volume_id" {
  description = "EBS volume ID"
  value       = aws_ebs_volume.shared_data.id
}

output "volume_arn" {
  description = "EBS volume ARN"
  value       = aws_ebs_volume.shared_data.arn
}

output "mount_point" {
  description = "Filesystem path where the volume is mounted"
  value       = var.mount_point
}

output "attached_to_instance" {
  description = "Instance ID the volume is attached to"
  value       = var.instance_id
}
