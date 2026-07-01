# AWS EC2 Rocky Linux 9.8 NVIDIA GPU & Ollama Deployment

This repository contains:
1. **Infrastructure as Code (IaC)**: Terraform files under the `terraform/` directory to deploy a GPU instance (`g6e.4xlarge`) on AWS.
2. **Standalone Configuration Script**: A bash script under the `scripts/` directory to set up NVIDIA drivers, CUDA, Docker, NVIDIA container runtime, and Ollama on any Rocky Linux 9.8 instance.

---

## 1. Standalone Deployment (Existing EC2 Instance)

If you already have a running Rocky Linux 9.8 EC2 instance with an NVIDIA GPU, you can deploy and validate the Ollama + GPU environment directly without using Terraform.

### Steps:

1. **Copy the script** to your target instance:
   ```bash
   scp -i /path/to/private-key.pem scripts/bluegreen-validation.sh rocky@<ec2-public-ip>:/tmp/
   ```

2. **SSH into your instance**:
   ```bash
   ssh -i /path/to/private-key.pem rocky@<ec2-public-ip>
   ```

3. **Execute the script with root privileges**:
   ```bash
   sudo chmod +x /tmp/bluegreen-validation.sh
   sudo /tmp/bluegreen-validation.sh
   ```

### Customizations:
You can pass custom environment variables to the script:
* Run with a custom test model:
  ```bash
  sudo OLLAMA_TEST_MODEL=llama3.2 /tmp/bluegreen-validation.sh
  ```
* Run with a custom prompt:
  ```bash
  sudo OLLAMA_TEST_PROMPT="Explain quantum computing in one sentence." /tmp/bluegreen-validation.sh
  ```

---

## 2. Automated Provisioning (Using Terraform)

To provision a fresh Rocky Linux 9.8 EC2 instance (`g6e.4xlarge`) and automatically run the validation script:

1. Navigate to the `terraform/` directory:
   ```bash
   cd terraform
   ```

2. Initialize and deploy:
   ```bash
   terraform init
   terraform apply
   ```

3. Monitor logs on the newly launched instance:
   ```bash
   ssh -i <your-key-file> rocky@<ec2-public-ip> "tail -f /var/log/bluegreen-validation.log"
   ```

---

## Script Features & Validations

The `bluegreen-validation.sh` script automates:
* Creation of system user `appsuser` and group configuration.
* Enablement of EPEL and CRB repositories.
* Installation of matching **kernel headers**, development tools, and DKMS.
* Configuration of official **NVIDIA CUDA repository** & installation of drivers and CUDA Toolkit.
* Installation of the **NVIDIA Container Toolkit** and registration of the runtime with Docker.
* Setup of **Ollama** running on custom port `8503` under models path `/data/apps/ollama/models`.
* Shell profile updates for `root` and `appsuser` with CUDA and Ollama environment variables.
* Multi-point health validations (GPU, CUDA, Docker, User Access, Ollama API, and a GPU-accelerated model validation run).
* Generates a final JSON summary report at `/var/log/bluegreen-validation-summary.json`.
