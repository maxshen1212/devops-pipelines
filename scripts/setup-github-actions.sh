#!/bin/bash

###############################################################################
# GitHub Actions Setup Script
# 自動創建 OIDC Provider、IAM Role 和策略
###############################################################################

set -e

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}GitHub Actions Setup${NC}"
echo -e "${BLUE}========================================${NC}\n"

# 載入配置
if [ -f "infrastructure-config.env" ]; then
    source infrastructure-config.env
    echo -e "${GREEN}✅ 已載入配置文件${NC}\n"
else
    echo -e "${RED}❌ 找不到 infrastructure-config.env${NC}"
    echo "請先運行: ./scripts/setup-aws-infrastructure.sh"
    exit 1
fi

# 獲取 GitHub 信息
read -p "輸入您的 GitHub 用戶名或組織名: " GITHUB_USERNAME
read -p "輸入 Repository 名稱 [devops-piplines]: " GITHUB_REPO
GITHUB_REPO=${GITHUB_REPO:-devops-piplines}

echo ""
read -p "是否只允許 main 分支部署? [Y/n]: " RESTRICT_BRANCH
RESTRICT_BRANCH=${RESTRICT_BRANCH:-Y}

echo -e "\n${BLUE}配置信息：${NC}"
echo "  GitHub: $GITHUB_USERNAME/$GITHUB_REPO"
echo "  AWS Account: $ACCOUNT_ID"
echo "  Region: $REGION"
if [[ $RESTRICT_BRANCH =~ ^[Yy]$ ]]; then
    echo "  Branch Restriction: ✅ 僅 main 分支"
else
    echo "  Branch Restriction: ⚠️  所有分支"
fi

echo ""
read -p "確認繼續? [Y/n]: " CONFIRM
if [[ $CONFIRM =~ ^[Nn]$ ]]; then
    echo "已取消"
    exit 0
fi

###############################################################################
# 1. 創建 OIDC Provider
###############################################################################

echo -e "\n${BLUE}▶ 1. 檢查/創建 OIDC Provider${NC}"

OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn $OIDC_PROVIDER_ARN &>/dev/null; then
    echo -e "${YELLOW}⚠️  OIDC Provider 已存在${NC}"
else
    # 獲取 thumbprint
    THUMBPRINT=$(echo | openssl s_client -servername token.actions.githubusercontent.com -showcerts -connect token.actions.githubusercontent.com:443 2>/dev/null | openssl x509 -fingerprint -noout | cut -d'=' -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    if [ -z "$THUMBPRINT" ]; then
        # 備用 thumbprint（GitHub 的固定值）
        THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"
        echo -e "${YELLOW}⚠️  使用預設 thumbprint${NC}"
    fi

    aws iam create-open-id-connect-provider \
        --url https://token.actions.githubusercontent.com \
        --client-id-list sts.amazonaws.com \
        --thumbprint-list $THUMBPRINT

    echo -e "${GREEN}✅ OIDC Provider 已創建${NC}"
fi

echo "  ARN: $OIDC_PROVIDER_ARN"

###############################################################################
# 2. 創建 IAM Policy
###############################################################################

echo -e "\n${BLUE}▶ 2. 創建 IAM Policy${NC}"

POLICY_NAME="GitHubActionsDeployPolicy"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

# 檢查策略是否存在
if aws iam get-policy --policy-arn $POLICY_ARN &>/dev/null; then
    echo -e "${YELLOW}⚠️  Policy 已存在: $POLICY_NAME${NC}"
    echo "  如需更新策略，請手動刪除後重新運行此腳本"
else
    # 創建策略文件
    cat > /tmp/github-actions-policy.json <<EOF
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

    POLICY_ARN=$(aws iam create-policy \
        --policy-name $POLICY_NAME \
        --policy-document file:///tmp/github-actions-policy.json \
        --description "Policy for GitHub Actions to deploy to ECS" \
        --query 'Policy.Arn' \
        --output text)

    echo -e "${GREEN}✅ Policy 已創建${NC}"
    rm /tmp/github-actions-policy.json
fi

echo "  ARN: $POLICY_ARN"

###############################################################################
# 3. 創建 IAM Role
###############################################################################

echo -e "\n${BLUE}▶ 3. 創建 IAM Role${NC}"

ROLE_NAME="github-actions-deploy-role"

# 檢查 Role 是否存在
if aws iam get-role --role-name $ROLE_NAME &>/dev/null; then
    echo -e "${YELLOW}⚠️  Role 已存在: $ROLE_NAME${NC}"
    ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)
else
    # 創建 Trust Policy
    if [[ $RESTRICT_BRANCH =~ ^[Yy]$ ]]; then
        # 限制僅 main 分支
        cat > /tmp/github-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
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
    else
        # 允許所有分支
        cat > /tmp/github-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
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
    fi

    ROLE_ARN=$(aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file:///tmp/github-trust-policy.json \
        --description "Role for GitHub Actions to deploy to ECS" \
        --query 'Role.Arn' \
        --output text)

    echo -e "${GREEN}✅ Role 已創建${NC}"
    rm /tmp/github-trust-policy.json

    # 附加策略
    aws iam attach-role-policy \
        --role-name $ROLE_NAME \
        --policy-arn $POLICY_ARN

    echo -e "${GREEN}✅ Policy 已附加到 Role${NC}"
fi

echo "  ARN: $ROLE_ARN"

###############################################################################
# 4. 保存配置
###############################################################################

echo -e "\n${BLUE}▶ 4. 保存配置${NC}"

# 添加到配置文件
if ! grep -q "AWS_ROLE_TO_ASSUME" infrastructure-config.env; then
    cat >> infrastructure-config.env <<EOF

# GitHub Actions
export GITHUB_USERNAME="$GITHUB_USERNAME"
export GITHUB_REPO="$GITHUB_REPO"
export AWS_ROLE_TO_ASSUME="$ROLE_ARN"
export CONTAINER_NAME="backend"
EOF
    echo -e "${GREEN}✅ 配置已保存到 infrastructure-config.env${NC}"
fi

###############################################################################
# 5. 生成 GitHub Variables
###############################################################################

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}\n"

echo -e "${BLUE}📝 下一步：在 GitHub Repository 中配置以下 Variables${NC}\n"
echo "前往: https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}/settings/variables/actions"
echo ""
echo -e "${YELLOW}點擊 'New repository variable' 並添加以下變數：${NC}\n"

cat <<EOF
╔════════════════════════╦════════════════════════════════════════════════════════╗
║ Variable Name          ║ Value                                                  ║
╠════════════════════════╬════════════════════════════════════════════════════════╣
║ AWS_REGION             ║ $REGION
║ AWS_ROLE_TO_ASSUME     ║ $ROLE_ARN
║ ECR_REPOSITORY         ║ $ECR_REPO
║ ECS_CLUSTER            ║ $CLUSTER_NAME
║ ECS_SERVICE            ║ $SERVICE_NAME
║ CONTAINER_NAME         ║ backend
╚════════════════════════╩════════════════════════════════════════════════════════╝
EOF

echo -e "\n${BLUE}💡 提示：${NC}"
echo "1. 複製上面的值到 GitHub Variables"
echo "2. 提交代碼變更到 main 分支測試自動部署"
echo "3. 在 GitHub Actions 頁面查看執行結果"

echo -e "\n${BLUE}🧪 測試部署：${NC}"
echo "  cd backend"
echo "  echo '# Test' >> README.md"
echo "  git add README.md"
echo "  git commit -m 'test: trigger GitHub Actions'"
echo "  git push origin main"

echo -e "\n${GREEN}🎉 完成！${NC}\n"

