#!/bin/bash
set -e

echo ""
echo "+==============================================================+"
echo "|                      K8s Monitoring Lab                      |"
echo "|              Prometheus + Grafana + MongoDB Exporter         |"
echo "+==============================================================+"
echo ""

echo "[1/12] Updating package manager..."
sudo apt-get update

echo "[2/12] Installing required tools..."
sudo apt-get install -y curl wget conntrack

echo "[3/12] Installing Docker..."
if ! command -v docker &> /dev/null; then
    sudo apt-get install -y docker.io
    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker $USER
    newgrp docker << EONG
    echo "Docker group changes applied successfully."
EONG
else
    echo "Docker is already installed, skipping installation..."
fi

echo "[4/12] Installing kubectl..."
if ! command -v kubectl &> /dev/null; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
else
    echo "kubectl is already installed, skipping installation..."
fi

echo "[5/12] Installing Minikube..."
if ! command -v minikube &> /dev/null; then
    curl -LO  https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
else
    echo "Minikube is already installed, skipping installation..."
fi

echo "[6/12] Starting Minikube..."
# Clean up any existing minikube configuration
minikube delete 2>/dev/null || true
minikube start --cpus 4 --memory 4096 --driver=docker

echo "[7/12] Setting up kubectl..."
alias kubectl="minikube kubectl --"
echo "alias kubectl='minikube kubectl --'" >> ~/.bashrc

echo "[8/12] Installing Helm..."
if ! command -v helm &> /dev/null; then
    curl -sSL https://get.helm.sh/helm-v3.18.3-linux-amd64.tar.gz -o helm.tar.gz
    tar -zxvf helm.tar.gz
    sudo mv linux-amd64/helm /usr/local/bin/helm
    rm -rf helm.tar.gz linux-amd64
else
    echo "Helm is already installed, skipping installation..."
fi

echo "[9/12] Installing Prometheus Stack with Minikube optimizations..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm uninstall prometheus 2>/dev/null || true
sleep 5
helm install prometheus prometheus-community/kube-prometheus-stack \
  --set prometheus.prometheusSpec.externalLabels.cluster=minikube \
  --set prometheus.prometheusSpec.retention=1d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=1Gi \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.probeSelectorNilUsesHelmValues=false

echo "[10/12] Deploying MongoDB and Exporter..."
curl -sLO https://raw.githubusercontent.com/of1r/k8s-monitoring-lab/main/mongodb.yaml
kubectl apply -f mongodb.yaml
curl -sLO https://raw.githubusercontent.com/of1r/k8s-monitoring-lab/main/values.yaml
helm uninstall mongodb-exporter 2>/dev/null || true
sleep 5
helm install mongodb-exporter prometheus-community/prometheus-mongodb-exporter -f values.yaml

echo "[11/12] Waiting for services to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n default --timeout=180s || echo "Grafana ready"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n default --timeout=180s || echo "Prometheus ready"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-mongodb-exporter --timeout=120s || echo "MongoDB exporter ready"

echo "[12/12] Setting up secure access and fixing Prometheus targets..."
# Start port forwarding for local access
echo "Starting port forwarding for secure access..."
kubectl port-forward svc/prometheus-grafana 3000:80 &
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 &
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093 &
kubectl port-forward svc/mongodb-exporter-prometheus-mongodb-exporter 9216:9216 &

# Wait for port forwarding to start
sleep 5

# Fix Minikube-specific Prometheus targets
echo "Fixing Minikube Prometheus targets..."
# Disable problematic ServiceMonitors that don't work in Minikube
kubectl patch servicemonitor prometheus-kube-prometheus-kube-controller-manager --type='json' -p='[{"op": "replace", "path": "/spec/endpoints", "value": []}]' 2>/dev/null || echo "Controller manager monitor not found"
kubectl patch servicemonitor prometheus-kube-prometheus-kube-scheduler --type='json' -p='[{"op": "replace", "path": "/spec/endpoints", "value": []}]' 2>/dev/null || echo "Scheduler monitor not found"
kubectl patch servicemonitor prometheus-kube-prometheus-kube-etcd --type='json' -p='[{"op": "replace", "path": "/spec/endpoints", "value": []}]' 2>/dev/null || echo "ETCD monitor not found"

# Wait for Prometheus to reload configuration
echo "Waiting for Prometheus to reload configuration..."
sleep 30

# Verify Prometheus targets are up
echo "Verifying Prometheus targets..."
sleep 15
kubectl get pods | grep -E "(prometheus|grafana|mongodb)" || echo "Some pods may still be starting..."

echo ""
echo "🎉 Setup complete!"
echo ""
echo "=== SECURE ACCESS VIA SSH TUNNELING ==="
echo "From your local machine, run this SSH command:"
echo ""
echo "ssh -L 3000:localhost:3000 -L 9090:localhost:9090 -L 9093:localhost:9093 -L 9216:localhost:9216 $USER@$(curl -4 -s ifconfig.me 2>/dev/null || echo 'YOUR_VM_IP')"
echo ""
echo "Then access your dashboards locally:"
echo "✅ Grafana: http://localhost:3000"
echo "✅ Prometheus: http://localhost:9090"
echo "✅ Alertmanager: http://localhost:9093"
echo "✅ MongoDB Exporter: http://localhost:9216"
echo ""
echo "Default Grafana credentials: admin / prom-operator"
echo ""
