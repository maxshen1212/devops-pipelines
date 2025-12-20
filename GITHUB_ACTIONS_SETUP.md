# GitHub Actions 設置指南 🚀

> 前置條件：✅ AWS 基礎設施已部署並運行

## 📋 設置檢查清單

- [ ] 創建 OIDC Identity Provider
- [ ] 創建 IAM Role for GitHub Actions
- [ ] 配置 GitHub Repository Variables
- [ ] 測試 GitHub Actions Workflow
- [ ] (可選) 設置分支保護規則

---

## 🔐 步驟 1：創建 OIDC Identity Provider

**前往**：AWS Console → **IAM** → **Identity providers** → **Add provider**

| 設定項        | 值                                            |
| ------------- | --------------------------------------------- |
| Provider type | **OpenID Connect**                            |
| Provider URL  | `https://token.actions.githubusercontent.com` |
| Audience      | `sts.amazonaws.com`                           |

**操作**：

1. 點擊 **Get thumbprint**（自動驗證）
2. 點擊 **Add provider**
3. **記錄 Provider ARN**（後面會用到）

**驗證**：

```bash
aws iam list-open-id-connect-providers
```

---

## 👤 步驟 2：創建 IAM Role for GitHub Actions

### 2.1 準備信息

首先獲取您的配置信息：

```bash
# 如果已運行自動化腳本
source infrastructure-config.env

# 獲取 GitHub Repository 信息
export GITHUB_USERNAME="YOUR_USERNAME"  # 您的 GitHub 用戶名
export GITHUB_REPO="devops-piplines"    # Repository 名稱

echo "Account ID: $ACCOUNT_ID"
echo "Region: $REGION"
echo "ECR Repo: $ECR_REPO"
echo "ECS Cluster: $CLUSTER_NAME"
echo "ECS Service: $SERVICE_NAME"
echo "GitHub: $GITHUB_USERNAME/$GITHUB_REPO"
```

### 2.2 創建策略文件

創建一個 IAM 策略文件 `github-actions-policy.json`：

```bash
cat > github-actions-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuthToken",
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
      "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO}"
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
      "Resource": "*"
    },
    {
      "Sid": "ECSPassRole",
      "Effect": "Allow",
      "Action": ["iam:PassRole"],
      "Resource": [
        "arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole",
        "arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskRole"
      ],
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    }
  ]
}
EOF
```

### 2.3 創建策略

```bash
POLICY_ARN=$(aws iam create-policy \
  --policy-name GitHubActionsDeployPolicy \
  --policy-document file://github-actions-policy.json \
  --description "Policy for GitHub Actions to deploy to ECS" \
  --query 'Policy.Arn' \
  --output text)

echo "✅ Policy created: $POLICY_ARN"
```

### 2.4 創建 Trust Policy

創建信任策略文件：

```bash
cat > github-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_USERNAME}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF
```

**更安全的選項**（僅允許 main 分支）：

```bash
cat > github-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_USERNAME}/${GITHUB_REPO}:ref:refs/heads/main"
        }
      }
    }
  ]
}
EOF
```

### 2.5 創建 Role

```bash
ROLE_ARN=$(aws iam create-role \
  --role-name github-actions-deploy-role \
  --assume-role-policy-document file://github-trust-policy.json \
  --description "Role for GitHub Actions to deploy to ECS" \
  --query 'Role.Arn' \
  --output text)

echo "✅ Role created: $ROLE_ARN"
```

### 2.6 附加策略到 Role

```bash
aws iam attach-role-policy \
  --role-name github-actions-deploy-role \
  --policy-arn $POLICY_ARN

echo "✅ Policy attached to role"
```

### 2.7 保存 Role ARN

```bash
echo "AWS_ROLE_TO_ASSUME=$ROLE_ARN" >> infrastructure-config.env
echo ""
echo "🎉 GitHub Actions IAM Role 已創建！"
echo "   Role ARN: $ROLE_ARN"
echo ""
echo "📝 記錄此 ARN，下一步需要在 GitHub 中配置"
```

---

## ⚙️ 步驟 3：配置 GitHub Repository Variables

### 3.1 前往 GitHub Repository Settings

1. 打開您的 GitHub Repository
2. 點擊 **Settings**
3. 左側菜單選擇 **Secrets and variables** → **Actions**
4. 選擇 **Variables** 標籤

### 3.2 添加以下 Variables

點擊 **New repository variable** 並添加：

| Variable Name        | Value                  | 範例                                                        |
| -------------------- | ---------------------- | ----------------------------------------------------------- |
| `AWS_REGION`         | 您的 AWS Region        | `us-west-2`                                                 |
| `AWS_ROLE_TO_ASSUME` | 步驟 2 創建的 Role ARN | `arn:aws:iam::123456789012:role/github-actions-deploy-role` |
| `ECR_REPOSITORY`     | ECR Repository 名稱    | `doublespot-backend`                                        |
| `ECS_CLUSTER`        | ECS Cluster 名稱       | `doublespot-cluster`                                        |
| `ECS_SERVICE`        | ECS Service 名稱       | `backend-service`                                           |
| `CONTAINER_NAME`     | 容器名稱               | `backend`                                                   |

**快速複製（如果使用了自動化腳本）**：

```bash
source infrastructure-config.env

echo "複製以下值到 GitHub Variables:"
echo ""
echo "AWS_REGION: $REGION"
echo "AWS_ROLE_TO_ASSUME: $ROLE_ARN"
echo "ECR_REPOSITORY: $ECR_REPO"
echo "ECS_CLUSTER: $CLUSTER_NAME"
echo "ECS_SERVICE: $SERVICE_NAME"
echo "CONTAINER_NAME: backend"
```

### 3.3 驗證配置

在 GitHub Repository 的 **Settings** → **Secrets and variables** → **Actions** → **Variables** 中確認：

- ✅ 所有 6 個變數都已添加
- ✅ 值正確無誤（特別是 Role ARN）

---

## 🧪 步驟 4：測試 GitHub Actions

### 4.1 準備測試

檢查 workflow 文件是否正確：

```bash
cat .github/workflows/backend-ci-cd.yml
```

確認：

- ✅ 使用了正確的變數名（`vars.AWS_REGION`, `vars.AWS_ROLE_TO_ASSUME` 等）
- ✅ Docker 構建使用了正確的架構（`--platform linux/amd64`）
- ✅ Task Definition template 路徑正確

### 4.2 觸發 Workflow

**方式 1：提交代碼變更**

```bash
# 在 backend 目錄做一個小改動
cd backend
echo "# GitHub Actions Test" >> README.md
git add README.md
git commit -m "test: trigger GitHub Actions"
git push origin main
```

**方式 2：手動觸發（如果 workflow 支持）**

在 GitHub Repository → **Actions** → 選擇 workflow → **Run workflow**

### 4.3 監控執行

1. 前往 GitHub Repository → **Actions**
2. 查看最新的 workflow run
3. 點擊進入查看詳細日誌

**期望的步驟**：

- ✅ Checkout code
- ✅ Setup Node.js
- ✅ Install dependencies
- ✅ Build
- ✅ Configure AWS credentials (使用 OIDC)
- ✅ Login to ECR
- ✅ Build and push Docker image
- ✅ Render task definition
- ✅ Deploy to ECS

### 4.4 驗證部署

```bash
# 檢查 ECS Service
source infrastructure-config.env
aws ecs describe-services --region $REGION --cluster $CLUSTER_NAME --services $SERVICE_NAME \
  --query 'services[0].{Running:runningCount,Desired:desiredCount}'

# 檢查最新的 Task Definition
aws ecs describe-task-definition --region $REGION --task-definition doublespot-backend \
  --query 'taskDefinition.{Revision:revision,Image:containerDefinitions[0].image}'

# 測試端點
curl http://$ALB_DNS/health
```

---

## 🎯 常見問題排查

### ❌ 錯誤：User is not authorized to perform: sts:AssumeRoleWithWebIdentity

**原因**：Trust Policy 配置錯誤

**解決**：

1. 檢查 GitHub Username 和 Repository 名稱是否正確
2. 確認 OIDC Provider 已創建
3. 驗證 Trust Policy：

```bash
aws iam get-role --role-name github-actions-deploy-role --query 'Role.AssumeRolePolicyDocument'
```

### ❌ 錯誤：Error: Cannot perform an interactive login from a non TTY device

**原因**：ECR 登入失敗

**解決**：確認 IAM Role 有 `ecr:GetAuthorizationToken` 權限

### ❌ 錯誤：Access Denied when calling PutImage

**原因**：缺少 ECR 推送權限

**解決**：檢查策略中的 ECR Resource ARN 是否正確

### ❌ 錯誤：Task definition does not exist

**原因**：Task Definition template 渲染失敗

**解決**：

1. 檢查 `backend/taskdef.template.json` 是否存在
2. 確認佔位符格式正確（`__IMAGE_URI__`, `__CONTAINER_NAME__`, `__AWS_REGION__`）

---

## ✅ 驗證清單

完成設置後，確認：

- [ ] OIDC Provider 已創建
- [ ] IAM Role 已創建並附加正確策略
- [ ] GitHub Variables 已全部配置
- [ ] GitHub Actions workflow 成功執行
- [ ] 新的 Task 已部署到 ECS
- [ ] 服務健康檢查通過
- [ ] ALB 端點返回正確響應

---

## 🎉 成功！

現在您的 CI/CD 管道已經完全自動化：

```
Git Push → GitHub Actions → Build Docker Image → Push to ECR → Deploy to ECS → 🚀
```

**下次部署**只需要：

```bash
git add .
git commit -m "feat: your changes"
git push origin main
```

GitHub Actions 會自動處理其他一切！

---

## 📚 相關資源

- [AWS OIDC 文檔](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [GitHub Actions OIDC](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [ECS Deploy Action](https://github.com/aws-actions/amazon-ecs-deploy-task-definition)

---

**需要幫助？** 參考：

- `AWS_CHEAT_SHEET.md` - 快速命令參考
- `SETUP_GUIDE.md` - 完整設置指南
- `scripts/README.md` - 自動化腳本說明
