# AWS 自動化部署腳本

這個目錄包含使用 AWS CLI 自動化創建和部署基礎設施的腳本。

## 📋 腳本列表

| 腳本 | 功能 | 使用時機 |
|------|------|----------|
| `setup-aws-infrastructure.sh` | 自動創建所有 AWS 基礎設施 | 首次設置或重新創建環境 |
| `deploy-ecs-service.sh` | 部署或更新 ECS Service | 每次代碼更新後部署 |
| `setup-github-actions.sh` | 🆕 自動配置 GitHub Actions OIDC 和 IAM | 設置 CI/CD 自動部署 |

---

## 🚀 快速開始

### 前置需求

1. **AWS CLI** 已安裝並配置
   ```bash
   aws --version
   aws sts get-caller-identity  # 驗證身份
   ```

2. **jq** 已安裝（用於 JSON 處理）
   ```bash
   # macOS
   brew install jq

   # Linux
   sudo apt-get install jq  # Ubuntu/Debian
   sudo yum install jq      # CentOS/RHEL
   ```

3. **VPC 和 Security Groups** 已創建
   - 需要已有的 VPC、Subnets 和 Security Groups
   - 如未創建，請先參考 `SETUP_GUIDE.md` 的 VPC 部分

---

## 📖 使用指南

### 步驟 1：設置基礎設施

```bash
# 1. 給腳本添加執行權限
chmod +x scripts/*.sh

# 2. 運行基礎設施設置腳本
./scripts/setup-aws-infrastructure.sh

# 腳本會互動式詢問：
# - 項目名稱（默認：doublespot）
# - 環境名稱（默認：test）
# - AWS Region（默認：us-west-2）
# - 是否創建 RDS（可選）
```

**創建的資源**：
- ✅ IAM Roles (ecsTaskExecutionRole, ecsTaskRole)
- ✅ ECR Repository
- ✅ CloudWatch Log Group
- ✅ ECS Cluster
- ✅ Application Load Balancer
- ✅ Target Group
- ✅ ALB Listener (HTTP:80)
- ✅ RDS MySQL（如果選擇創建）

**輸出文件**：
- `infrastructure-config.env` - 包含所有資源 ID 和配置

### 步驟 2：構建並推送 Docker 映像

```bash
# 1. 載入配置
source infrastructure-config.env

# 2. 登入 ECR
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin \
  $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# 3. 構建映像
cd backend
export IMAGE_TAG="v1.0.0"

# AMD64:
docker build --platform linux/amd64 -t $ECR_REPO:$IMAGE_TAG .

# 或 ARM64 (M1/M2 Mac):
docker build -t $ECR_REPO:$IMAGE_TAG .

# 4. 推送映像
docker tag $ECR_REPO:$IMAGE_TAG $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG
```

### 步驟 3：準備 Task Definition

編輯 `backend/task-definition.json`：

```json
{
  "family": "doublespot-backend",
  "executionRoleArn": "arn:aws:iam::YOUR_ACCOUNT_ID:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::YOUR_ACCOUNT_ID:role/ecsTaskRole",
  "containerDefinitions": [{
    "image": "YOUR_ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/REPO:TAG",
    "environment": [
      {"name": "DB_HOST", "value": "YOUR_RDS_ENDPOINT"},
      {"name": "DB_USER", "value": "admin"},
      {"name": "DB_PASSWORD", "value": "YOUR_PASSWORD"},
      {"name": "DB_NAME", "value": "doublespot"}
    ]
  }]
}
```

註冊 Task Definition：
```bash
aws ecs register-task-definition --region $REGION --cli-input-json file://task-definition.json
```

### 步驟 4：部署 ECS Service

```bash
# 確保已載入配置
source infrastructure-config.env

# 運行部署腳本
./scripts/deploy-ecs-service.sh
```

腳本會自動：
- ✅ 檢查 Service 是否存在
- ✅ 創建或更新 Service
- ✅ 監控部署狀態
- ✅ 檢查健康狀態
- ✅ 測試 ALB 端點

### 步驟 5：設置 GitHub Actions（可選）

```bash
# 確保已載入配置
source infrastructure-config.env

# 運行 GitHub Actions 設置腳本
./scripts/setup-github-actions.sh
```

腳本會自動：
- ✅ 創建 OIDC Identity Provider
- ✅ 創建 IAM Policy（ECR + ECS 權限）
- ✅ 創建 IAM Role（信任 GitHub Actions）
- ✅ 生成 GitHub Variables 配置清單
- ✅ 保存配置到 `infrastructure-config.env`

**完成後**：
1. 複製腳本輸出的 Variables 到 GitHub Repository Settings
2. 推送代碼到 main 分支測試自動部署

詳細說明請參考 [GITHUB_ACTIONS_SETUP.md](../GITHUB_ACTIONS_SETUP.md)

---

## 🔧 腳本詳細說明

### setup-aws-infrastructure.sh

**功能**：
- 自動創建所有必要的 AWS 資源
- 智能檢測已存在的資源（不會重複創建）
- 生成配置文件供後續使用

**選項**：
- 互動式配置（項目名稱、環境、Region）
- 可選擇是否創建 RDS
- 自動驗證 VPC 和 Security Groups

**輸出**：
- 在終端顯示創建進度
- 生成 `infrastructure-config.env` 配置文件

**使用範例**：
```bash
# 使用默認配置
./scripts/setup-aws-infrastructure.sh
# 輸入 Y 確認默認配置

# 自定義配置
./scripts/setup-aws-infrastructure.sh
# 輸入 N，然後自定義項目名稱、環境等
```

### deploy-ecs-service.sh

**功能**：
- 自動創建或更新 ECS Service
- 監控部署狀態（最多 10 分鐘）
- 檢查 Target Group 健康狀態
- 測試 ALB 端點

**前置需求**：
- 已運行 `setup-aws-infrastructure.sh`
- 已載入 `infrastructure-config.env`
- Task Definition 已註冊

**首次運行**：
- 創建新的 ECS Service
- 配置 Load Balancer 關聯
- 設置 `minimumHealthyPercent=0`（首次部署需要）

**後續運行**：
- 更新現有 Service
- 觸發新的部署
- 使用 `force-new-deployment`

**使用範例**：
```bash
# 首次部署
source infrastructure-config.env
./scripts/deploy-ecs-service.sh

# 更新部署（推送新映像後）
./scripts/deploy-ecs-service.sh
```

---

## 📝 配置文件說明

### infrastructure-config.env

自動生成的配置文件，包含所有資源的 ID 和 ARN。

**使用方式**：
```bash
# 載入配置
source infrastructure-config.env

# 之後可以直接使用變數
echo $CLUSTER_NAME
echo $ALB_DNS
```

**包含的變數**：
- `REGION` - AWS Region
- `ACCOUNT_ID` - AWS Account ID
- `VPC_ID` - VPC ID
- `CLUSTER_NAME` - ECS Cluster 名稱
- `ECR_URI` - ECR Repository URI
- `ALB_DNS` - ALB DNS 名稱
- 等等...

---

## 🔍 監控和診斷

### 查看服務狀態
```bash
source infrastructure-config.env

aws ecs describe-services \
  --region $REGION \
  --cluster $CLUSTER_NAME \
  --services $SERVICE_NAME \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}'
```

### 查看日誌
```bash
aws logs tail $LOG_GROUP --region $REGION --follow
```

### 查看健康狀態
```bash
aws elbv2 describe-target-health \
  --region $REGION \
  --target-group-arn $TG_ARN
```

### 測試端點
```bash
curl http://$ALB_DNS/health
```

---

## 🐛 故障排查

### 問題：腳本執行權限錯誤
```bash
chmod +x scripts/*.sh
```

### 問題：找不到配置文件
```bash
# 確保在項目根目錄運行
source infrastructure-config.env

# 如果文件不存在，重新運行設置腳本
./scripts/setup-aws-infrastructure.sh
```

### 問題：VPC 不存在
```
錯誤：VPC 'doublespot-test-vpc' 不存在
```

**解決**：
1. 檢查 VPC 名稱是否正確
2. 確保 VPC 已創建（參考 SETUP_GUIDE.md）
3. 修改腳本中的 VPC 名稱格式

### 問題：RDS 創建失敗
```
錯誤：密碼必須至少 8 個字符
```

**解決**：
- 使用更強的密碼（至少 8 個字符）
- 包含大小寫字母、數字和特殊字符

### 問題：ECS Service 無法啟動
```
runningCount: 0
```

**檢查清單**：
1. Task Definition 是否已註冊？
2. 映像是否已推送到 ECR？
3. 映像架構是否匹配？（AMD64 vs ARM64）
4. 查看日誌：`aws logs tail $LOG_GROUP --region $REGION`

---

## 💡 最佳實踐

1. **配置管理**
   - 將 `infrastructure-config.env` 加入 `.gitignore`
   - 不要在 Git 中提交敏感信息

2. **腳本執行**
   - 在項目根目錄執行腳本
   - 始終先載入配置：`source infrastructure-config.env`

3. **資源清理**
   - 測試環境可以手動刪除資源
   - 生產環境建議使用 Terraform 或 CloudFormation

4. **成本優化**
   - 測試完成後停止 RDS 實例
   - 使用 ARM64 架構節省約 20% 成本
   - 考慮使用 Spot Instances（需修改腳本）

---

## 🔗 相關文檔

- [AWS_CHEAT_SHEET.md](../AWS_CHEAT_SHEET.md) - 命令快速參考
- [NEXT_STEPS.md](../NEXT_STEPS.md) - 完整部署指南
- [SETUP_GUIDE.md](../SETUP_GUIDE.md) - VPC 和網絡設置

---

## 🤝 貢獻

如果發現問題或有改進建議，歡迎提交 Issue 或 Pull Request。

---

**⚠️ 注意**：這些腳本適用於開發和測試環境。生產環境建議使用 IaC 工具（如 Terraform、CloudFormation）來管理基礎設施。

