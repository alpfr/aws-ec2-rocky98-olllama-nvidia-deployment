# variables.tf
# Variable declarations for Rocky Linux 9.8 EC2 deployment.

variable "aws_region" {
  type        = string
  description = "The AWS region to deploy resources in"
  default     = "us-east-1"
}

variable "instance_type" {
  type        = string
  description = "The AWS EC2 instance type with GPU capabilities"
  default     = "g6e.4xlarge"
}

variable "ssh_key_name" {
  type        = string
  description = "The name of the SSH Key Pair to create in AWS"
  default     = "rocky-gpu-ollama-key"
}

variable "public_key_path" {
  type        = string
  description = "The path to the local SSH public key to be imported into AWS"
  default     = "~/.ssh/id_rsa.pub"
}

variable "volume_size" {
  type        = number
  description = "The size of the root EBS volume in GBs (minimum 50GB recommended for CUDA and models)"
  default     = 100
}
