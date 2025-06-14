#!/bin/bash

# Grafana Stack 验证脚本

set -e

echo "🔍 验证 Grafana Stack 部署状态..."

# 检查命名空间
echo "📦 检查命名空间..."
if kubectl get namespace grafana-stack &> /dev/null; then
    echo "✅ 命名空间 grafana-stack 存在"
else
    echo "❌ 命名空间 grafana-stack 不存在"
    exit 1
fi

# 检查Pod状态
echo "🚀 检查Pod状态..."
kubectl get pods -n grafana-stack

echo ""
echo "⏳ 等待所有Pod就绪..."
kubectl wait --for=condition=ready --timeout=300s pod -l app=grafana -n grafana-stack
kubectl wait --for=condition=ready --timeout=300s pod -l app=loki -n grafana-stack
kubectl wait --for=condition=ready --timeout=300s pod -l app=tempo -n grafana-stack
kubectl wait --for=condition=ready --timeout=300s pod -l app=mimir -n grafana-stack

echo "✅ 所有Pod已就绪"

# 检查服务
echo ""
echo "🌐 检查服务..."
kubectl get svc -n grafana-stack

# 检查配置
echo ""
echo "⚙️  检查配置..."
kubectl get configmap -n grafana-stack
kubectl get secret -n grafana-stack

# 测试服务连接
echo ""
echo "🔗 测试服务连接..."

# 测试Grafana
echo "测试Grafana连接..."
kubectl port-forward svc/grafana 3000:3000 -n grafana-stack &
PF_PID=$!
sleep 5

if curl -s http://localhost:3000/api/health > /dev/null; then
    echo "✅ Grafana 连接正常"
else
    echo "❌ Grafana 连接失败"
fi

kill $PF_PID 2>/dev/null || true

# 显示访问信息
echo ""
echo "📊 访问信息:"
echo "   获取Grafana外部IP: kubectl get svc grafana -n grafana-stack"
echo "   端口转发: kubectl port-forward svc/grafana 3000:3000 -n grafana-stack"
echo "   默认登录: admin/admin123"
echo ""
echo "🎉 验证完成！" 