# AWS ECS 部署指南

> **⚠️ 架構選擇**：如果您使用 Apple Silicon (M1/M2/M3) Mac，有兩種方式避免 `exec format error`：
>
> **選項 1：構建 AMD64 映像**（兼容性最好，默認）
>
> ```bash
> docker build --platform linux/amd64 -t your-image .
> ```
>
> **選項 2：使用 ARM64 Fargate**（更便宜，約節省 20%）
>
> - 正常構建映像（不需要 `--platform` 標記）
> - 在 Task Definition 中指定 `"cpuArchitecture": "ARM64"`
>
> 本指南默認使用**選項 1 (AMD64)**，如需使用 ARM64 請參考步驟 8.3。

## 📊 當前狀態

### ✅ 已完成

- VPC & Networking (`doublespot-test-vpc`)
- Security Groups (ALB、ECS、RDS)

### 📋 部署步驟概覽

1. 創建 RDS 數據庫
2. 創建 IAM Roles
3. 創建 ECR Repository
4. 創建 CloudWatch Log Group
5. 創建 ECS Cluster
6. 創建 ALB 和 Target Group
7. 構建並推送 Docker 映像
8. 創建並註冊 Task Definition
9. 創建 ECS Service
10. 測試部署
11. 設置 GitHub Actions (可選)

## 🏗️ 架構選擇：AMD64 vs ARM64

| 特性              | AMD64 (x86_64)   | ARM64 (Graviton2)   |
| ----------------- | ---------------- | ------------------- |
| **成本**          | 標準價格         | **約節省 20%** ⭐   |
| **性能**          | 標準             | 某些工作負載更快 ⭐ |
| **兼容性**        | **最佳** ⭐      | 大部分應用支持      |
| **Apple Silicon** | 需要跨平台構建   | **原生構建** ⭐     |
| **第三方映像**    | **全面支持** ⭐  | 部分支持            |
| **推薦場景**      | 默認選擇，最保險 | 成本敏感型應用      |

**建議**：

- ✅ 首次部署使用 **AMD64**（默認，最安全）
- ✅ 應用穩定後可以切換到 **ARM64** 節省成本
- ✅ 純 Node.js/Python 應用適合 ARM64

---

## 🚀 部署步驟

### 步驟 1：創建 RDS 數據庫

#### 1.1 創建 DB Subnet Group (AWS Console)

**RDS** → **Subnet groups** → **Create DB subnet group**

| 設定項             | 值                                |
| ------------------ | --------------------------------- |
| Name               | `doublespot-test-db-subnet-group` |
| VPC                | `doublespot-test-vpc`             |
| Availability Zones | `us-west-2a`, `us-west-2b`        |
| Subnets            | 選擇兩個 **private** subnets      |

**✅ 驗證**：

```bash
aws rds describe-db-subnet-groups --region us-west-2 --db-subnet-group-name doublespot-test-db-subnet-group
```

#### 1.2 創建 RDS MySQL 實例 (AWS Console)

**RDS** → **Databases** → **Create database**

| 設定項           | 值                                |
| ---------------- | --------------------------------- |
| Engine           | MySQL 8.0.43+                     |
| Template         | Free tier                         |
| DB identifier    | `doublespot-test-mysql`           |
| Master username  | `admin`                           |
| Master password  | 設置並**記錄密碼**                |
| Instance class   | `db.t3.micro`                     |
| Storage          | 20 GiB, gp3                       |
| VPC              | `doublespot-test-vpc`             |
| DB subnet group  | `doublespot-test-db-subnet-group` |
| Public access    | **No**                            |
| Security group   | `doublespot-test-rds-sg`          |
| Initial database | `doublespot`                      |

> ⏱️ 等待 5-10 分鐘讓數據庫創建完成

**✅ 驗證並記錄 Endpoint**：

```bash
RDS_ENDPOINT=$(aws rds describe-db-instances --region us-west-2 \
  --db-instance-identifier doublespot-test-mysql \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "📝 RDS Endpoint: $RDS_ENDPOINT"
```

**記錄這些資訊**（部署時需要）：

- ✅ RDS Endpoint
- ✅ Username
- ✅ Password
- ✅ Database name: `doublespot`

---

### 步驟 2：創建 IAM Roles

#### 2.1 ECS Task Execution Role (AWS Console)

**IAM** → **Roles** → **Create role**

| 步驟           | 設定                                                                                 |
| -------------- | ------------------------------------------------------------------------------------ |
| Trusted entity | **AWS service** → **Elastic Container Service** → **Elastic Container Service Task** |
| Permissions    | 附加：`AmazonECSTaskExecutionRolePolicy`                                             |
| Role name      | `ecsTaskExecutionRole`                                                               |

**✅ 驗證**：

```bash
aws iam get-role --role-name ecsTaskExecutionRole --query 'Role.Arn'
```

#### 2.2 ECS Task Role (AWS Console)

**IAM** → **Roles** → **Create role**

| 步驟           | 設定                                                                                 |
| -------------- | ------------------------------------------------------------------------------------ |
| Trusted entity | **AWS service** → **Elastic Container Service** → **Elastic Container Service Task** |
| Permissions    | 暫時不附加（需要時再添加）                                                           |
| Role name      | `ecsTaskRole`                                                                        |

**✅ 驗證並記錄 ARNs**：

```bash
aws iam get-role --role-name ecsTaskExecutionRole --query 'Role.Arn'
aws iam get-role --role-name ecsTaskRole --query 'Role.Arn'
```

---

### 步驟 3：創建 ECR Repository

**ECR** → **Repositories** → **Create repository**

| 設定項           | 值                   |
| ---------------- | -------------------- |
| Visibility       | Private              |
| Repository name  | `doublespot-backend` |
| Tag immutability | **Enabled** (推薦)   |

**✅ 驗證並記錄 URI**：

```bash
ECR_URI=$(aws ecr describe-repositories --region us-west-2 \
  --repository-names doublespot-backend \
  --query 'repositories[0].repositoryUri' --output text)
echo "📝 ECR URI: $ECR_URI"
```

---

### 步驟 4：創建 CloudWatch Log Group

**CloudWatch** → **Log groups** → **Create log group**

| 設定項         | 值                        |
| -------------- | ------------------------- |
| Log group name | `/ecs/doublespot-backend` |
| Retention      | 7 days                    |

**✅ 驗證**：

```bash
aws logs describe-log-groups --region us-west-2 \
  --log-group-name-prefix "/ecs/doublespot-backend"
```

---

### 步驟 5：創建 ECS Cluster

**ECS** → **Clusters** → **Create cluster**

| 設定項         | 值                           |
| -------------- | ---------------------------- |
| Cluster name   | `doublespot-cluster`         |
| Infrastructure | **AWS Fargate (serverless)** |

**✅ 驗證**：

```bash
aws ecs describe-clusters --region us-west-2 --clusters doublespot-cluster
```

---

### 步驟 6：創建 ALB 和 Target Group

#### 6.1 創建 Application Load Balancer

**EC2** → **Load Balancers** → **Create Load Balancer** → **Application Load Balancer**

| 設定項         | 值                                                    |
| -------------- | ----------------------------------------------------- |
| Name           | `doublespot-test-alb`                                 |
| Scheme         | Internet-facing                                       |
| VPC            | `doublespot-test-vpc`                                 |
| Subnets        | 選擇 **2 個 public subnets** (us-west-2a, us-west-2b) |
| Security group | `doublespot-test-alb-sg`                              |

#### 6.2 創建 Target Group (在 ALB 創建流程中)

| 設定項                | 值                      |
| --------------------- | ----------------------- |
| Target group name     | `doublespot-backend-tg` |
| Target type           | **IP** (重要！)         |
| Protocol              | HTTP                    |
| Port                  | 3000                    |
| Health check path     | `/health`               |
| Health check interval | 30 seconds              |

> 📝 暫時不註冊目標，ECS 會自動註冊

**✅ 驗證並記錄 ALB DNS**：

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --region us-west-2 \
  --names doublespot-test-alb \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "📝 ALB DNS: $ALB_DNS"
```

---

### 步驟 7：構建並推送 Docker 映像

> **架構選擇**：請根據您在步驟 8.3 的選擇來構建對應架構的映像。

#### 7.1 設置環境變數

```bash
cd /Users/maxshen/Desktop/Learning/WebApp/devops-piplines/backend

export REGION="us-west-2"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REPO="doublespot-backend"
export IMAGE_TAG="v1.0.0"  # 使用版本號或時間戳

echo "Account ID: $ACCOUNT_ID"
echo "Image: $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG"
```

#### 7.2 登入 ECR

```bash
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin \
  $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
```

#### 7.3 構建映像

**選項 A：AMD64 架構**（默認，兼容性最好）

```bash
docker build --platform linux/amd64 -t $ECR_REPO:$IMAGE_TAG .
```

**選項 B：ARM64 架構**（更便宜，在 Apple Silicon 上更快）

```bash
# 在 Apple Silicon Mac 上可以直接構建，不需要跨平台
docker build -t $ECR_REPO:$IMAGE_TAG .

# 或明確指定
docker build --platform linux/arm64 -t $ECR_REPO:$IMAGE_TAG .
```

> 💡 **選擇建議**：
>
> - 如果不確定，使用 **AMD64**（更安全）
> - 如果想節省成本且應用沒有特殊依賴，使用 **ARM64**

#### 7.4 標記並推送映像

```bash
docker tag $ECR_REPO:$IMAGE_TAG \
  $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG

docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG
```

**✅ 驗證映像已推送並檢查架構**：

```bash
aws ecr describe-images --region $REGION --repository-name $ECR_REPO

# 檢查本地映像架構
docker inspect $ECR_REPO:$IMAGE_TAG | grep Architecture
```

---

### 步驟 8：創建並註冊 Task Definition

#### 8.1 更新 task-definition.json

編輯 `backend/task-definition.json`，確保以下設定正確：

```bash
cd /Users/maxshen/Desktop/Learning/WebApp/devops-piplines/backend

# 獲取必要資訊
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RDS_ENDPOINT=$(aws rds describe-db-instances --region us-west-2 \
  --db-instance-identifier doublespot-test-mysql \
  --query 'DBInstances[0].Endpoint.Address' --output text)

echo "Account ID: $ACCOUNT_ID"
echo "RDS Endpoint: $RDS_ENDPOINT"
```

**檢查並更新這些欄位**：

- `image`: 映像 URI（步驟 7 推送的映像）
- `executionRoleArn`: `arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole`
- `taskRoleArn`: `arn:aws:iam::$ACCOUNT_ID:role/ecsTaskRole`
- 環境變數：
  - `DB_HOST`: RDS endpoint
  - `DB_USER`: admin（或您設定的用戶名）
  - `DB_PASSWORD`: 您的 RDS 密碼
  - `DB_NAME`: doublespot

#### 8.2 註冊 Task Definition

```bash
aws ecs register-task-definition \
  --region us-west-2 \
  --cli-input-json file://task-definition.json
```

**✅ 驗證**：

```bash
aws ecs describe-task-definition \
  --region us-west-2 \
  --task-definition doublespot-backend \
  --query 'taskDefinition.{family:family,revision:revision,image:containerDefinitions[0].image}'
```

#### 8.3 (可選) 使用 ARM64 架構

如果您想使用 ARM64（更便宜，約節省 20% 成本）：

**在 task-definition.json 中添加**：

```json
{
  "family": "doublespot-backend",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "networkMode": "awsvpc",
  ...
}
```

**然後構建 ARM64 映像**：

```bash
# 在 Apple Silicon Mac 上，不需要 --platform 標記
docker build -t $ECR_REPO:$IMAGE_TAG .

# 或者明確指定
docker build --platform linux/arm64 -t $ECR_REPO:$IMAGE_TAG .
```

> 💡 **提示**：ARM64 優點是成本更低，但 AMD64 兼容性更好。大多數第三方容器映像都支持 AMD64。

---

### 步驟 9：創建 ECS Service

> **⚠️ 重要**：首次部署時，`minimumHealthyPercent` 必須設為 0，否則無法啟動！

#### 9.1 獲取必要資訊

```bash
export REGION="us-west-2"
export CLUSTER="doublespot-cluster"
export SERVICE_NAME="backend-service"

TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --region $REGION \
  --names doublespot-backend-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

SUBNET_1=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=tag:Name,Values=doublespot-test-private-us-west-2a" \
  --query 'Subnets[0].SubnetId' --output text)

SUBNET_2=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=tag:Name,Values=doublespot-test-private-us-west-2b" \
  --query 'Subnets[0].SubnetId' --output text)

SG_ID=$(aws ec2 describe-security-groups --region $REGION \
  --filters "Name=group-name,Values=doublespot-test-ecs-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

echo "✅ Target Group: $TARGET_GROUP_ARN"
echo "✅ Subnets: $SUBNET_1, $SUBNET_2"
echo "✅ Security Group: $SG_ID"
```

#### 9.2 創建 Service

```bash
aws ecs create-service \
  --region $REGION \
  --cluster $CLUSTER \
  --service-name $SERVICE_NAME \
  --task-definition doublespot-backend \
  --desired-count 1 \
  --launch-type FARGATE \
  --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$SG_ID],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TARGET_GROUP_ARN,containerName=backend,containerPort=3000" \
  --health-check-grace-period-seconds 60
```

> 📝 **為什麼 minimumHealthyPercent=0？**
> 首次部署時沒有健康的任務，如果設為 100，新任務將無法啟動。部署成功後可以改回 100。

#### 9.3 監控部署進度

```bash
# 查看服務狀態（每 30 秒執行一次）
watch -n 30 'aws ecs describe-services \
  --region us-west-2 \
  --cluster doublespot-cluster \
  --services backend-service \
  --query "services[0].{Status:status,Running:runningCount,Desired:desiredCount}"'
```

或手動檢查：

```bash
aws ecs describe-services \
  --region $REGION \
  --cluster $CLUSTER \
  --services $SERVICE_NAME \
  --query 'services[0].{status:status,runningCount:runningCount,desiredCount:desiredCount,events:events[0:3]}'
```

**✅ 等待直到 `runningCount: 1`**（約 2-5 分鐘）

---

### 步驟 10：測試部署

#### 10.1 檢查服務狀態

```bash
aws ecs describe-services \
  --region us-west-2 \
  --cluster doublespot-cluster \
  --services backend-service \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}'
```

**期望結果**：`"Running": 1`

#### 10.2 檢查 Target Group 健康狀態

```bash
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --region us-west-2 \
  --names doublespot-backend-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-target-health \
  --region us-west-2 \
  --target-group-arn $TARGET_GROUP_ARN
```

**期望結果**：至少一個 target 狀態為 `"State": "healthy"`

#### 10.3 測試 ALB 端點

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --region us-west-2 \
  --names doublespot-test-alb \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "ALB URL: http://$ALB_DNS"

# 測試健康檢查
curl http://$ALB_DNS/health
```

**期望結果**：返回 `ok` 或 `{"status":"ok"}`

#### 10.4 查看日誌

```bash
aws logs tail /ecs/doublespot-backend --region us-west-2 --follow
```

**期望看到**：

```
Server running on port 3000
```

---

### 步驟 11：設置 GitHub Actions (可選)

如果需要自動化部署，參考 `SETUP_GUIDE.md` 設置 GitHub Actions。

**需要配置**：

1. OIDC Identity Provider
2. IAM Role for GitHub Actions
3. GitHub Repository Variables

**如果使用 ARM64**：

修改 `.github/workflows/backend-ci-cd.yml` 第 57 行：

```yaml
# 從
docker build --platform linux/amd64 -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .

# 改為
docker build --platform linux/arm64 -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
```

並確保 `task-definition.json` 包含：

```json
"runtimePlatform": {
  "cpuArchitecture": "ARM64",
  "operatingSystemFamily": "LINUX"
}
```

---

## ✅ 驗證檢查清單

- [ ] RDS 實例運行中
- [ ] ECR 映像已推送（AMD64 架構）
- [ ] Task Definition 已註冊
- [ ] ECS Service 運行中 (`runningCount: 1`)
- [ ] Target Group 健康檢查通過 (`State: healthy`)
- [ ] ALB 端點返回正確響應
- [ ] CloudWatch Logs 顯示應用程序啟動

---

## 🐛 常見問題排查

### 問題 1：exec format error

**錯誤**：`exec /usr/local/bin/docker-entrypoint.sh: exec format error`

**原因**：Docker 映像架構與 Task Definition 配置不匹配

**解決方案 A：構建匹配的映像**（推薦，更快）

```bash
cd backend

# 如果 Task Definition 使用默認（AMD64）
docker build --platform linux/amd64 -t doublespot-backend:fixed .

# 如果 Task Definition 配置了 ARM64
docker build --platform linux/arm64 -t doublespot-backend:fixed .

# 推送映像
docker tag doublespot-backend:fixed $ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/doublespot-backend:fixed
docker push $ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/doublespot-backend:fixed

# 更新 task-definition.json 中的映像 URI，然後註冊
aws ecs register-task-definition --region us-west-2 --cli-input-json file://task-definition.json

# 強制更新服務
aws ecs update-service \
  --region us-west-2 \
  --cluster doublespot-cluster \
  --service backend-service \
  --force-new-deployment
```

**解決方案 B：修改 Task Definition 架構**（適合已有 ARM64 映像）

在 `task-definition.json` 中添加或修改：

```json
{
  "family": "doublespot-backend",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",  // 改為 "X86_64" 或 "ARM64"
    "operatingSystemFamily": "LINUX"
  },
  ...
}
```

然後重新註冊並更新服務。

### 問題 2：服務無法啟動任務 (runningCount: 0)

**原因**：`minimumHealthyPercent: 100` 阻止首次部署

**解決**：

```bash
aws ecs update-service \
  --region us-west-2 \
  --cluster doublespot-cluster \
  --service backend-service \
  --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" \
  --force-new-deployment
```

### 問題 3：Target Group 健康檢查失敗

**檢查步驟**：

```bash
# 1. 檢查日誌
aws logs tail /ecs/doublespot-backend --region us-west-2

# 2. 確認應用程序正在監聽 port 3000
# 3. 確認 /health 端點正常工作
# 4. 檢查安全組是否允許 ALB → ECS 的流量
```

**常見原因**：

- 應用程序未啟動
- 監聽錯誤的端口
- `/health` 端點未實現
- 安全組配置錯誤

---

## 📝 常用命令參考

### 設置環境變數

```bash
export REGION="us-west-2"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER="doublespot-cluster"
export SERVICE_NAME="backend-service"
```

### 檢查服務狀態

```bash
aws ecs describe-services --region $REGION --cluster $CLUSTER --services $SERVICE_NAME \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}'
```

### 查看日誌

```bash
aws logs tail /ecs/doublespot-backend --region $REGION --follow
```

### 強制重新部署

```bash
aws ecs update-service --region $REGION --cluster $CLUSTER \
  --service $SERVICE_NAME --force-new-deployment
```

### 測試 ALB 端點

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --region $REGION \
  --names doublespot-test-alb --query 'LoadBalancers[0].DNSName' --output text)
curl http://$ALB_DNS/health
```

---

**🎉 完成！** 您的應用程序現在應該在 AWS ECS 上運行了。
