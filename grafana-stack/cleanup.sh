#!/bin/bash

# Grafana Stack 清理脚本

set -e

echo "🧹 开始清理 Grafana Stack 资源..."

# 确认删除
read -p "确定要删除所有 Grafana Stack 资源吗？(y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "取消清理操作"
    exit 0
fi

# 删除部署
echo "🗑️  删除部署..."
kubectl delete deployment grafana loki tempo mimir -n grafana-stack --ignore-not-found=true

# 删除服务
echo "🌐 删除服务..."
kubectl delete svc grafana loki tempo mimir -n grafana-stack --ignore-not-found=true

# 删除配置
echo "⚙️  删除配置..."
kubectl delete configmap grafana-config loki-config tempo-config mimir-config gcs-config -n grafana-stack --ignore-not-found=true

# 删除密钥
echo "🔐 删除密钥..."
kubectl delete secret gcs-credentials -n grafana-stack --ignore-not-found=true

# 删除服务账户和RBAC
echo "👤 删除服务账户和RBAC..."
kubectl delete serviceaccount grafana-stack-sa -n grafana-stack --ignore-not-found=true
kubectl delete clusterrolebinding grafana-stack-binding --ignore-not-found=true
kubectl delete clusterrole grafana-stack-role --ignore-not-found=true

# 删除命名空间
echo "📦 删除命名空间..."
kubectl delete namespace grafana-stack --ignore-not-found=true

echo "✅ 清理完成！"
echo ""
echo "💡 如果您还想删除GCS存储桶和服务账户，请手动执行："
echo "   gsutil rm -r gs://\$GCS_BUCKET_NAME"
echo "   gcloud iam service-accounts delete grafana-stack@\$PROJECT_ID.iam.gserviceaccount.com" 
