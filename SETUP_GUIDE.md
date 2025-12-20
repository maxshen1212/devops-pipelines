# AWS 與 GitHub Actions 設置完整指南

## 📋 概述

本指南將分兩個階段進行設置：

1. **第一階段：手動設置並測試 AWS 服務**（推薦先完成）
2. **第二階段：配置 GitHub Actions CI/CD**

**為什麼要先手動設置 AWS？**
- ✅ 確保所有 AWS 資源正確配置
- ✅ 驗證權限和訪問控制
- ✅ 減少 CI/CD 流程中的錯誤
- ✅ 更容易排查問題
- ✅ 理解整個部署流程

---

## 🎯 第一階段：手動設置並測試 AWS 服務

### 步驟 1：準備 AWS 帳號資訊

1. 登入 AWS Console
2. 記錄以下資訊（稍後會用到）：
   - **AWS Account ID**：點擊右上角用戶名查看
   - **AWS Region**：選擇您要使用的區域（例如：`us-west-2`）

### 步驟 2：創建後端所需 AWS 資源

#### 2.1 創建 ECR Repository

1. 前往 **ECR** → **Repositories** → **Create repository**
2. 設置：
   - **Visibility settings**: Private
   - **Repository name**: `doublespot-backend`（或您選擇的名稱）
   - **Tag immutability**: 可選啟用
3. 點擊 **Create repository**
4. **記錄 Repository URI**（格式：`ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/REPO_NAME`）

**測試**：
```bash
# 確保 AWS CLI 已配置
aws ecr describe-repositories --repository-names doublespot-backend
```

#### 2.2 創建 CloudWatch Log Group

1. 前往 **CloudWatch** → **Log groups** → **Create log group**
2. 設置：
   - **Log group name**: `/ecs/doublespot-backend`
   - **Retention**: 選擇保留天數（例如：7 天）
3. 點擊 **Create log group**

**測試**：
```bash
aws logs describe-log-groups --log-group-name-prefix "/ecs/doublespot-backend"
```

#### 2.3 創建 ECS Task Execution Role

1. 前往 **IAM** → **Roles** → **Create role**
2. 選擇 **AWS service** → **ECS** → **ECS Task**
3. 選擇 **Use case**: **ECS Task**
4. 點擊 **Next**
5. 附加策略：
   - `AmazonECSTaskExecutionRolePolicy`（必須）
   - 如果需要訪問 Secrets Manager 或 Parameter Store，添加相應權限
6. 點擊 **Next**
7. 設置：
   - **Role name**: `ecsTaskExecutionRole`
   - **Description**: `Role for ECS tasks to pull images and write logs`
8. 點擊 **Create role**
9. **記錄 Role ARN**（格式：`arn:aws:iam::ACCOUNT_ID:role/ecsTaskExecutionRole`）

**測試**：
```bash
aws iam get-role --role-name ecsTaskExecutionRole --query 'Role.Arn'
```

#### 2.4 創建 ECS Task Role（可選）

1. 前往 **IAM** → **Roles** → **Create role**
2. 選擇 **AWS service** → **ECS** → **ECS Task**
3. 選擇 **Use case**: **ECS Task**
4. 點擊 **Next**
5. 如果應用需要訪問其他 AWS 服務（如 S3、DynamoDB），附加相應策略
6. 點擊 **Next**
7. 設置：
   - **Role name**: `ecsTaskRole`
8. 點擊 **Create role**
9. **記錄 Role ARN**

#### 2.5 創建 ECS Cluster

1. 前往 **ECS** → **Clusters** → **Create cluster**
2. 設置：
   - **Cluster name**: `doublespot-cluster`（或您選擇的名稱）
   - **Infrastructure**: **AWS Fargate (serverless)**
3. 點擊 **Create**

**測試**：
```bash
aws ecs describe-clusters --clusters doublespot-cluster
```

#### 2.6 創建 Application Load Balancer（ALB）

1. 前往 **EC2** → **Load Balancers** → **Create Load Balancer**
2. 選擇 **Application Load Balancer**
3. 設置：
   - **Name**: `doublespot-alb`
   - **Scheme**: Internet-facing
   - **IP address type**: IPv4
   - **VPC**: 選擇您的 VPC
   - **Availability Zones**: 選擇至少 2 個可用區
   - **Security group**: 創建或選擇允許 HTTP/HTTPS 的安全組
4. 點擊 **Next: Configure Security Settings**
5. 點擊 **Next: Configure Routing**
6. 創建 Target Group：
   - **Target group name**: `doublespot-backend-tg`
   - **Target type**: IP
   - **Protocol**: HTTP
   - **Port**: 3000
   - **Health check path**: `/health`
   - **Health check protocol**: HTTP
   - **Health check port**: 3000
7. 點擊 **Next: Register Targets**（暫時跳過）
8. 點擊 **Next: Review**
9. 點擊 **Create**

**測試**：
```bash
aws elbv2 describe-load-balancers --names doublespot-alb
aws elbv2 describe-target-groups --names doublespot-backend-tg
```

#### 2.7 手動推送 Docker 映像到 ECR（測試）

```bash
# 1. 登入 ECR
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com

# 2. 構建映像
cd backend
docker build -t doublespot-backend:test .

# 3. 標記映像
docker tag doublespot-backend:test ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/doublespot-backend:test

# 4. 推送映像
docker push ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/doublespot-backend:test
```

**驗證**：
```bash
aws ecr describe-images --repository-name doublespot-backend
```

#### 2.8 創建 ECS Task Definition

1. 前往 **ECS** → **Task Definitions** → **Create new Task Definition**
2. 設置：
   - **Task definition family**: `doublespot-backend`
   - **Launch type**: **Fargate**
   - **Task size**:
     - **CPU**: 0.25 vCPU (256)
     - **Memory**: 0.5 GB (512)
3. 在 **Container details** 中：
   - **Container name**: `backend`
   - **Image URI**: `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/doublespot-backend:test`
   - **Port mappings**:
     - **Container port**: 3000
     - **Protocol**: TCP
   - **Environment variables**:
     - `PORT`: `3000`
     - `NODE_ENV`: `production`
   - **Log configuration**:
     - **Log driver**: awslogs
     - **Log group**: `/ecs/doublespot-backend`
     - **Log stream prefix**: `ecs`
     - **Region**: 選擇您的區域
4. 在 **Task execution role** 中選擇：`ecsTaskExecutionRole`
5. 在 **Task role** 中選擇：`ecsTaskRole`（如果創建了）
6. 點擊 **Create**

**測試**：
```bash
aws ecs describe-task-definition --task-definition doublespot-backend
```

#### 2.9 創建 ECS Service

1. 前往 **ECS** → **Clusters** → 選擇您的 cluster → **Services** → **Create**
2. 設置：
   - **Launch type**: Fargate
   - **Task Definition**: `doublespot-backend`
   - **Service name**: `backend-service`
   - **Number of tasks**: 1
   - **VPC**: 選擇您的 VPC
   - **Subnets**: 選擇至少 2 個子網
   - **Security groups**: 選擇允許端口 3000 的安全組
   - **Load balancing**: 選擇 **Application Load Balancer**
   - **Load balancer name**: 選擇 `doublespot-alb`
   - **Container to load balance**: 選擇 `backend:3000`
   - **Target group name**: 選擇 `doublespot-backend-tg`
   - **Health check grace period**: 60 秒
3. 點擊 **Create**

**等待服務穩定**（可能需要幾分鐘）

**測試**：
```bash
# 檢查服務狀態
aws ecs describe-services --cluster doublespot-cluster --services backend-service

# 檢查任務狀態
aws ecs list-tasks --cluster doublespot-cluster --service-name backend-service

# 獲取 ALB DNS 名稱並測試
ALB_DNS=$(aws elbv2 describe-load-balancers --names doublespot-alb --query 'LoadBalancers[0].DNSName' --output text)
curl http://$ALB_DNS/health
```

### 步驟 3：創建前端所需 AWS 資源

#### 3.1 創建 S3 Bucket

1. 前往 **S3** → **Buckets** → **Create bucket**
2. 設置：
   - **Bucket name**: `doublespot-frontend`（必須全局唯一）
   - **AWS Region**: 選擇您的區域
   - **Block Public Access**: **取消勾選**（前端需要公開訪問）
     - 勾選確認框以允許公開訪問
   - **Bucket Versioning**: 可選啟用
3. 點擊 **Create bucket**

**設置 Bucket Policy**（允許公開讀取）：
1. 選擇 bucket → **Permissions** → **Bucket policy**
2. 添加以下策略（替換 `BUCKET_NAME`）：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }
  ]
}
```

**設置靜態網站托管**（可選，如果直接使用 S3）：
1. 選擇 bucket → **Properties** → **Static website hosting**
2. 啟用並設置：
   - **Index document**: `index.html`
   - **Error document**: `index.html`（用於 SPA）

**測試**：
```bash
# 創建測試文件
echo "Hello World" > test.txt

# 上傳到 S3
aws s3 cp test.txt s3://doublespot-frontend/test.txt

# 列出文件
aws s3 ls s3://doublespot-frontend/

# 刪除測試文件
aws s3 rm s3://doublespot-frontend/test.txt
```

#### 3.2 創建 CloudFront Distribution

1. 前往 **CloudFront** → **Distributions** → **Create distribution**
2. 設置：
   - **Origin domain**: 選擇您的 S3 bucket（例如：`doublespot-frontend.s3.us-west-2.amazonaws.com`）
   - **Origin access**: 選擇 **Origin access control settings (recommended)**
     - 點擊 **Create control setting**
     - **Name**: `doublespot-frontend-oac`
     - **Signing behavior**: **Sign requests (recommended)**
     - 點擊 **Create**
   - **Viewer protocol policy**: **Redirect HTTP to HTTPS**
   - **Allowed HTTP methods**: **GET, HEAD, OPTIONS**
   - **Cache policy**: **CachingOptimized**（或自定義）
   - **Default root object**: `index.html`
3. 點擊 **Create distribution**

**更新 S3 Bucket Policy**（允許 CloudFront 訪問）：
1. 返回 S3 bucket → **Permissions** → **Bucket policy**
2. 更新策略，添加 CloudFront OAC 的訪問權限（CloudFront 會提供策略模板）

**等待 Distribution 部署**（可能需要 10-15 分鐘）

**記錄 Distribution ID** 和 **Distribution Domain Name**

**測試**：
```bash
# 獲取 Distribution ID
aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='doublespot-frontend'].Id" --output text

# 創建測試文件並上傳
echo "<html><body>Test</body></html>" > index.html
aws s3 cp index.html s3://doublespot-frontend/index.html

# 等待幾分鐘後訪問 CloudFront URL
# 格式：https://DISTRIBUTION_ID.cloudfront.net
```

---

## 🔐 第二階段：配置 GitHub Actions

### 步驟 4：設置 AWS IAM 角色（用於 GitHub Actions）

#### 4.1 創建 OIDC Identity Provider（首次設置）

1. 前往 **IAM** → **Identity providers** → **Add provider**
2. 選擇 **OpenID Connect**
3. 設置：
   - **Provider URL**: `https://token.actions.githubusercontent.com`
   - **Audience**: `sts.amazonaws.com`
   - 點擊 **Get thumbprint**（AWS 會自動驗證）
4. 點擊 **Add provider**
5. **記錄 Provider ARN**（格式：`arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com`）

#### 4.2 創建 IAM Role（用於 GitHub Actions）

1. 前往 **IAM** → **Roles** → **Create role**
2. 選擇 **Web Identity**
3. 在 **Identity provider** 中：
   - 選擇 `token.actions.githubusercontent.com`
   - **Audience**: `sts.amazonaws.com`
4. 點擊 **Next**
5. 設置 **Conditions**（限制特定 repository）：

```json
{
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
  },
  "StringLike": {
    "token.actions.githubusercontent.com:sub": "repo:YOUR_GITHUB_USERNAME/YOUR_REPO_NAME:*"
  }
}
```

**替換**：
- `YOUR_GITHUB_USERNAME`: 您的 GitHub 用戶名或組織名
- `YOUR_REPO_NAME`: 您的 repository 名稱（例如：`devops-piplines`）

**更安全的選項**（僅允許 main 分支）：
```json
{
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub": "repo:YOUR_GITHUB_USERNAME/YOUR_REPO_NAME:ref:refs/heads/main"
  }
}
```

6. 點擊 **Next**

#### 4.3 創建並附加權限策略

1. 點擊 **Create policy**（會在新標籤頁打開）
2. 選擇 **JSON** 標籤
3. 複製以下策略（**後端 + 前端組合策略**）：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAccess",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "ECRImageManagement",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "arn:aws:ecr:REGION:ACCOUNT_ID:repository/doublespot-backend"
    },
    {
      "Sid": "ECSServiceManagement",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService"
      ],
      "Resource": [
        "arn:aws:ecs:REGION:ACCOUNT_ID:service/CLUSTER_NAME/SERVICE_NAME",
        "arn:aws:ecs:REGION:ACCOUNT_ID:task-definition/FAMILY_NAME:*"
      ]
    },
    {
      "Sid": "ECSPassRole",
      "Effect": "Allow",
      "Action": ["iam:PassRole"],
      "Resource": [
        "arn:aws:iam::ACCOUNT_ID:role/ecsTaskExecutionRole",
        "arn:aws:iam::ACCOUNT_ID:role/ecsTaskRole"
      ],
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    },
    {
      "Sid": "S3BucketAccess",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::BUCKET_NAME"
    },
    {
      "Sid": "S3ObjectManagement",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    },
    {
      "Sid": "CloudFrontInvalidation",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateInvalidation",
        "cloudfront:GetInvalidation",
        "cloudfront:ListInvalidations"
      ],
      "Resource": "arn:aws:cloudfront::ACCOUNT_ID:distribution/DISTRIBUTION_ID"
    }
  ]
}
```

**替換所有佔位符**：
- `REGION`: 您的 AWS 區域（例如：`us-west-2`）
- `ACCOUNT_ID`: 您的 AWS 帳號 ID（12 位數字）
- `CLUSTER_NAME`: ECS cluster 名稱（例如：`doublespot-cluster`）
- `SERVICE_NAME`: ECS service 名稱（例如：`backend-service`）
- `FAMILY_NAME`: Task definition family 名稱（例如：`doublespot-backend`）
- `BUCKET_NAME`: S3 bucket 名稱（例如：`doublespot-frontend`）
- `DISTRIBUTION_ID`: CloudFront distribution ID

4. 點擊 **Next**
5. 設置：
   - **Policy name**: `GitHubActionsDeployPolicy`
   - **Description**: `Policy for GitHub Actions to deploy backend to ECS and frontend to S3`
6. 點擊 **Create policy**
7. 返回角色創建頁面，刷新策略列表，選擇剛創建的策略
8. 點擊 **Next**

#### 4.4 完成角色創建

1. 設置：
   - **Role name**: `github-actions-deploy-role`
   - **Description**: `IAM role for GitHub Actions to deploy backend to ECS and frontend to S3/CloudFront`
2. 點擊 **Create role**
3. **記錄 Role ARN**（格式：`arn:aws:iam::ACCOUNT_ID:role/github-actions-deploy-role`）

**測試**：
```bash
aws iam get-role --role-name github-actions-deploy-role --query 'Role.Arn'
```

### 步驟 5：配置 GitHub Repository Variables

1. 前往 GitHub Repository → **Settings** → **Secrets and variables** → **Actions**
2. 點擊 **Variables** 標籤 → **New repository variable**

**添加以下變數**：

#### 後端部署變數

| 變數名稱             | 說明                | 範例值                                                      |
| -------------------- | ------------------- | ----------------------------------------------------------- |
| `AWS_REGION`         | AWS 區域            | `us-west-2`                                                 |
| `AWS_ROLE_TO_ASSUME` | IAM 角色 ARN        | `arn:aws:iam::123456789012:role/github-actions-deploy-role` |
| `ECR_REPOSITORY`     | ECR repository 名稱 | `doublespot-backend`                                        |
| `ECS_CLUSTER`        | ECS cluster 名稱    | `doublespot-cluster`                                        |
| `ECS_SERVICE`        | ECS service 名稱    | `backend-service`                                           |
| `CONTAINER_NAME`     | ECS container 名稱  | `backend`                                                   |

#### 前端部署變數

| 變數名稱                     | 說明                       | 範例值                                                      |
| ---------------------------- | -------------------------- | ----------------------------------------------------------- |
| `AWS_REGION`                 | AWS 區域                   | `us-west-2`                                                 |
| `AWS_ROLE_TO_ASSUME`         | IAM 角色 ARN               | `arn:aws:iam::123456789012:role/github-actions-deploy-role` |
| `S3_BUCKET`                  | S3 bucket 名稱             | `doublespot-frontend`                                       |
| `CLOUDFRONT_DISTRIBUTION_ID` | CloudFront distribution ID | `E1234567890ABC`                                            |
| `VITE_API_BASE_URL`          | API 基礎 URL               | `https://YOUR_ALB_DNS_NAME` 或 `https://api.example.com`    |

**注意**：
- 如果 `AWS_REGION` 和 `AWS_ROLE_TO_ASSUME` 在後端和前端相同，只需設置一次
- `VITE_API_BASE_URL` 應該是您的 ALB DNS 名稱或 API 網域名稱

### 步驟 6：更新 Task Definition Template

編輯 `backend/taskdef.template.json`，確保以下欄位正確：

1. **executionRoleArn**: 替換 `ACCOUNT_ID` 為實際帳號 ID
2. **taskRoleArn**: 替換 `ACCOUNT_ID` 為實際帳號 ID（如果使用）
3. **awslogs-group**: 確認與 CloudWatch Log Group 名稱匹配
4. **awslogs-region**: 確認與 AWS 區域匹配

### 步驟 7：測試 GitHub Actions Workflow

1. 提交一個小的更改到 `main` 分支（例如：修改 README）
2. 前往 GitHub → **Actions** 標籤
3. 查看 workflow 執行日誌
4. 確認以下步驟成功：
   - ✅ Configure AWS credentials
   - ✅ Login to ECR（後端）或 Deploy to S3（前端）
   - ✅ Deploy 步驟

---

## ✅ 驗證檢查清單

### AWS 資源驗證

- [ ] ECR repository 存在且可以推送映像
- [ ] CloudWatch Log Group 已創建
- [ ] ECS Task Execution Role 已創建並有正確權限
- [ ] ECS Task Role 已創建（如果使用）
- [ ] ECS Cluster 已創建
- [ ] ALB 和 Target Group 已創建並配置
- [ ] ECS Task Definition 已創建
- [ ] ECS Service 運行正常且健康檢查通過
- [ ] S3 bucket 已創建並配置公開訪問
- [ ] CloudFront Distribution 已創建並部署完成
- [ ] 手動推送的 Docker 映像可以成功部署到 ECS

### IAM 設置驗證

- [ ] OIDC Identity Provider 已創建
- [ ] IAM Role 已創建並配置信任關係
- [ ] IAM Role 信任關係條件正確（包含您的 repository）
- [ ] IAM Role 已附加必要的權限策略
- [ ] 策略中的資源 ARN 已更新為實際值

### GitHub 設置驗證

- [ ] 所有必要的 Variables 已添加到 GitHub Repository
- [ ] Variables 中的值正確（特別是 IAM Role ARN）
- [ ] Workflow 文件已更新並啟用 AWS 部署步驟
- [ ] Workflow 文件包含 `permissions.id-token: write`

### 功能驗證

- [ ] 可以手動運行 `aws sts get-caller-identity` 獲取帳號 ID
- [ ] ECR repository 可以手動推送 Docker 映像
- [ ] ECS service 可以手動更新
- [ ] ALB 健康檢查通過
- [ ] S3 bucket 可以手動上傳文件
- [ ] CloudFront 可以手動創建 invalidation
- [ ] GitHub Actions workflow 可以成功執行

---

## 🐛 常見問題排查

### 問題 1：`Not authorized to perform sts:AssumeRoleWithWebIdentity`

**解決方案**：
1. 檢查 IAM Role 的信任關係
2. 確認 OIDC provider URL 正確
3. 確認 repository 名稱在條件中正確（區分大小寫）

### 問題 2：`Access Denied` 當推送到 ECR

**解決方案**：
1. 檢查 IAM Role 是否附加了 ECR 權限策略
2. 確認策略中的 ECR repository ARN 正確

### 問題 3：`The service does not exist`

**解決方案**：
1. 確認 Variables 中的 `ECS_SERVICE` 和 `ECS_CLUSTER` 名稱正確
2. 確認 IAM Role 有 ECS 權限

### 問題 4：`AccessDenied when calling PutObject`

**解決方案**：
1. 確認 S3 bucket 名稱正確
2. 確認 IAM Role 有 S3 權限
3. 檢查 S3 bucket policy

---

## 📚 參考資源

- [AWS_GITHUB_SETUP.md](./AWS_GITHUB_SETUP.md) - 詳細的技術文檔
- [GitHub Actions OIDC 文檔](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [AWS IAM OIDC 文檔](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)

---

## 🎉 完成！

完成所有步驟後，您的 CI/CD 流程應該可以正常運作。每次推送到 `main` 分支時，GitHub Actions 會自動：

1. **後端**：構建 Docker 映像 → 推送到 ECR → 部署到 ECS
2. **前端**：構建靜態文件 → 上傳到 S3 → 使 CloudFront 緩存失效

如有任何問題，請參考 [AWS_GITHUB_SETUP.md](./AWS_GITHUB_SETUP.md) 中的詳細故障排除指南。

