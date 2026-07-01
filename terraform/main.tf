# main.tf
# Terraform infrastructure declaration using the existing public VPC to ensure internet connectivity.

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# 1. Official Rocky Linux 9.8 AMI Filter
data "aws_ami" "rocky_linux" {
  most_recent = true
  owners      = ["792107900819"] # Official Rocky Linux AWS Account

  filter {
    name   = "name"
    values = ["Rocky-9-EC2-Base-9.8-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 2. Query Existing Public VPC and Subnet in us-east-1d for g6e.4xlarge capacity
data "aws_vpc" "selected" {
  id = "vpc-0ff1c679adade279a"
}

data "aws_subnet" "selected" {
  id = "subnet-0428be0140a4d7fd0"
}

# 3. Security Group in the Selected VPC
resource "aws_security_group" "instance" {
  name        = "rocky-gpu-ollama-sg"
  description = "Security Group for GPU instance running Ollama"
  vpc_id      = data.aws_vpc.selected.id

  # SSH Access
  ingress {
    description = "Allow SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # For production, restrict to your public IP
  }

  # Ollama API Access
  ingress {
    description = "Allow Ollama API from anywhere"
    from_port   = 8503
    to_port     = 8503
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # For production, restrict to trusted IPs
  }

  # outbound internet access
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "rocky-gpu-ollama-sg"
  }
}

# 4. SSH Key Pair
resource "aws_key_pair" "deployer" {
  key_name   = var.ssh_key_name
  public_key = file(var.public_key_path)
}

# 5. EC2 GPU Instance in Selected Subnet
resource "aws_instance" "gpu_instance" {
  ami           = data.aws_ami.rocky_linux.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.deployer.key_name
  subnet_id     = data.aws_subnet.selected.id

  vpc_security_group_ids = [aws_security_group.instance.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.volume_size
    delete_on_termination = true
  }

  # Inject automated setup script
  # We prepend appsuser creation since the standalone script assumes the user already exists.
  user_data = join("\n", [
    "#!/bin/bash",
    "id \"appsuser\" >/dev/null 2>&1 || useradd -m appsuser",
    file("${path.module}/../scripts/bluegreen-validation.sh")
  ])

  tags = {
    Name = "rocky-gpu-ollama-instance"
  }
}
