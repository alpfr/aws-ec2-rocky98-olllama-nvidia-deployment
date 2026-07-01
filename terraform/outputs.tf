# outputs.tf
# Output values for the Rocky Linux 9.8 GPU deployment.

output "ami_id" {
  value       = data.aws_ami.rocky_linux.id
  description = "The ID of the official Rocky Linux 9.8 AMI launched"
}

output "instance_public_ip" {
  value       = aws_instance.gpu_instance.public_ip
  description = "The public IP of the GPU instance"
}

output "ssh_command" {
  value       = "ssh -i <your_private_key_path> rocky@${aws_instance.gpu_instance.public_ip}"
  description = "The command to connect to the instance via SSH"
}

output "ollama_endpoint" {
  value       = "http://${aws_instance.gpu_instance.public_ip}:8502"
  description = "The endpoint URL for the Ollama API"
}

output "ollama_test_command" {
  value       = "curl http://${aws_instance.gpu_instance.public_ip}:8502/api/tags"
  description = "Command to verify if Ollama is running and accessible externally"
}

output "setup_logs_check_command" {
  value       = "ssh -i <your_private_key_path> rocky@${aws_instance.gpu_instance.public_ip} 'tail -f /var/log/bluegreen-validation.log'"
  description = "Command to tail the installation progress logs"
}
