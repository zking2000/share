# Grafana Stack on GKE with GCS Backend

这个项目在Google Kubernetes Engine (GKE)上部署完整的Grafana可观测性堆栈，包括：

- **Loki** - 日志聚合系统
- **Tempo** - 分布式追踪系统
- **Mimir** - 指标存储系统
- **Grafana** - 可视化界面

所有数据都存储在Google Cloud Storage (GCS)中，实现持久化和高可用性。

## 前置条件

1. **GKE集群**: 确保您有一个运行中的GKE集群
2. **kubectl**: 配置好kubectl以连接到您的GKE集群
3. **GCS存储桶**: 创建一个GCS存储桶用于数据存储
4. **服务账户**: 创建一个具有GCS访问权限的服务账户

### 创建GCS存储桶

```bash
# 替换为您的项目ID和存储桶名称
export PROJECT_ID="your-gcp-project-id"
export GCS_BUCKET_NAME="your-grafana-stack-bucket"

# 创建存储桶
gsutil mb gs://$GCS_BUCKET_NAME
```

### 创建服务账户

```bash
# 创建服务账户
gcloud iam service-accounts create grafana-stack \
    --display-name="Grafana Stack Service Account"

# 授予存储桶访问权限
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:grafana-stack@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/storage.admin"

# 创建密钥文件
gcloud iam service-accounts keys create grafana-stack-key.json \
    --iam-account=grafana-stack@$PROJECT_ID.iam.gserviceaccount.com
```

### 配置Workload Identity (推荐)

如果您的GKE集群启用了Workload Identity：

```bash
# 绑定Kubernetes服务账户到GCP服务账户
gcloud iam service-accounts add-iam-policy-binding \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:$PROJECT_ID.svc.id.goog[grafana-stack/grafana-stack-sa]" \
    grafana-stack@$PROJECT_ID.iam.gserviceaccount.com

# 注释Kubernetes服务账户
kubectl annotate serviceaccount grafana-stack-sa \
    --namespace grafana-stack \
    iam.gke.io/gcp-service-account=grafana-stack@$PROJECT_ID.iam.gserviceaccount.com
```

## 部署步骤

### 1. 设置环境变量

```bash
export PROJECT_ID="your-gcp-project-id"
export GCS_BUCKET_NAME="your-grafana-stack-bucket"
export SERVICE_ACCOUNT_KEY_PATH="/path/to/grafana-stack-key.json"
```

### 2. 运行部署脚本

```bash
chmod +x deploy.sh
./deploy.sh
```

### 3. 手动部署（可选）

如果您不想使用脚本，可以手动部署：

```bash
# 1. 创建命名空间
kubectl apply -f namespace.yaml

# 2. 创建GCS凭据
kubectl create secret generic gcs-credentials \
    --from-file=service-account-key.json="$SERVICE_ACCOUNT_KEY_PATH" \
    --namespace=grafana-stack

# 3. 更新并应用配置
# 编辑 gcs-secret.yaml 文件，替换存储桶名称和项目ID
kubectl apply -f gcs-secret.yaml

# 4. 创建服务账户
kubectl apply -f service-account.yaml

# 5. 部署配置
kubectl apply -f loki-config.yaml
kubectl apply -f tempo-config.yaml
kubectl apply -f mimir-config.yaml
kubectl apply -f grafana-config.yaml

# 6. 部署应用
kubectl apply -f loki-deployment.yaml
kubectl apply -f tempo-deployment.yaml
kubectl apply -f mimir-deployment.yaml
kubectl apply -f grafana-deployment.yaml
```

## 访问服务

### Grafana界面

```bash
# 获取Grafana外部IP
kubectl get svc grafana -n grafana-stack

# 或者使用端口转发
kubectl port-forward svc/grafana 3000:3000 -n grafana-stack
```

默认登录凭据：
- 用户名: `admin`
- 密码: `admin123`

### 服务端点

- **Grafana**: http://localhost:3000
- **Loki**: http://loki:3100 (集群内部)
- **Tempo**: http://tempo:3200 (集群内部)
- **Mimir**: http://mimir:8080 (集群内部)

## 数据源配置

Grafana已预配置以下数据源：

1. **Loki** - 日志查询
2. **Tempo** - 分布式追踪
3. **Mimir** - 指标查询 (默认数据源)

数据源之间已配置关联：
- 从追踪跳转到日志
- 从追踪跳转到指标
- Exemplars支持

## 监控和故障排除

### 查看Pod状态

```bash
kubectl get pods -n grafana-stack
```

### 查看日志

```bash
# Grafana日志
kubectl logs -f deployment/grafana -n grafana-stack

# Loki日志
kubectl logs -f deployment/loki -n grafana-stack

# Tempo日志
kubectl logs -f deployment/tempo -n grafana-stack

# Mimir日志
kubectl logs -f deployment/mimir -n grafana-stack
```

### 检查服务

```bash
kubectl get svc -n grafana-stack
```

### 检查配置

```bash
kubectl get configmap -n grafana-stack
kubectl get secret -n grafana-stack
```

## 配置说明

### 存储配置

所有组件都配置为使用GCS作为后端存储：

- **Loki**: 日志数据存储在 `gs://your-bucket/loki/`
- **Tempo**: 追踪数据存储在 `gs://your-bucket/tempo/`
- **Mimir**: 指标数据存储在 `gs://your-bucket/mimir-*/`

### 资源限制

默认资源配置：

- **Grafana**: 100m CPU, 128Mi内存
- **Loki**: 100m CPU, 256Mi内存
- **Tempo**: 100m CPU, 256Mi内存
- **Mimir**: 200m CPU, 512Mi内存

### 安全配置

- 多租户模式已禁用（适合单一组织使用）
- 使用Kubernetes服务账户进行GCS访问
- 支持Workload Identity

## 生产环境建议

1. **高可用性**: 增加副本数量
2. **持久存储**: 为本地缓存使用PersistentVolume
3. **监控**: 添加Prometheus监控
4. **备份**: 配置GCS存储桶的备份策略
5. **安全**: 启用TLS和身份验证
6. **资源**: 根据负载调整资源限制

## 清理

```bash
# 删除所有资源
kubectl delete namespace grafana-stack

# 删除GCS存储桶（可选）
gsutil rm -r gs://$GCS_BUCKET_NAME

# 删除服务账户（可选）
gcloud iam service-accounts delete grafana-stack@$PROJECT_ID.iam.gserviceaccount.com
```

## 故障排除

### 常见问题

1. **Pod无法启动**: 检查GCS凭据和权限
2. **存储错误**: 验证GCS存储桶存在且可访问
3. **内存不足**: 增加资源限制
4. **网络连接问题**: 检查服务间的网络连接

### 有用的命令

```bash
# 描述Pod详情
kubectl describe pod <pod-name> -n grafana-stack

# 进入Pod调试
kubectl exec -it <pod-name> -n grafana-stack -- /bin/sh

# 检查网络连接
kubectl exec -it <pod-name> -n grafana-stack -- nslookup loki
``` 