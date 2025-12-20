# AWS ECS 部署速查表 🚀

> 快速構建和部署指南 - 適用於已有基礎設施（VPC、Security Groups）的場景

## 📐 架構總覽

```
Internet
    ↓
Application Load Balancer (Public Subnets)
    ↓
ECS Fargate Tasks (Private Subnets)
    ↓
RDS MySQL (Private Subnets)
```

**核心組件**：RDS → IAM Roles → ECR → CloudWatch → ECS Cluster → ALB/TG → Docker Image → Task Def → Service

---

## ⚡ 快速命令

### 設置環境變數（每次使用前執行）

```bash
export REGION="us-west-2"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER="doublespot-cluster"
export SERVICE="backend-service"
export ECR_REPO="doublespot-backend"
```

---

## 🤖 自動化設置（推薦）

使用自動化腳本一鍵創建所有基礎設施：

```bash
# 1. 給腳本添加執行權限
chmod +x scripts/*.sh

# 2. 運行基礎設施設置腳本
./scripts/setup-aws-infrastructure.sh

# 3. 載入生成的配置
source infrastructure-config.env

# 完成！所有資源已自動創建
```

腳本會自動創建：

- ✅ IAM Roles
- ✅ ECR Repository
- ✅ CloudWatch Log Group
- ✅ ECS Cluster
- ✅ Application Load Balancer
- ✅ Target Group
- ✅ RDS MySQL（可選）

---

## 🏗️ 手動設置（或自動化腳本的詳細步驟）

### 1. RDS 數據庫

```bash
# AWS Console 創建
# RDS → Create database → MySQL 8.0 → Free tier
# 記錄 endpoint, username, password
```

### 2. IAM Roles

```bash
# 需要兩個 Roles：
# - ecsTaskExecutionRole (附加 AmazonECSTaskExecutionRolePolicy)
# - ecsTaskRole (暫時無需附加策略)
```

### 3. ECR Repository

```bash
aws ecr create-repository --region $REGION --repository-name $ECR_REPO
```

### 4. CloudWatch Log Group

```bash
aws logs create-log-group --region $REGION --log-group-name /ecs/doublespot-backend
```

### 5. ECS Cluster

```bash
aws ecs create-cluster --region $REGION --cluster-name $CLUSTER
```

### 6. Target Group (在創建 ALB 時一起創建)

```bash
# AWS Console:
# EC2 → Load Balancers → Create ALB
# 配置 Target Group: Type=IP, Port=3000, Health=/health
```

---

## 🐳 構建與部署流程

### 選擇架構（選一個）

| 架構  | 構建命令                                  | Task Def 配置            | 適用場景      |
| ----- | ----------------------------------------- | ------------------------ | ------------- |
| AMD64 | `docker build --platform linux/amd64 ...` | 默認（不需要額外配置）   | 兼容性最好    |
| ARM64 | `docker build -t ...`（M1/M2 Mac 原生）   | 需添加 `runtimePlatform` | 節省 20% 成本 |

### 自動化部署（推薦）

```bash
# 1. 構建並推送映像（使用你選擇的架構）
cd backend
export IMAGE_TAG="v1.0.0"
docker build --platform linux/amd64 -t $ECR_REPO:$IMAGE_TAG .
docker tag $ECR_REPO:$IMAGE_TAG $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG

# 2. 更新 task-definition.json（映像 URI、RDS endpoint 等）

# 3. 註冊 Task Definition
aws ecs register-task-definition --region $REGION --cli-input-json file://task-definition.json

# 4. 使用腳本自動部署 Service
cd ..
./scripts/deploy-ecs-service.sh

# 完成！腳本會自動創建/更新 Service 並監控部署狀態
```

### 手動部署命令

```bash
# 1. 登入 ECR
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin \
  $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# 2. 構建映像（選擇架構）
cd backend
export IMAGE_TAG="v1.0.0"  # 或使用 $(git rev-parse --short HEAD)

# AMD64:
docker build --platform linux/amd64 -t $ECR_REPO:$IMAGE_TAG .

# ARM64 (M1/M2 Mac):
docker build -t $ECR_REPO:$IMAGE_TAG .

# 3. 推送到 ECR
docker tag $ECR_REPO:$IMAGE_TAG \
  $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG

# 4. 更新 task-definition.json
# 編輯文件，更新 image URI, RDS endpoint, 密碼等

# 5. 註冊 Task Definition
aws ecs register-task-definition --region $REGION \
  --cli-input-json file://task-definition.json

# 6. 創建/更新 Service
# 首次創建：
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --region $REGION \
  --names doublespot-backend-tg --query 'TargetGroups[0].TargetGroupArn' --output text)

SUBNET_1=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=tag:Name,Values=doublespot-test-private-us-west-2a" \
  --query 'Subnets[0].SubnetId' --output text)

SUBNET_2=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=tag:Name,Values=doublespot-test-private-us-west-2b" \
  --query 'Subnets[0].SubnetId' --output text)

SG_ID=$(aws ec2 describe-security-groups --region $REGION \
  --filters "Name=group-name,Values=doublespot-test-ecs-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

aws ecs create-service \
  --region $REGION \
  --cluster $CLUSTER \
  --service-name $SERVICE \
  --task-definition doublespot-backend \
  --desired-count 1 \
  --launch-type FARGATE \
  --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$SG_ID],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TARGET_GROUP_ARN,containerName=backend,containerPort=3000" \
  --health-check-grace-period-seconds 60

# 後續更新（已有 Service）：
aws ecs update-service --region $REGION --cluster $CLUSTER \
  --service $SERVICE --force-new-deployment
```

---

## 🔍 監控與診斷

### 檢查服務狀態

```bash
aws ecs describe-services --region $REGION --cluster $CLUSTER --services $SERVICE \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}'
```

### 查看日誌

```bash
aws logs tail /ecs/doublespot-backend --region $REGION --follow
```

### 檢查健康狀態

```bash
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --region $REGION \
  --names doublespot-backend-tg --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-target-health --region $REGION \
  --target-group-arn $TARGET_GROUP_ARN
```

### 測試 ALB 端點

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --region $REGION \
  --names doublespot-test-alb --query 'LoadBalancers[0].DNSName' --output text)

curl http://$ALB_DNS/health
```

### 查看最近停止的任務

```bash
aws ecs list-tasks --region $REGION --cluster $CLUSTER \
  --desired-status STOPPED --max-items 1 | \
  jq -r '.taskArns[0]' | \
  xargs -I {} aws ecs describe-tasks --region $REGION --cluster $CLUSTER --tasks {} \
  --query 'tasks[0].{Reason:stoppedReason,Exit:containers[0].exitCode}'
```

---

## 🔧 常見問題快速修復

### ❌ exec format error

```bash
# 原因：架構不匹配
# 修復：重新構建正確架構的映像

# 檢查當前 Task Definition 架構
aws ecs describe-task-definition --region $REGION \
  --task-definition doublespot-backend \
  --query 'taskDefinition.runtimePlatform'

# 重新構建（AMD64 或 ARM64）並推送
# 然後強制更新
aws ecs update-service --region $REGION --cluster $CLUSTER \
  --service $SERVICE --force-new-deployment
```

### ❌ runningCount: 0（任務無法啟動）

```bash
# 原因：minimumHealthyPercent=100 阻止首次部署
# 修復：
aws ecs update-service --region $REGION --cluster $CLUSTER \
  --service $SERVICE \
  --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" \
  --force-new-deployment
```

### ❌ Target 健康檢查失敗

```bash
# 檢查清單：
# 1. 應用是否在 port 3000 監聽？
# 2. /health 端點是否正常工作？
# 3. Security Group 是否允許 ALB → ECS？

# 查看 Security Group 規則
aws ec2 describe-security-groups --region $REGION \
  --filters "Name=group-name,Values=doublespot-test-ecs-sg" \
  --query 'SecurityGroups[0].IpPermissions'
```

---

## 📝 Task Definition 關鍵配置

### AMD64（默認）

```json
{
  "family": "doublespot-backend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::ACCOUNT_ID:role/ecsTaskRole",
  "containerDefinitions": [
    {
      "name": "backend",
      "image": "ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/REPO:TAG",
      "portMappings": [{ "containerPort": 3000 }],
      "environment": [
        { "name": "DB_HOST", "value": "RDS_ENDPOINT" },
        { "name": "DB_USER", "value": "admin" },
        { "name": "DB_PASSWORD", "value": "PASSWORD" },
        { "name": "DB_NAME", "value": "doublespot" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/doublespot-backend",
          "awslogs-region": "us-west-2",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

### ARM64（添加此部分）

```json
{
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  }
  // ... 其他配置相同
}
```

---

## 🎯 Security Groups 配置檢查表

| 來源                 | 目標     | Port    | 規則                           |
| -------------------- | -------- | ------- | ------------------------------ |
| Internet (0.0.0.0/0) | ALB      | 80, 443 | ALB-SG Inbound                 |
| ALB-SG               | ECS-SG   | 3000    | ECS-SG Inbound                 |
| ECS-SG               | RDS-SG   | 3306    | RDS-SG Inbound                 |
| ECS-SG               | Internet | All     | ECS-SG Outbound (for ECR pull) |

---

## 💡 最佳實踐

1. **環境變數**：使用 AWS Secrets Manager 而非明文密碼
2. **映像標籤**：使用 git SHA 或版本號，不要用 `latest`
3. **架構選擇**：
   - 首次部署：AMD64（安全）
   - 生產優化：ARM64（省錢）
4. **監控**：設置 CloudWatch Alarms 監控服務健康
5. **部署策略**：生產環境改用 `minimumHealthyPercent=100`

---

## 📋 完整部署檢查清單

- [ ] RDS 實例運行（記錄 endpoint）
- [ ] IAM Roles 已創建
- [ ] ECR Repository 已創建
- [ ] CloudWatch Log Group 已創建
- [ ] ECS Cluster 已創建
- [ ] ALB 和 Target Group 已配置
- [ ] Security Groups 規則正確
- [ ] Docker 映像已推送到 ECR
- [ ] Task Definition 已註冊
- [ ] ECS Service 已創建
- [ ] `runningCount: 1` ✅
- [ ] Target health: `healthy` ✅
- [ ] `curl http://ALB_DNS/health` 返回 OK ✅

---

## 🚀 快速重新部署

```bash
# 最常用的重新部署流程
cd backend
export IMAGE_TAG="v1.0.1"

# 1. 構建並推送
docker build --platform linux/amd64 -t $ECR_REPO:$IMAGE_TAG .
docker tag $ECR_REPO:$IMAGE_TAG $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG

# 2. 更新 task-definition.json 中的 image URI

# 3. 註冊新版本
aws ecs register-task-definition --region $REGION --cli-input-json file://task-definition.json

# 4. 強制更新（ECS 會自動使用最新的 Task Definition revision）
aws ecs update-service --region $REGION --cluster $CLUSTER --service $SERVICE --force-new-deployment

# 5. 監控部署
watch -n 10 'aws ecs describe-services --region $REGION --cluster $CLUSTER --services $SERVICE --query "services[0].{Running:runningCount,Desired:desiredCount}"'
```

---

---

## 🔄 GitHub Actions 自動部署設置

### 使用自動化腳本（推薦）

```bash
# 確保已完成基礎設施設置
source infrastructure-config.env

# 運行 GitHub Actions 設置腳本
./scripts/setup-github-actions.sh

# 腳本會自動：
# - 創建 OIDC Provider
# - 創建 IAM Policy 和 Role
# - 生成 GitHub Variables 配置清單
```

### 手動設置步驟

**1. 創建 OIDC Provider**
```bash
# AWS Console: IAM → Identity providers → Add provider
# Provider URL: https://token.actions.githubusercontent.com
# Audience: sts.amazonaws.com
```

**2. 創建 IAM Role**
```bash
# 使用 SETUP_GUIDE.md 中的策略
# Trust GitHub Actions OIDC Provider
# 附加 ECR + ECS 權限
```

**3. 配置 GitHub Variables**

前往 Repository → Settings → Secrets and variables → Actions → Variables

| Variable | Value |
|----------|-------|
| `AWS_REGION` | `us-west-2` |
| `AWS_ROLE_TO_ASSUME` | `arn:aws:iam::ACCOUNT_ID:role/github-actions-deploy-role` |
| `ECR_REPOSITORY` | `doublespot-backend` |
| `ECS_CLUSTER` | `doublespot-cluster` |
| `ECS_SERVICE` | `backend-service` |
| `CONTAINER_NAME` | `backend` |

**4. 測試部署**
```bash
# 推送代碼到 main 分支觸發 workflow
git add .
git commit -m "feat: trigger CI/CD"
git push origin main
```

詳細說明請參考 [GITHUB_ACTIONS_SETUP.md](./GITHUB_ACTIONS_SETUP.md)

---

**💾 保存此文件並收藏！**

需要詳細步驟說明請參考：
- `NEXT_STEPS.md` - 完整部署指南
- `GITHUB_ACTIONS_SETUP.md` - CI/CD 設置指南
