# Terraform Infrastructure for DevOps Environment

This directory contains the Terraform configuration to provision the following GCP resources:
- **VPC & Subnets**: Isolated network for the DevOps tools.
- **Cloud NAT**: To allow the GKE cluster nodes to access the internet.
- **GKE Autopilot**: A fully managed Kubernetes cluster.

## Usage

1.  **Configure GCP**:
    Ensure you are authenticated with `gcloud auth application-default login`.
2.  **Initialize**:
    ```bash
    terraform init
    ```
3.  **Plan**:
    ```bash
    terraform plan -var="project_id=YOUR_PROJECT_ID"
    ```
4.  **Apply**:
    ```bash
    terraform apply -var="project_id=YOUR_PROJECT_ID"
    ```
