#!/bin/bash

# AWS EC2 K3s Deployment Script for VXG
# This script provisions an EC2 instance, installs k3s, and deploys Nginx and Prometheus

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables
INSTANCE_NAME="vxg-k3s-demo"
KEY_NAME="vxg-demo-key"
SECURITY_GROUP_NAME="vxg-k3s-sg"
AMI_ID="ami-0cfde0ea8edd312d4"
INSTANCE_TYPE="t3.small"
REGION="${AWS_REGION:-us-east-2}"
USER_DATA_FILE="./k3s-userdata.sh"

# Function to print colored messages
print_message() {
    echo -e "${2}${1}${NC}"
}

# Function to check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_message "AWS CLI is not installed. Please install it first." "$RED"
        exit 1
    fi
    print_message "✓ AWS CLI found" "$GREEN"
}

# Function to check AWS credentials
check_aws_credentials() {
    if ! aws sts get-caller-identity &> /dev/null; then
        print_message "AWS credentials are not configured. Please configure them first." "$RED"
        exit 1
    fi
    print_message "✓ AWS credentials configured" "$GREEN"
}

# Function to create key pair
create_key_pair() {
    print_message "Creating SSH key pair..." "$YELLOW"
    
    # Check if key already exists
    if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" 2>/dev/null; then
        print_message "Key pair $KEY_NAME already exists" "$YELLOW"
    else
        aws ec2 create-key-pair \
            --key-name "$KEY_NAME" \
            --region "$REGION" \
            --query 'KeyMaterial' \
            --output text > "${KEY_NAME}.pem"
        
        chmod 400 "${KEY_NAME}.pem"
        print_message "✓ Key pair created and saved to ${KEY_NAME}.pem" "$GREEN"
    fi
}

# Function to get default VPC ID
get_vpc_id() {
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=is-default,Values=true" \
        --region "$REGION" \
        --query 'Vpcs[0].VpcId' \
        --output text)
    
    if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
        print_message "No default VPC found. Creating one..." "$YELLOW"
        aws ec2 create-default-vpc --region "$REGION"
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=is-default,Values=true" \
            --region "$REGION" \
            --query 'Vpcs[0].VpcId' \
            --output text)
    fi
    
    print_message "✓ Using VPC: $VPC_ID" "$GREEN"
}

# Function to create security group
create_security_group() {
    print_message "Creating security group..." "$YELLOW"
    
    # Check if security group exists
    SG_ID=$(aws ec2 describe-security-groups \
        --group-names "$SECURITY_GROUP_NAME" \
        --region "$REGION" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
        # Create security group
        SG_ID=$(aws ec2 create-security-group \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "Security group for K3s cluster" \
            --vpc-id "$VPC_ID" \
            --region "$REGION" \
            --query 'GroupId' \
            --output text)
        
        print_message "✓ Security group created: $SG_ID" "$GREEN"
        
        # Add inbound rules
        print_message "Adding security group rules..." "$YELLOW"
        
        # SSH access
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region "$REGION"
        
        # HTTP access
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 80 \
            --cidr 0.0.0.0/0 \
            --region "$REGION"
        
        # Kubernetes API server
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 6443 \
            --cidr 0.0.0.0/0 \
            --region "$REGION"
        
        # NodePort services range
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 30000-32767 \
            --cidr 0.0.0.0/0 \
            --region "$REGION"
        
        # Prometheus port
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 9090 \
            --cidr 0.0.0.0/0 \
            --region "$REGION"
        
        print_message "✓ Security group rules added" "$GREEN"
    else
        print_message "Security group $SECURITY_GROUP_NAME already exists: $SG_ID" "$YELLOW"
    fi
}

# Function to create user data script
create_user_data() {
    cat > "$USER_DATA_FILE" << 'EOF'
#!/bin/bash
set -e

# Update system
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y curl wget git

# Install k3s
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

# Wait for k3s to be ready
sleep 30
until kubectl get nodes 2>/dev/null; do
    echo "Waiting for k3s to be ready..."
    sleep 5
done

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Add Helm repositories
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add stable https://charts.helm.sh/stable
helm repo update

# Create namespaces
kubectl create namespace nginx || true
kubectl create namespace monitoring || true

mkdir -p /home/ubuntu/configs

# Deploy Nginx with Helm
cat > /home/ubuntu/configs/nginx-values.yaml << 'NGINX_VALUES'
service:
  type: NodePort
  nodePorts:
    http: 30080
replicaCount: 2
metrics:
  enabled: true
  service:
    port: 9113
NGINX_VALUES

helm upgrade --install nginx bitnami/nginx \
    --namespace nginx \
    --values /home/ubuntu/configs/nginx-values.yaml \
    --wait || echo "Nginx Helm install failed!"

# Deploy Prometheus with Helm
cat > /home/ubuntu/configs/prometheus-values.yaml << 'PROM_VALUES'
prometheus:
  service:
    type: NodePort
    nodePort: 30090
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
alertmanager:
  enabled: false
grafana:
  enabled: true
  service:
    type: NodePort
    nodePort: 30300
  adminPassword: "vxg-demo-2024"
PROM_VALUES

# Install kube-prometheus-stack (includes Prometheus, Grafana, and exporters)
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --values /home/ubuntu/configs/prometheus-values.yaml \
    --wait || echo "Prometheus Helm install failed!"

# Create ServiceMonitor for Nginx metrics
cat > /home/ubuntu/configs/nginx-servicemonitor.yaml << 'SM_YAML'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nginx-metrics
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx
  namespaceSelector:
    matchNames:
    - nginx
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
SM_YAML

kubectl apply -f /home/ubuntu/configs/nginx-servicemonitor.yaml

# Save cluster info
cat > /home/ubuntu/cluster-info.txt << 'INFO'
K3s Cluster Information
=======================

Kubernetes API: https://<PUBLIC_IP>:6443
Nginx: http://<PUBLIC_IP>:30080
Prometheus: http://<PUBLIC_IP>:30090
Grafana: http://<PUBLIC_IP>:30300

Grafana Credentials:
Username: admin
Password: vxg-demo-2024

To access kubectl remotely:
1. Copy /etc/rancher/k3s/k3s.yaml to your local machine
2. Replace 127.0.0.1 with the public IP
3. Set KUBECONFIG environment variable

Useful commands:
- kubectl get nodes
- kubectl get pods -A
- kubectl get svc -A
- helm list -A
INFO

echo "K3s cluster setup completed successfully!"
EOF
    
    print_message "✓ User data script created" "$GREEN"
}

# Function to launch EC2 instance
launch_instance() {
    print_message "Launching EC2 instance..." "$YELLOW"
    
    # Check if instance with the same name already exists
    EXISTING_INSTANCE=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
                  "Name=instance-state-name,Values=running,pending" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null || echo "None")
    
    if [ "$EXISTING_INSTANCE" != "None" ] && [ -n "$EXISTING_INSTANCE" ]; then
        print_message "Instance $INSTANCE_NAME already exists: $EXISTING_INSTANCE" "$YELLOW"
        INSTANCE_ID="$EXISTING_INSTANCE"
    else
        INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --key-name "$KEY_NAME" \
            --security-group-ids "$SG_ID" \
            --user-data file://"$USER_DATA_FILE" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Environment,Value=Demo},{Key=Project,Value=VXG}]" \
            --region "$REGION" \
            --query 'Instances[0].InstanceId' \
            --output text)
        
        print_message "✓ Instance launched: $INSTANCE_ID" "$GREEN"
    fi
    
    # Wait for instance to be running
    print_message "Waiting for instance to be running..." "$YELLOW"
    aws ec2 wait instance-running \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION"
    
    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    print_message "✓ Instance is running with public IP: $PUBLIC_IP" "$GREEN"
}

# Function to display connection information
display_info() {
    echo ""
    print_message "========================================" "$GREEN"
    print_message "Deployment Successful!" "$GREEN"
    print_message "========================================" "$GREEN"
    echo ""
    print_message "Instance ID: $INSTANCE_ID" "$YELLOW"
    print_message "Public IP: $PUBLIC_IP" "$YELLOW"
    echo ""
    print_message "SSH Access:" "$YELLOW"
    echo "  ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
    echo ""
    print_message "Wait 5-10 minutes for k3s setup to complete, then access:" "$YELLOW"
    echo "  Nginx: http://$PUBLIC_IP:30080"
    echo "  Prometheus: http://$PUBLIC_IP:30090"
    echo "  Grafana: http://$PUBLIC_IP:30300 (admin/vxg-demo-2024)"
    echo ""
    print_message "To check setup status:" "$YELLOW"
    echo "  ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo tail -f /var/log/cloud-init-output.log'"
    echo ""
    print_message "To get kubeconfig:" "$YELLOW"
    echo "  scp -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP:/etc/rancher/k3s/k3s.yaml ./kubeconfig"
    echo "  sed -i 's/127.0.0.1/$PUBLIC_IP/g' ./kubeconfig"
    echo "  export KUBECONFIG=./kubeconfig"
    echo ""
    
    # Save instance information to file
    cat > deployment-info.txt << EOF
VXG K3s Deployment Information
==============================
Date: $(date)
Instance ID: $INSTANCE_ID
Public IP: $PUBLIC_IP
Region: $REGION
Security Group: $SG_ID
Key Pair: $KEY_NAME

Access URLs:
- SSH: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP
- Nginx: http://$PUBLIC_IP:30080
- Prometheus: http://$PUBLIC_IP:30090
- Grafana: http://$PUBLIC_IP:30300

Grafana Credentials:
- Username: admin
- Password: vxg-demo-2024
EOF
    
    print_message "✓ Deployment information saved to deployment-info.txt" "$GREEN"
}

# Function to cleanup resources
cleanup() {
    print_message "Cleaning up resources..." "$YELLOW"
    
    # Terminate instance
    if [ -n "$INSTANCE_ID" ]; then
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
        aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
    fi
    
    # Delete security group
    if [ -n "$SG_ID" ]; then
        aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
    fi
    
    # Delete key pair
    aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION" 2>/dev/null || true
    
    print_message "✓ Cleanup completed" "$GREEN"
}

# Main execution
main() {
    print_message "Starting AWS EC2 K3s Deployment for VXG" "$GREEN"
    print_message "========================================" "$GREEN"
    
    # Parse command line arguments
    case "${1:-deploy}" in
        cleanup)
            cleanup
            exit 0
            ;;
        deploy)
            ;;
        *)
            echo "Usage: $0 [deploy|cleanup]"
            exit 1
            ;;
    esac
    
    # Check prerequisites
    check_aws_cli
    check_aws_credentials
    
    # Setup infrastructure
    create_key_pair
    get_vpc_id
    create_security_group
    create_user_data
    
    # Launch and configure instance
    launch_instance
    
    # Display connection information
    display_info
    
    # Cleanup temp file
    rm -f "$USER_DATA_FILE"
    
    print_message "Deployment script completed!" "$GREEN"
    print_message "Note: K3s installation will continue in the background for 5-10 minutes." "$YELLOW"
}

# Run main function
main "$@"