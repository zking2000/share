下面给你一套**定位“是谁把日志打爆了”**的实操方案，分三层做：
A. 先止血 → B. 入口侧计量（OTel 自身指标） → C. 后端侧核对 → D. 离线/节点侧取证。
兼顾你常用的 OTel Collector + Loki/ELK/GCP Logging 场景。所有示例都可直接用/改。

⸻

A. 先止血（立即生效的临时降噪）
	1.	快速缩小采集面（立刻上线，防继续膨胀）

	•	在 filelog 上加排除：

receivers:
  filelog:
    include: [/var/log/containers/*.log]
    exclude:
      - /var/log/containers/*_kube-system_*.log
      - /var/log/containers/*fluentd*.log
      - /var/log/containers/*fluent-bit*.log
      - /var/log/containers/*opentelemetry-collector*.log
      - /var/log/containers/*istio-*.log        # 如有
      - /var/log/containers/*event-exporter*.log # 如有

	•	对非关键业务命名空间/Pod 加注解让 GKE 默认代理不采（避免双采）：

metadata:
  annotations:
    logging.googleapis.com/disable: "true"

	2.	禁用 stdout 导出（避免自激回环扩大）
把 exporters.logging 关掉（保留 OTLP/Kafka/Loki 等“单向”出口）。

⸻

B. 入口侧计量：用 OTel 自身指标找“谁在猛写”

OTel Collector 自带 Prometheus 指标（强烈推荐）：
	•	otelcol_receiver_accepted_log_records{receiver="filelog",k8s.namespace.name=...,k8s.pod.name=...}
	•	otelcol_receiver_refused_log_records{...}

若你还没把 K8s 维度贴到资源上，先在 filelog 加解析，把命名空间/Pod从文件名提取为 resource 属性（关键！）。

1) 在 filelog 提取 namespace/pod（从文件路径解析）

receivers:
  filelog:
    include: [/var/log/containers/*.log]
    operators:
      - type: regex_parser
        id: k8s-from-path
        regex: '^(?P<fname>.*/(?P<pod>[^_]+)_(?P<ns>[^_]+)_.+\.log)$'
        parse_from: attributes["log.file.path"]
      - type: move
        from: attributes["ns"]
        to: resource["k8s.namespace.name"]
      - type: move
        from: attributes["pod"]
        to: resource["k8s.pod.name"]

2) 打开 OTel 指标并用 PromQL 分析 TOP N
	•	确保 service.telemetry.metrics.address: ":8888"（或通过 Prometheus 抓取 :8888/metrics）。
	•	典型 PromQL（看每分钟日志条数，按命名空间 TOP 20）：

topk(20, sum by (k8s_namespace_name) (
  rate(otelcol_receiver_accepted_log_records{receiver="filelog"}[5m])
))

	•	继续细分到 Pod：

topk(20, sum by (k8s_namespace_name, k8s_pod_name) (
  rate(otelcol_receiver_accepted_log_records{receiver="filelog"}[5m])
))

这能快速指认“哪个 ns / 哪个 pod”在疯狂产生日志。
想估“字节量”，可结合平均日志行长（见 D 节脚本）做近似：字节 ≈ 行数 × 平均行长。

⸻

C. 后端侧核对（Loki / GCP Logging / Elasticsearch）

1) Loki（LogQL）

不同版本对字节函数支持不同；稳妥做法是先用行数定位罪魁，再做抽样估算平均行长。

	•	按命名空间统计行数（一小时窗口）：

sum by (namespace) (count_over_time({cluster="your-cluster"}[1h]))

	•	找 TOP Pod：

topk(20, sum by (namespace, pod) (count_over_time({cluster="your-cluster"}[1h])))

	•	抽样估算平均行长（示意）：
取某 Pod 最近 5 分钟的 N 条日志，导出样本算 avg(len(line))。

Loki 2.9+ 才有更完善的字节函数（如果可用：bytes_over_time），但为兼容性我提供行数法。

2) GCP Cloud Logging（Log Analytics / BigQuery）

如果你开启了 Log Analytics（BQ 语法） 或已导出到 BigQuery，直接跑 SQL（近24小时）：

SELECT
  resource.labels.namespace_name AS ns,
  resource.labels.pod_name AS pod,
  COUNT(1) AS rows,
  SUM(LENGTH(COALESCE(textPayload, jsonPayload, protoPayload))) AS approx_bytes
FROM
  `projects/<PROJECT_ID>/locations/global/buckets/_Default/links/<LINK_ID>/datasets/<DATASET>.logs_*`
WHERE
  timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
GROUP BY ns, pod
ORDER BY approx_bytes DESC
LIMIT 50;

说明：不同环境下表路径有所不同；如果是日志路由到 BQ，就对相应表执行同样聚合。

3) Elasticsearch / OpenSearch
	•	如果日志进了 ES，直接按 kubernetes.namespace_name, kubernetes.pod_name 做 terms 聚合 + value_count。
	•	若需要“字节近似”，可在 可视化层用 scripted field 估 doc_length（不精确），或通过 ingest pipeline 把 message.length 写入一个数值字段（用于后续分析）。

⸻

D. 离线/节点侧取证（无后端维度时的兜底手段）

有时你后端没带 namespace/pod 维度，或你想快速确定“哪些文件最大/增长最快”。
下述脚本以 DaemonSet Job 的方式在每个节点统计 /var/log/containers 下按命名空间汇总大小并给出 Top N。

1) 一次性排查脚本（可在节点上或以 DS 跑）

# 在一个节点上运行（需要宿主权限），或封装到 DaemonSet 容器里挂 /var/log
find /var/log/containers -type f -printf '%s %f\n' \
| awk '
  {
    # 文件名形如：<pod>_<namespace>_<container>-<container_id>.log
    # 示例：api-55fcd_foo_ns_api-1234567890abcdef.log
    split($2, a, "_"); ns=a[2]; bytes=$1;
    by_ns[ns]+=bytes;
    by_file[$2]+=bytes;
  }
  END {
    print "=== Top 20 namespaces by bytes ===";
    for (n in by_ns) printf("%-40s %15d\n", n, by_ns[n]) | "sort -k2 -nr | head -20";
    close("sort -k2 -nr | head -20");

    print "\n=== Top 20 files by bytes ===";
    for (f in by_file) printf("%-80s %15d\n", f, by_file[f]) | "sort -k2 -nr | head -20";
    close("sort -k2 -nr | head -20");
  }'

2) 估算平均行长（配合 B 节行数作“字节量”近似）

# 取某可疑文件做抽样
F=/var/log/containers/<pod>_<ns>_<container>-<id>.log
# 抽样 10k 行（跳读提升速度）
awk 'NR%100==0{c++; bytes+=length($0)} END{ if(c>0) print bytes/c; else print 0 }' "$F"

用 近似字节 = 行数 × 平均行长，即可估算每 ns/pod 的字节占用。

⸻

E. 找到“罪魁”后的治理手段（根因与永久修复）
	1.	噪声模式（最常见 Root Cause）

	•	健康检查/探针频繁打印；
	•	请求/响应全文落日志（尤其 JSON 大 payload）；
	•	Debug 日志级别开启；
	•	Retry/异常雪崩导致同样的报错刷屏；
	•	多行堆栈未聚合，造成“行数 ×10”。

	2.	Collector 侧治理（推荐配置）

receivers:
  filelog:
    include: [/var/log/containers/*.log]
    # 1) 严格排除（系统/代理/自身）
    exclude:
      - /var/log/containers/*_kube-system_*.log
      - /var/log/containers/*fluent*.log
      - /var/log/containers/*opentelemetry-collector*.log
    operators:
      # 2) 多行合并（Java/Go 堆栈）
      - type: recombine
        first_line_pattern: '^\d{4}-\d{2}-\d{2}[ T]'
      # 3) 过滤健康检查与特定噪声
      - type: filter
        expr: 'IsMatch(body, "(GET /healthz|/metrics|/readyz)")'
        drop: true
      # 4) 解析 ns/pod（前面给过）
      - type: regex_parser
        regex: '^(?P<fname>.*/(?P<pod>[^_]+)_(?P<ns>[^_]+)_.+\.log)$'
        parse_from: attributes["log.file.path"]
      - type: move
        from: attributes["ns"]
        to: resource["k8s.namespace.name"]

processors:
  # 5) 采样（对 info 级应用/超高频服务）
  probabilistic_sampler:
    hash_seed: 1
    sampling_percentage: 10
    # 可配 tail_sampling（按属性）用于 trace；日志侧用 probabilistic 即可
  # 6) 资源标注，便于后端聚合
  resource:
    attributes:
      - key: pipeline.source
        value: otel-filelog
        action: upsert
  # 7) 内存保护
  memory_limiter:
    check_interval: 2s
    limit_mib: 1024
    spike_limit_mib: 256
  batch: {}

service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [memory_limiter, resource, probabilistic_sampler, batch]
      exporters: [otlphttp]   # 或 kafka / loki

	3.	应用侧治理

	•	调整日志级别（从 DEBUG→INFO/WARN）。
	•	关闭打印大 payload（或只打印摘要/traceId）。
	•	健康检查/metrics 自身不落应用日志。
	•	多行堆栈用结构化日志（一次一条事件）。

⸻

F. 一个“从检测到修复”的流程图

flowchart TD
  A[OTel 自身指标: rate(accepted_log_records)] --> B{Top N ns/pod}
  B -->|锁定可疑工作负载| C[Loki/Logging 二次核对]
  C --> D{确定模式: Debug/Probe/大Payload/异常风暴}
  D -->|Collector 侧| E[排除/合并/采样/过滤]
  D -->|应用侧| F[降级别/删大payload/修重试/修探针]
  E --> G[观察指标与存储曲线]
  F --> G


⸻

结论
	•	最快的办法：用 OTel 的 accepted_log_records 指标先锁定“谁在刷日志”，再到后端核对。
	•	兜底：在节点上按 文件名→命名空间聚合体量，找 TOP N。
	•	根因通常是：Debug/探针/异常雪崩/多行未合并。
	•	永久方案：收紧 filelog、加多行与过滤、低价值日志做采样，应用侧降噪。

如果你告诉我后端是 Loki / GCP Logging / ES 的哪一种，我可以把上面的查询语句和仪表板变量替换成完全贴你的环境的成品（Grafana 面板 JSON / BQ SQL / Kibana Lens）。
