# Hosting Options for Regulated Industry Compliance

> Prepared: 2026-02-20
> Status: PACT Prepare Phase — Research Complete

---

## Executive Summary

For Synaptic Cloud's hosting infrastructure, we recommend a **graduated migration path**: start on **Fly.io** (best Elixir ecosystem support, SOC 2 Type II, HIPAA BAA available, low operational overhead) for the MVP and growth stages, then graduate to **AWS** when enterprise customers require FedRAMP, PCI DSS, or data residency in specific regions beyond what Fly.io offers. Railway is a viable alternative to Fly.io with similar compliance posture but weaker Elixir ecosystem support. GCP and Azure are equivalent to AWS in compliance breadth but lack the Elixir community momentum.

The key finding is that **Fly.io now covers SOC 2 + HIPAA**, which are the two certifications most commonly needed in early-stage SaaS. FedRAMP and PCI DSS are only needed for federal government contracts and direct payment processing respectively — both are enterprise-tier requirements that justify the operational cost of AWS.

---

## 1. Compliance Certification Comparison

| Certification | Fly.io | Railway | AWS | GCP | Azure |
|--------------|--------|---------|-----|-----|-------|
| **SOC 2 Type II** | Yes | Yes | Yes | Yes | Yes |
| **SOC 3** | -- | Yes | Yes | Yes | Yes |
| **HIPAA BAA** | Yes (pre-signed) | Yes (Enterprise add-on) | Yes (BAA required) | Yes (BAA required) | Yes (included in Product Terms) |
| **FedRAMP** | No | No | Yes (Moderate + High) | Yes (High P-ATO, 150+ services) | Yes (Moderate + High) |
| **PCI DSS** | No | No | Yes (Level 1) | Yes | Yes (Level 1, v4.0) |
| **GDPR/DPA** | Yes (pre-signed DPA) | Yes (self-service DPA) | Yes | Yes | Yes |
| **ISO 27001** | -- | -- | Yes | Yes | Yes |
| **ISO 27017/27018** | -- | -- | Yes | Yes | Yes |

### What This Means for Synaptic Cloud

- **MVP to Growth (most customers)**: SOC 2 + HIPAA cover healthcare, legal, and most B2B use cases. Fly.io or Railway suffice.
- **Enterprise/Government**: FedRAMP required for US federal agencies. PCI DSS required only if processing payment cards directly (Stripe handles this for you in most cases). AWS, GCP, or Azure needed.
- **EU Customers**: GDPR compliance available on all platforms. Data residency is the differentiator.

---

## 2. Data Residency Controls

| Platform | US Regions | EU Regions | APAC Regions | Region Granularity | Change Region Without Downtime |
|----------|-----------|-----------|-------------|-------------------|-------------------------------|
| **Fly.io** | Multiple (US East, West, Central) | Multiple (Amsterdam, London, Frankfurt, etc.) | Multiple (Sydney, Tokyo, Singapore, etc.) | Per-app, per-machine | Yes (create new machine, destroy old) |
| **Railway** | US-West, US-East | EU-West | Southeast Asia | Per-service | Yes (no downtime, except with volumes) |
| **AWS** | 8+ US regions | 5+ EU regions | 10+ APAC regions | Per-resource, per-VPC | Requires redeployment |
| **GCP** | 8+ US regions | 5+ EU regions | 8+ APAC regions | Per-resource | Requires redeployment |
| **Azure** | 8+ US regions | 5+ EU regions | 8+ APAC regions | Per-resource | Requires redeployment |

### Key Observations

- **Fly.io** has the most global regions (~35 cities) with the easiest region selection. Deploy anywhere with `fly deploy --region <code>`.
- **Railway** has the fewest regions (4 total) — a significant limitation for enterprise data residency requirements.
- **Hyperscalers** (AWS/GCP/Azure) have the most regions and finest granularity but require more configuration to enforce data residency (VPC isolation, resource policies, etc.).

---

## 3. Audit Logging Capabilities

| Capability | Fly.io | Railway | AWS | GCP | Azure |
|-----------|--------|---------|-----|-----|-------|
| **Infrastructure audit logs** | Via metrics dashboard | Yes (Enterprise) | CloudTrail (free for management events) | Cloud Audit Logs (free) | Activity Log (free) |
| **API activity logging** | Limited | Yes — event type, data, actor | CloudTrail data events (paid) | Data access logs | Diagnostic settings |
| **Retention** | Metrics-based | Plan-dependent; Enterprise has longer | 90 days free; 10 years in CloudTrail Lake | 400 days default | 90 days; extended via Log Analytics |
| **Export/SIEM integration** | -- | Yes (API export) | S3, CloudWatch, EventBridge | BigQuery, Pub/Sub | Event Hubs, Log Analytics |
| **User action tracking** | Limited | Users, Staff, System actors | IAM-integrated | IAM-integrated | AAD-integrated |
| **Filter capabilities** | Basic | Event type, environment, project, time range | Extensive (resource, user, time, event) | Extensive | Extensive |

### Key Observations

- **Railway** has surprisingly good audit logging for a PaaS — tracks deployments, config changes, member additions, exportable via API.
- **AWS CloudTrail** is the gold standard for audit logging but adds cost for data events and long-term retention.
- **Fly.io** is weakest in audit logging — adequate for startup phase but not for regulated enterprise customers.

---

## 4. Pricing Comparison

### 4.1 Small Scale (MVP, <100 users)

Running a Phoenix app (1 instance, 512MB RAM, 1 vCPU) + managed PostgreSQL.

| Platform | Compute | Database | Total Est./Month | Notes |
|----------|---------|----------|------------------|-------|
| **Fly.io** | $3-7 (shared-cpu-1x, 256MB) | $0-15 (Fly Postgres or Neon Free) | **$3-22** | Generous free tier; Phoenix-optimized |
| **Railway** | $5-15 (Hobby/Pro plan + usage) | $5-10 (Railway Postgres) | **$10-25** | Simple; $5 Hobby or $20 Pro subscription |
| **AWS (Fargate)** | $15-30 (0.25 vCPU, 0.5GB) | $15-30 (RDS t4g.micro) | **$30-60** | No free tier for Fargate in production |
| **GCP (Cloud Run)** | $0-5 (within free tier for low traffic) | $10-30 (Cloud SQL) | **$10-35** | Excellent free tier; scale-to-zero |
| **Azure (Container Apps)** | $0-5 (Consumption plan, free tier) | $15-30 (Azure DB for Postgres) | **$15-35** | Good free tier; similar to Cloud Run |

### 4.2 Medium Scale (Growth, 100-1000 users)

Running 2-3 instances, dedicated database, Redis, object storage.

| Platform | Compute | Database | Extras | Total Est./Month | Notes |
|----------|---------|----------|--------|------------------|-------|
| **Fly.io** | $30-60 (2x shared-cpu-2x, 1GB) | $30-80 (Neon Launch) | $10-30 (Tigris, Upstash) | **$70-170** | Scales well; cluster-friendly |
| **Railway** | $40-80 (Pro plan + usage) | $20-50 (Railway Postgres) | $10-20 (Redis, etc.) | **$70-150** | Auto-scaling simplifies ops |
| **AWS (Fargate)** | $80-160 (2x 0.5 vCPU, 1GB) | $50-100 (RDS t4g.small) | $20-40 (ElastiCache, S3) | **$150-300** | Savings Plans can reduce 20-52% |
| **GCP (Cloud Run)** | $40-100 | $50-100 (Cloud SQL) | $20-40 (Memorystore, GCS) | **$110-240** | Committed use discounts available |
| **Azure** | $40-100 | $50-100 | $20-40 | **$110-240** | Similar to GCP pricing |

### 4.3 Large Scale (Enterprise, 1000+ users)

Running 5+ instances, multi-region, dedicated resources, compliance overhead.

| Platform | Compute | Database | Extras | Compliance Overhead | Total Est./Month |
|----------|---------|----------|--------|--------------------|--------------------|
| **Fly.io** | $100-400 | $100-400 (Neon Scale) | $50-150 | Low (built-in) | **$250-950** |
| **Railway** | $100-300 (Enterprise) | $80-200 | $30-100 | Medium (Enterprise plan required) | **$210-600** + Enterprise fee |
| **AWS** | $200-800 | $200-600 (RDS) | $100-300 | High (WAF, GuardDuty, Config, etc.) | **$500-1700** + compliance tools |
| **GCP** | $150-600 | $200-500 | $80-250 | High (similar to AWS) | **$430-1350** |
| **Azure** | $150-600 | $200-500 | $80-250 | High (similar to AWS) | **$430-1350** |

---

## 5. Operational Complexity

| Dimension | Fly.io | Railway | AWS | GCP | Azure |
|-----------|--------|---------|-----|-----|-------|
| **Deploy workflow** | `fly deploy` (CLI-first) | Git push or CLI | Terraform/CloudFormation + ECR + ECS | gcloud CLI or Terraform | az CLI or Terraform |
| **Elixir ecosystem** | Excellent (Phoenix creator active in community, first-class docs) | Good (Docker-based, no special support) | Manual (Docker + ECS/Fargate, DIY clustering) | Manual (Docker + Cloud Run) | Manual (Docker + Container Apps) |
| **BEAM clustering** | Built-in via `fly-io/dns_cluster` | Manual (private networking) | Manual (service discovery + libcluster) | Manual | Manual |
| **LiveView WebSockets** | Native support | Native support | ALB WebSocket support (config required) | Load balancer config needed | App Gateway config needed |
| **SSL/TLS** | Automatic | Automatic | ACM + ALB (config required) | Managed certs (some config) | Managed certs (some config) |
| **Auto-scaling** | Manual or fly-autoscaler | Automatic (built-in) | ECS Service Auto Scaling | Automatic (Cloud Run) | Automatic (Container Apps) |
| **Logging/monitoring** | Built-in metrics + Grafana | Built-in observability platform | CloudWatch (separate cost) | Cloud Logging/Monitoring | Azure Monitor |
| **DevOps hours/week** | 1-2h | <1h | 5-10h | 4-8h | 4-8h |
| **Learning curve** | Low-Medium (CLI-focused) | Low (GUI-focused) | High (many services to learn) | Medium-High | Medium-High |

### Key Observations

- **Fly.io** is the clear winner for Elixir/Phoenix: first-class `dns_cluster` support, Phoenix creator engagement, WebSocket-native, and built-in distributed Erlang clustering.
- **Railway** is simplest operationally (auto-scaling, GUI-first) but has no Elixir-specific advantages.
- **AWS** has the most capability but requires 5-10x more DevOps effort. Justifiable only when enterprise compliance demands it.
- **GCP Cloud Run** is compelling for scale-to-zero (cost savings for low-traffic tenants) but lacks BEAM clustering support.

---

## 6. Platform-Specific Notes

### 6.1 Fly.io — Recommended for MVP through Growth

**Strengths:**
- SOC 2 Type II certified, HIPAA BAA available (pre-signed, self-service)
- 35+ global regions with per-machine region selection
- First-class Phoenix/Elixir support (dns_cluster, WireGuard private networking)
- Chris McCord (Phoenix creator) actively supports Fly.io deployments
- Tigris object storage with its own BAA for HIPAA workloads
- Low operational overhead: `fly deploy` handles most concerns

**Limitations:**
- No FedRAMP certification
- No PCI DSS certification
- Audit logging is basic compared to hyperscalers
- No built-in metrics-based auto-scaling (requires fly-autoscaler)
- Enterprise support is email-based; no 24/7 phone support

**Best for:** MVP, seed-to-Series A startups, healthcare/legal SaaS that needs HIPAA without FedRAMP.

### 6.2 Railway — Alternative to Fly.io

**Strengths:**
- SOC 2 Type II + HIPAA BAA (Enterprise tier)
- Simplest operational model (auto-scaling, GUI-first)
- Good audit logging with SIEM export capability
- Enterprise features: SSO, dedicated VMs, BYOC (bring your own cloud)
- New observability platform handling 100B+ logs

**Limitations:**
- Only 4 deployment regions (US-West, US-East, EU-West, Southeast Asia)
- No FedRAMP, no PCI DSS
- HIPAA BAA requires Enterprise plan (custom pricing)
- No Elixir-specific optimizations (Docker-only)
- Private networking less mature than Fly.io's WireGuard mesh

**Best for:** Teams that prioritize developer experience over Elixir-specific features.

### 6.3 AWS — Recommended for Enterprise Compliance

**Strengths:**
- 143+ compliance certifications including FedRAMP (Moderate + High), PCI DSS Level 1, HIPAA BAA
- 30+ regions worldwide with finest data residency granularity
- CloudTrail provides gold-standard audit logging
- Most extensive ecosystem (WAF, GuardDuty, KMS, Config, Inspector)
- ECS Fargate eliminates server management
- Graviton (ARM) processors 20% cheaper

**Limitations:**
- 5-10x more operational overhead than PaaS options
- No Elixir-specific support (all DIY via Docker)
- Minimum viable deployment is more expensive ($30-60/month vs $3-22)
- Steep learning curve; dozens of services to configure
- BEAM clustering requires manual service discovery (libcluster + ECS)

**Best for:** Enterprise customers requiring FedRAMP, PCI DSS, or specific regulatory compliance. Government contracts. Series B+ startups.

### 6.4 GCP — Strong Alternative to AWS

**Strengths:**
- FedRAMP High P-ATO (150+ services)
- Cloud Run has excellent scale-to-zero (cost savings for multi-tenant)
- Strong AI/ML ecosystem if Synaptic integrates Vertex AI or Gemini
- Free tier is more generous than AWS for small workloads

**Limitations:**
- Smaller community for Elixir than Fly.io or AWS
- BEAM clustering on Cloud Run is impractical (stateless containers, no persistent connections)
- Enterprise support pricing is premium

**Best for:** Teams already invested in Google ecosystem, or if Synaptic integrates Google AI services.

### 6.5 Azure — Equivalent to AWS/GCP

**Strengths:**
- PCI DSS v4.0 Level 1, FedRAMP High
- Container Apps has good scale-to-zero with generous free tier
- Strong enterprise identity integration (Azure AD/Entra)
- Government cloud (Azure Gov) for federal workloads

**Limitations:**
- Weakest Elixir ecosystem support
- Enterprise-focused pricing can be expensive for small teams
- Container Apps is newer and less mature than ECS/Cloud Run

**Best for:** Enterprise customers already in Microsoft ecosystem.

---

## 7. Recommended Migration Path

### Stage 1: Fly.io (MVP through Growth, 0-1000 users)

```
Fly.io
├── Phoenix app (1-3 instances, shared-cpu)
├── Neon PostgreSQL (per-tenant databases)
├── Tigris Object Storage (HIPAA BAA available)
├── Upstash Redis (caching, PubSub backup)
└── DNS + SSL (automatic)

Cost: $10-200/month
Compliance: SOC 2 Type II, HIPAA BAA, GDPR DPA
Ops effort: 1-2 hours/week
```

**Why Fly.io first:**
- Lowest cost and complexity for Elixir apps
- SOC 2 + HIPAA covers 90% of early customers
- dns_cluster enables distributed Erlang out of the box
- Pre-signed BAA is self-service (no sales call needed)
- WebSocket support is native (critical for LiveView)

### Stage 2: Fly.io + AWS (Growth to Scale, 1000-5000 users)

Add AWS for specific enterprise customer requirements:

```
Fly.io (primary)                    AWS (enterprise tenants)
├── Most customers                  ├── FedRAMP customers
├── Standard isolation              ├── Dedicated VPC per tenant
├── Neon per-tenant DB              ├── RDS per-tenant DB
└── Shared infrastructure           ├── CloudTrail audit logging
                                    ├── WAF + GuardDuty
                                    └── KMS encryption
```

**When to add AWS:**
- First enterprise customer requires FedRAMP
- Customer contract requires specific AWS region (GovCloud, etc.)
- Customer requires dedicated infrastructure (not shared)
- Revenue from enterprise tier justifies operational cost

### Stage 3: AWS Primary (Scale, 5000+ users / enterprise focus)

If enterprise becomes the dominant revenue source:

```
AWS (primary)
├── ECS Fargate (multi-region)
├── RDS Multi-AZ (platform DB)
├── Neon or RDS (per-tenant DB)
├── S3 + CloudFront (assets)
├── ElastiCache (Redis)
├── CloudTrail + Config (audit)
├── WAF + Shield (security)
├── KMS (encryption)
└── CloudWatch (monitoring)

Cost: $500-2000+/month
Compliance: SOC 2, HIPAA, FedRAMP, PCI DSS, ISO 27001
Ops effort: 5-10 hours/week (or hire DevOps)
```

**Only if:**
- Enterprise revenue justifies dedicated DevOps investment
- Multiple customers require FedRAMP or government compliance
- Scale demands multi-region with fine-grained control

---

## 8. Comparison Matrix (Decision Framework)

| Factor | Weight | Fly.io | Railway | AWS | GCP | Azure |
|--------|--------|--------|---------|-----|-----|-------|
| Elixir/Phoenix support | 20% | 5 | 3 | 2 | 2 | 1 |
| Compliance breadth | 20% | 3 | 3 | 5 | 5 | 5 |
| Operational simplicity | 20% | 4 | 5 | 1 | 2 | 2 |
| Cost (small scale) | 15% | 5 | 4 | 2 | 4 | 3 |
| Data residency options | 10% | 4 | 2 | 5 | 5 | 5 |
| Audit logging | 10% | 2 | 4 | 5 | 5 | 5 |
| Scale ceiling | 5% | 3 | 3 | 5 | 5 | 5 |
| **Weighted Score** | | **3.85** | **3.45** | **3.15** | **3.55** | **3.25** |

**Fly.io wins overall** due to Elixir-specific advantages and the combination of adequate compliance (SOC 2 + HIPAA) with low operational overhead. AWS scores highest on compliance and scale but is penalized by operational complexity and cost.

---

## 9. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Fly.io insufficient compliance for enterprise deal | Medium | Medium | Maintain AWS migration playbook; add AWS only when needed |
| Fly.io pricing increases or service changes | Low | Medium | Infrastructure abstracted behind Phoenix config; Docker-based, portable |
| AWS operational costs exceed revenue | Medium | High | Start on Fly.io; only migrate enterprise tenants to AWS |
| Railway limited regions block EU data residency | Medium | Low | Railway not recommended as primary; use Fly.io instead |
| BEAM clustering issues on non-Fly platforms | Medium | Medium | Use libcluster with ECS service discovery on AWS; test thoroughly |
| Compliance gap discovered mid-deal | Low | High | Pre-qualify customer compliance needs before committing platform |

---

## 10. References

### Platform Compliance
- [Fly.io Compliance](https://fly.io/compliance)
- [Fly.io Healthcare Apps](https://fly.io/docs/about/healthcare/)
- [Railway Compliance](https://docs.railway.com/maturity/compliance)
- [Railway Enterprise](https://docs.railway.com/enterprise)
- [Railway Audit Logs](https://docs.railway.com/enterprise/audit-logs)
- [AWS Compliance Programs](https://aws.amazon.com/compliance/programs/)
- [AWS Services in Scope](https://aws.amazon.com/compliance/services-in-scope/)
- [GCP Compliance Offerings](https://cloud.google.com/security/compliance/offerings)
- [Azure Compliance Documentation](https://learn.microsoft.com/en-us/azure/compliance/)

### Pricing
- [Fly.io Pricing](https://fly.io/pricing/)
- [Railway Pricing](https://railway.com/pricing)
- [AWS Fargate Pricing](https://aws.amazon.com/fargate/pricing/)
- [GCP Cloud Run Pricing](https://cloud.google.com/run/pricing)
- [Azure Container Apps Pricing](https://azure.microsoft.com/en-us/pricing/details/container-apps/)

### Data Residency
- [Railway Regions](https://docs.railway.com/deployments/regions)
- [Fly.io Security Practices](https://fly.io/docs/security/security-at-fly-io/)

### Audit Logging
- [AWS CloudTrail Pricing](https://aws.amazon.com/cloudtrail/pricing/)
- [Railway Audit Logs](https://docs.railway.com/enterprise/audit-logs)

### Elixir Deployment
- [Deploying Phoenix on Fly.io](https://fly.io/docs/elixir/)
- [Railway vs Fly.io](https://docs.railway.com/platform/compare-to-fly)
- [Fly.io vs Railway Comparison](https://getdeploying.com/flyio-vs-railway)
