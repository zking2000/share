# 🛡️ Internal Application LB + Cloud Armor 部署与回滚文档

> 📋 本文档详细描述了内部应用负载均衡器与 Cloud Armor 的完整部署流程和回滚策略

---

## 🚀 部署过程

### 📝 1. 前置准备

#### 创建 proxy-only 子网
> ⚠️ **注意**: 此步骤只需执行一次

```bash
# 创建 proxy-only 子网（只需一次）
gcloud compute networks subnets create proxy-only-subnet \
  --purpose=INTERNAL_HTTPS_LOAD_BALANCER \
  --role=ACTIVE \
  --region=<REGION> \
  --network=<VPC_NAME> \
  --range=10.200.0.0/24
```

#### 创建健康检查
```bash
# 创建健康检查
gcloud compute health-checks create http hc-sli \
  --port=80 \
  --request-path=/healthz \
  --region=<REGION>
```

---

### 🔧 2. 创建 Backend Service 并添加后端

```bash
# 创建 Backend Service
gcloud compute backend-services create be-sli \
  --protocol=HTTP \
  --health-checks=hc-sli \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --region=<REGION>

# 添加后端实例组
gcloud compute backend-services add-backend be-sli \
  --instance-group=<SLI_MIG_NAME> \
  --instance-group-zone=<ZONE> \
  --region=<REGION>
```

---

### 🌐 3. 创建 URL Map / Proxy / Forwarding Rule

```bash
# 创建 URL Map
gcloud compute url-maps create ilb-sli-map \
  --default-service=be-sli \
  --region=<REGION>

# 创建 Target HTTP Proxy
gcloud compute target-http-proxies create ilb-sli-proxy \
  --url-map=ilb-sli-map \
  --region=<REGION>

# 创建 Forwarding Rule
gcloud compute forwarding-rules create fr-ilb-sli \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --address=<INTERNAL_IP 或自动分配> \
  --ports=80 \
  --network=<VPC_NAME> \
  --subnet=<SUBNET_NAME> \
  --target-http-proxy=ilb-sli-proxy \
  --region=<REGION>
```

---

### 🛡️ 4. 创建并绑定 Cloud Armor 策略

```bash
# 创建安全策略
gcloud compute security-policies create armor-sli \
  --type=BACKEND_SECURITY_POLICY \
  --description="WAF for internal ILB (SLI backend)"

# 添加 WAF 规则（先用 preview 模式观察）
gcloud compute security-policies rules create 1000 \
  --security-policy=armor-sli \
  --expression="evaluatePreconfiguredWaf('xss-v33-stable')" \
  --action=deny-403 \
  --preview

# 绑定策略到 Backend Service
gcloud compute backend-services update be-sli \
  --security-policy=armor-sli \
  --region=<REGION>
```

---

### 🔄 5. iirp Nginx 灰度切流

#### Nginx 配置
```nginx
upstream fe_pool {
    server sli.internal.svc:80 weight=100;   # 旧链路
    server 10.10.20.30:80 weight=0;          # 新链路 (ILB VIP)
}

server {
    listen 80;
    server_name frontend.internal.example;

    location / {
        proxy_pass http://fe_pool;
    }
}
```

#### 🎯 灰度步骤
1. **初始状态**: `weight=0`（全部走旧链路）
2. **渐进切换**: 按 `5% → 30% → 50% → 100%` 提升新链路权重
3. **最终确认**: 确认无误后，将 Cloud Armor 规则从 `preview` 改为 `deny`

---

## 🔙 回滚过程

### ⚡ 1. 流量回滚（最快）

> 🚨 **紧急回滚**: 优先选择此方式快速恢复业务

```nginx
upstream fe_pool {
    server sli.internal.svc:80 weight=100;   # 全部回旧链路
    server 10.10.20.30:80 weight=0;          # 关闭新链路
}
```

**执行命令**:
```bash
nginx -s reload
```

---

### 🛡️ 2. 策略回滚（仅关闭 Cloud Armor）

```bash
# 方法一：将规则改为 preview 模式
gcloud compute security-policies rules update 1000 \
  --security-policy=armor-sli \
  --preview

# 方法二：解绑策略
gcloud compute backend-services update be-sli \
  --security-policy= \
  --region=<REGION>
```

---

### 🔧 3. 结构回滚（移除 ILB）

```bash
# 删除转发规则
gcloud compute forwarding-rules delete fr-ilb-sli --region=<REGION>

# 删除代理
gcloud compute target-http-proxies delete ilb-sli-proxy --region=<REGION>

# 删除 URL Map
gcloud compute url-maps delete ilb-sli-map --region=<REGION>
```

---

### 🗑️ 4. 资源清理（彻底退回旧架构）

> ⚠️ **警告**: 仅在确认不再使用新链路后执行

```bash
# 删除 Backend Service
gcloud compute backend-services delete be-sli --region=<REGION>

# 删除健康检查
gcloud compute health-checks delete hc-sli --region=<REGION>

# 删除安全策略
gcloud compute security-policies delete armor-sli

# 删除 proxy-only 子网
gcloud compute networks subnets delete proxy-only-subnet --region=<REGION>
```

---

## 📋 使用原则

| 回滚类型 | 适用场景 | 执行速度 | 影响范围 |
|---------|----------|----------|----------|
| 🚨 **流量回滚** | 最快恢复业务（改 iirp 权重） | ⚡ 极快 | 最小 |
| 🛡️ **策略回滚** | Cloud Armor 误杀问题 | 🔄 较快 | 中等 |
| 🔧 **结构回滚** | ILB 自身故障 | ⏳ 中等 | 较大 |
| 🗑️ **资源清理** | 彻底退回旧架构 | ⏰ 较慢 | 最大 |

---

> 💡 **最佳实践**: 优先使用流量回滚方式，这是恢复业务最快的方法。只有在确定问题根源后，才考虑更深层次的回滚操作。