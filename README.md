# AWS EC2 K3s Deployment with Prometheus Monitoring

## Overview

This project demonstrates automated provisioning and configuration of a Kubernetes (k3s) cluster on AWS EC2, complete with application deployment and Prometheus monitoring.

## Features

- **Automated EC2 Provisioning**: Creates and configures an Ubuntu 22.04 instance on AWS
- **K3s Kubernetes**: Lightweight Kubernetes distribution perfect for edge and development
- **Application Deployment**: Deploys Nginx and a demo web application using Helm
- **Monitoring Stack**: Full Prometheus and Grafana setup for metrics collection
- **Security Configuration**: Proper networking and security group settings
- **One-Command Deployment**: Single script handles the entire infrastructure

## Architecture

```
┌─────────────────────────────────────────┐
│           AWS EC2 Instance              │
│         (Ubuntu 22.04, t3.small)        │
├─────────────────────────────────────────┤
│              K3s Cluster                │
├─────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────┐  │
│  │  Nginx   │  │Demo App  │  │ Prom │  │
│  │  (Helm)  │  │  (K8s)   │  │Stack │  │
│  └──────────┘  └──────────┘  └──────┘  │
└─────────────────────────────────────────┘
```

## Prerequisites

- AWS Account with appropriate permissions
- AWS CLI installed and configured
- Bash shell (Linux/macOS/WSL)
- Internet connection

### Required AWS Permissions

The IAM user/role needs the following permissions:
- EC2: Full access (or at minimum: RunInstances, DescribeInstances, CreateKeyPair, CreateSecurityGroup, AuthorizeSecurityGroupIngress)
- VPC: DescribeVpcs, CreateDefaultVpc

## Quick Start

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd scripts
   ```

2. **Make the script executable**
   ```bash
   chmod +x k3s-deployment.sh
   ```

3. **Set your AWS region (optional)**
   ```bash
   export AWS_REGION=us-east-2  
   ```

4. **Run the deployment**
   ```bash
   bash k3s-deployment.sh
   ```

5. **Wait for completion** (approximately 5-10 minutes for full setup)

## What Gets Deployed

### Infrastructure Components

| Component | Details |
|-----------|---------|
| **EC2 Instance** | Ubuntu 22.04 LTS, t3.small |
| **Security Group** | Allows SSH (22), HTTP (80), K8s API (6443), NodePorts (30000-32767), Prometheus (9090) |
| **SSH Key Pair** | Auto-generated and saved locally |
| **VPC** | Uses default VPC or creates one if needed |

### Kubernetes Applications

| Application | Namespace | Access Port | Purpose |
|-------------|-----------|-------------|---------|
| **Nginx** | nginx | 30080 | Web server with metrics endpoint |
| **Prometheus** | monitoring | 30090 | Metrics collection and storage |
| **Grafana** | monitoring | 30300 | Metrics visualization |

## Accessing the Deployment

After deployment completes, you'll receive connection information:

### SSH Access
```bash
ssh -i vxg-demo-key.pem ubuntu@<PUBLIC_IP>
```

### Web Services
- **Nginx**: `http://<PUBLIC_IP>:30080`
- **Prometheus**: `http://<PUBLIC_IP>:30090`
- **Grafana**: `http://<PUBLIC_IP>:30300`
  - Username: `admin`
  - Password: `vxg-demo-2024`

### Kubernetes Access

1. **From the EC2 instance**:
   ```bash
   kubectl get nodes
   kubectl get pods -A
   ```

2. **From your local machine**:
   ```bash
   # Download kubeconfig
   scp -i vxg-demo-key.pem ubuntu@<PUBLIC_IP>:/etc/rancher/k3s/k3s.yaml /etc/rancher/k3s/k3s.yaml
   
   # Update the server address
   sed -i 's/127.0.0.1/<PUBLIC_IP>/g' /etc/rancher/k3s/k3s.yaml
   
   # Use the config
   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
   kubectl get nodes
   ```

## Monitoring and Metrics

### Available Metrics

The deployment automatically configures several metric sources:

1. **Node Metrics**: CPU, memory, disk, network statistics from the EC2 instance
2. **Kubernetes Metrics**: Pod, deployment, and service statistics
3. **Nginx Metrics**: Request rates, response times, error rates
4. **Application Metrics**: Basic HTTP metrics from the demo app

### Viewing Metrics in Prometheus

1. Navigate to `http://<PUBLIC_IP>:30090`
2. Use the expression browser to query metrics
3. Example queries:
   ```promql
   # CPU usage
   100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
   
   # Memory usage
   (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100

   ```

### Screenshots

<img width="1847" height="943" alt="Screenshot 2025-09-22 025141" src="https://github.com/user-attachments/assets/e58f1213-bbeb-4a79-9de9-c0c6336b4d54" />

### Using Grafana Dashboards

1. Access Grafana at `http://<PUBLIC_IP>:30300`
2. Login with `admin` / `vxg-demo-2024`
3. Navigate to Dashboards → Browse
4. Pre-installed dashboards include:
   - Kubernetes cluster overview
   - Node exporter full
   - Nginx metrics

## Verification Steps

After deployment, verify everything is working:

```bash
# Check instance status
aws ec2 describe-instances --instance-ids <INSTANCE_ID>

# SSH into the instance
ssh -i vxg-demo-key.pem ubuntu@<PUBLIC_IP>

# Check k3s status
sudo systemctl status k3s

# Check all pods are running
kubectl get pods -A

# Check services
kubectl get svc -A

# Test Nginx
curl http://<PUBLIC_IP>:30080

```

## Cleanup

To remove all created resources:

```bash
./k3s-deployment.sh cleanup
```

This will:
- Terminate the EC2 instance
- Delete the security group
- Remove the SSH key pair

**Note**: The local SSH key file (`vxg-demo-key.pem`) will remain and should be deleted manually if no longer needed.

## Troubleshooting

### Common Issues

1. **Script fails with permission errors**
   - Ensure AWS CLI is configured: `aws configure`
   - Verify IAM permissions

2. **Cannot access web services**
   - Wait 5-10 minutes for k3s setup to complete
   - Check security group rules
   - Verify instance is running: `aws ec2 describe-instances`

3. **SSH connection refused**
   - Ensure you're using the correct key file
   - Check the security group allows SSH from your IP
   - Wait for instance to fully initialize

4. **Pods not starting**
   ```bash
   # Check pod status
   kubectl get pods -A
   kubectl describe pod <pod-name> -n <namespace>
   
   # Check logs
   kubectl logs <pod-name> -n <namespace>
   ```

### Monitoring Setup Status

Watch the cloud-init logs to monitor setup progress:

```bash
ssh -i vxg-demo-key.pem ubuntu@<PUBLIC_IP> 'sudo tail -f /var/log/cloud-init-output.log'
```

## Technical Details

### K3s Configuration

- Kubernetes version: Latest stable
- Container runtime: containerd
- Network: Flannel (default)
- Storage: Local path provisioner

### Helm Charts Used

- **nginx**: `bitnami/nginx`
  - Configured with metrics exporter
  - 2 replicas for high availability
  
- **prometheus-stack**: `prometheus-community/kube-prometheus-stack`
  - Includes Prometheus Operator
  - Node Exporter for system metrics
  - Kube State Metrics for Kubernetes metrics
  - Grafana with pre-configured dashboards

### Security Considerations

- Security group restricts access to necessary ports only
- SSH key is generated per deployment
- Consider restricting SSH access to specific IPs in production
- Grafana uses a default password - change it for production use
- All services use NodePort - consider LoadBalancer or Ingress for production



## Project Structure

```
.
├── k3s-deployment.sh              # Main deployment script
├── README.md             # This file
├── deployment-info.txt   # Generated after deployment

```

## Contributing

This project was created as a test task. Feel free to fork and adapt for your own use cases.

## License

MIT License - See LICENSE file for details

---

