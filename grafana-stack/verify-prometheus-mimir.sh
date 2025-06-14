#!/bin/bash

echo "=== Prometheus + Mimir 架构验证 ==="
echo ""

# 检查所有Pod状态
echo "1. 检查Pod状态:"
kubectl get pods -n grafana-stack

echo ""
echo "2. 检查服务状态:"
kubectl get services -n grafana-stack

echo ""
echo "3. 检查Prometheus配置中的remote write:"
kubectl get configmap -n grafana-stack prometheus-config -o yaml | grep -A 5 "remote_write"

echo ""
echo "4. 验证Prometheus可访问性:"
PROMETHEUS_IP=$(kubectl get service -n grafana-stack prometheus-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ ! -z "$PROMETHEUS_IP" ]; then
    echo "Prometheus Web UI: http://$PROMETHEUS_IP:9090"
    echo "测试连接..."
    curl -s -o /dev/null -w "%{http_code}" http://$PROMETHEUS_IP:9090 || echo "连接失败"
else
    echo "Prometheus LoadBalancer IP未分配"
fi

echo ""
echo "5. 验证Grafana数据源配置:"
kubectl get configmap -n grafana-stack grafana-config -o yaml | grep -A 10 "Prometheus"

echo ""
echo "6. 检查Prometheus remote write状态:"
echo "最近的Prometheus日志 (remote write相关):"
kubectl logs -n grafana-stack deployment/prometheus --tail=10 | grep -i "remote\|mimir" || echo "无remote write相关日志"

echo ""
echo "7. 检查Mimir接收状态:"
echo "最近的Mimir日志:"
kubectl logs -n grafana-stack deployment/mimir --tail=5

echo ""
echo "8. 验证服务端点:"
echo "测试Prometheus内部连接:"
kubectl exec -n grafana-stack deployment/prometheus -- wget -qO- http://localhost:9090/-/healthy || echo "Prometheus健康检查失败"

echo "测试Mimir内部连接:"
kubectl exec -n grafana-stack deployment/mimir -- wget -qO- http://localhost:8080/ready || echo "Mimir就绪检查失败"

echo ""
echo "=== 架构总结 ==="
echo "- Prometheus: 负责服务发现和指标收集"
echo "- Mimir: 负责长期存储和查询"
echo "- Grafana: 同时配置了Prometheus(默认)和Mimir数据源"
echo ""

# 获取外部访问信息
GRAFANA_IP=$(kubectl get service -n grafana-stack grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ ! -z "$GRAFANA_IP" ]; then
    echo "Grafana访问地址: http://$GRAFANA_IP:3000"
    echo "默认登录: admin/admin123"
fi

if [ ! -z "$PROMETHEUS_IP" ]; then
    echo "Prometheus访问地址: http://$PROMETHEUS_IP:9090"
fi 