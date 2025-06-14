#!/bin/bash

# Grafana Stack 部署脚本
# 使用GCS作为后端存储

set -e

echo "🚀 开始部署 Grafana Stack 到 GKE..."

# 检查必要的环境变量
if [ -z "$PROJECT_ID" ]; then
    echo "❌ 请设置 PROJECT_ID 环境变量"
    echo "   export PROJECT_ID=your-gcp-project-id"
    exit 1
fi

if [ -z "$GCS_BUCKET_NAME" ]; then
    echo "❌ 请设置 GCS_BUCKET_NAME 环境变量"
    echo "   export GCS_BUCKET_NAME=your-gcs-bucket-name"
    exit 1
fi

if [ -z "$SERVICE_ACCOUNT_KEY_PATH" ]; then
    echo "❌ 请设置 SERVICE_ACCOUNT_KEY_PATH 环境变量"
    echo "   export SERVICE_ACCOUNT_KEY_PATH=/path/to/your/service-account-key.json"
    exit 1
fi

# 检查服务账户密钥文件是否存在
if [ ! -f "$SERVICE_ACCOUNT_KEY_PATH" ]; then
    echo "❌ 服务账户密钥文件不存在: $SERVICE_ACCOUNT_KEY_PATH"
    exit 1
fi

echo "✅ 环境变量检查通过"

# 创建命名空间
echo "📦 创建命名空间..."
kubectl apply -f namespace.yaml

# 创建GCS凭据Secret
echo "🔐 创建GCS凭据..."
kubectl create secret generic gcs-credentials \
    --from-file=service-account-key.json="$SERVICE_ACCOUNT_KEY_PATH" \
    --namespace=grafana-stack \
    --dry-run=client -o yaml | kubectl apply -f -

# 更新GCS配置
echo "⚙️  更新GCS配置..."
sed "s/your-gcs-bucket-name/$GCS_BUCKET_NAME/g; s/your-gcp-project-id/$PROJECT_ID/g" gcs-secret.yaml | kubectl apply -f -

# 更新服务账户配置
echo "👤 创建服务账户..."
sed "s/\${PROJECT_ID}/$PROJECT_ID/g" service-account.yaml | kubectl apply -f -

# Consul不再需要，Mimir使用内存存储进行服务发现

# 部署配置文件
echo "📋 部署配置文件..."
kubectl apply -f prometheus-config.yaml
kubectl apply -f loki-config.yaml
kubectl apply -f tempo-config.yaml
kubectl apply -f mimir-config.yaml
kubectl apply -f grafana-config.yaml

# 部署应用
echo "🚀 部署应用..."
kubectl apply -f prometheus-deployment.yaml
kubectl apply -f loki-deployment.yaml
kubectl apply -f tempo-deployment.yaml
kubectl apply -f mimir-deployment.yaml
kubectl apply -f grafana-deployment.yaml

# 等待所有部署就绪
echo "⏳ 等待所有服务就绪..."
kubectl wait --for=condition=available --timeout=600s deployment/prometheus -n grafana-stack
kubectl wait --for=condition=available --timeout=600s deployment/loki -n grafana-stack
kubectl wait --for=condition=available --timeout=600s deployment/tempo -n grafana-stack
kubectl wait --for=condition=available --timeout=600s deployment/mimir -n grafana-stack
kubectl wait --for=condition=available --timeout=600s deployment/grafana -n grafana-stack

echo "✅ 部署完成！"
echo ""
echo "📊 访问信息:"
echo "   Grafana: http://localhost:3000 (admin/admin123)"
echo "   Prometheus: http://localhost:9090"
echo ""
echo "🔧 获取外部IP:"
echo "   kubectl get svc grafana -n grafana-stack"
echo "   kubectl get svc prometheus-lb -n grafana-stack"
echo ""
echo "📝 查看Pod状态:"
echo "   kubectl get pods -n grafana-stack"
echo ""
echo "🔍 查看日志:"
echo "   kubectl logs -f deployment/prometheus -n grafana-stack"
echo "   kubectl logs -f deployment/grafana -n grafana-stack"
echo "   kubectl logs -f deployment/loki -n grafana-stack"
echo "   kubectl logs -f deployment/tempo -n grafana-stack"
echo "   kubectl logs -f deployment/mimir -n grafana-stack"
echo ""
echo "🧪 验证架构:"
echo "   ./verify-prometheus-mimir.sh" 