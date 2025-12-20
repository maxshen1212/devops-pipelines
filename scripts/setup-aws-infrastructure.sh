#!/bin/bash

###############################################################################
# AWS ECS Infrastructure Setup Script
# 使用 AWS CLI 自動創建所有必要的基礎設施
###############################################################################

set -e  # 遇到錯誤立即退出

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置變數
PROJECT_NAME="doublespot"
ENVIRONMENT="test"
REGION="us-west-2"

# 詢問用戶是否要使用默認配置
read -p "使用默認配置? (Project: $PROJECT_NAME, Env: $ENVIRONMENT, Region: $REGION) [Y/n]: " use_default

if [[ $use_default =~ ^[Nn]$ ]]; then
    read -p "輸入項目名稱 [$PROJECT_NAME]: " input_project
    PROJECT_NAME=${input_project:-$PROJECT_NAME}

    read -p "輸入環境名稱 [$ENVIRONMENT]: " input_env
    ENVIRONMENT=${input_env:-$ENVIRONMENT}

    read -p "輸入 AWS Region [$REGION]: " input_region
    REGION=${input_region:-$REGION}
fi

# 獲取 AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AWS Infrastructure Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Project: ${GREEN}$PROJECT_NAME${NC}"
echo -e "Environment: ${GREEN}$ENVIRONMENT${NC}"
echo -e "Region: ${GREEN}$REGION${NC}"
echo -e "Account ID: ${GREEN}$ACCOUNT_ID${NC}"
echo -e "${BLUE}========================================${NC}\n"

# 資源命名
VPC_NAME="${PROJECT_NAME}-${ENVIRONMENT}-vpc"
CLUSTER_NAME="${PROJECT_NAME}-cluster"
SERVICE_NAME="backend-service"
ECR_REPO="${PROJECT_NAME}-backend"
ALB_NAME="${PROJECT_NAME}-${ENVIRONMENT}-alb"
TG_NAME="${PROJECT_NAME}-backend-tg"
LOG_GROUP="/ecs/${PROJECT_NAME}-backend"

# RDS 配置
DB_INSTANCE_ID="${PROJECT_NAME}-${ENVIRONMENT}-mysql"
DB_NAME="${PROJECT_NAME}"
DB_USERNAME="admin"

# 詢問是否創建 RDS
read -p "是否創建 RDS MySQL 實例? [y/N]: " create_rds

if [[ $create_rds =~ ^[Yy]$ ]]; then
    read -s -p "輸入 RDS master password (最少 8 個字符): " DB_PASSWORD
    echo
    if [ ${#DB_PASSWORD} -lt 8 ]; then
        echo -e "${RED}❌ 密碼必須至少 8 個字符${NC}"
        exit 1
    fi
fi

###############################################################################
# 輔助函數
###############################################################################

print_step() {
    echo -e "\n${BLUE}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# 檢查資源是否存在
resource_exists() {
    local resource_type=$1
    local identifier=$2

    case $resource_type in
        vpc)
            aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=$identifier" --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep -v "None"
            ;;
        ecr)
            aws ecr describe-repositories --region $REGION --repository-names $identifier --query 'repositories[0].repositoryName' --output text 2>/dev/null
            ;;
        ecs-cluster)
            aws ecs describe-clusters --region $REGION --clusters $identifier --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -v "MISSING"
            ;;
        log-group)
            aws logs describe-log-groups --region $REGION --log-group-name-prefix $identifier --query 'logGroups[0].logGroupName' --output text 2>/dev/null
            ;;
    esac
}

###############################################################################
# 1. 檢查 VPC 和網絡（假設已存在）
###############################################################################

print_step "1. 檢查 VPC 和網絡配置"

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query 'Vpcs[0].VpcId' --output text)

if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
    print_error "VPC '$VPC_NAME' 不存在。請先創建 VPC 和網絡資源。"
    echo "參考: SETUP_GUIDE.md 的 VPC 設置部分"
    exit 1
fi

print_success "VPC 已存在: $VPC_ID"

# 獲取 Subnets
PRIVATE_SUBNET_1=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}-private-${REGION}a" \
    --query 'Subnets[0].SubnetId' --output text)

PRIVATE_SUBNET_2=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}-private-${REGION}b" \
    --query 'Subnets[0].SubnetId' --output text)

PUBLIC_SUBNET_1=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}-public-${REGION}a" \
    --query 'Subnets[0].SubnetId' --output text)

PUBLIC_SUBNET_2=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}-public-${REGION}b" \
    --query 'Subnets[0].SubnetId' --output text)

if [ "$PRIVATE_SUBNET_1" == "None" ] || [ "$PRIVATE_SUBNET_2" == "None" ]; then
    print_error "Private subnets 不存在"
    exit 1
fi

print_success "Subnets 已找到"
echo "  Private: $PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2"
echo "  Public: $PUBLIC_SUBNET_1, $PUBLIC_SUBNET_2"

# 獲取 Security Groups
ALB_SG=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-${ENVIRONMENT}-alb-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)

ECS_SG=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-${ENVIRONMENT}-ecs-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)

RDS_SG=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-${ENVIRONMENT}-rds-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)

if [ "$ALB_SG" == "None" ] || [ "$ECS_SG" == "None" ]; then
    print_error "Security Groups 不存在"
    exit 1
fi

print_success "Security Groups 已找到"
echo "  ALB SG: $ALB_SG"
echo "  ECS SG: $ECS_SG"
echo "  RDS SG: $RDS_SG"

###############################################################################
# 2. 創建 RDS (可選)
###############################################################################

if [[ $create_rds =~ ^[Yy]$ ]]; then
    print_step "2. 創建 RDS MySQL 實例"

    # 創建 DB Subnet Group
    DB_SUBNET_GROUP="${PROJECT_NAME}-${ENVIRONMENT}-db-subnet-group"

    if aws rds describe-db-subnet-groups --region $REGION --db-subnet-group-name $DB_SUBNET_GROUP &>/dev/null; then
        print_warning "DB Subnet Group 已存在: $DB_SUBNET_GROUP"
    else
        aws rds create-db-subnet-group \
            --region $REGION \
            --db-subnet-group-name $DB_SUBNET_GROUP \
            --db-subnet-group-description "DB subnet group for $PROJECT_NAME" \
            --subnet-ids $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2 \
            --tags "Key=Name,Value=$DB_SUBNET_GROUP" "Key=Environment,Value=$ENVIRONMENT"

        print_success "DB Subnet Group 已創建: $DB_SUBNET_GROUP"
    fi

    # 創建 RDS 實例
    if aws rds describe-db-instances --region $REGION --db-instance-identifier $DB_INSTANCE_ID &>/dev/null; then
        print_warning "RDS 實例已存在: $DB_INSTANCE_ID"
    else
        aws rds create-db-instance \
            --region $REGION \
            --db-instance-identifier $DB_INSTANCE_ID \
            --db-instance-class db.t3.micro \
            --engine mysql \
            --engine-version 8.0.43 \
            --master-username $DB_USERNAME \
            --master-user-password "$DB_PASSWORD" \
            --allocated-storage 20 \
            --storage-type gp3 \
            --db-subnet-group-name $DB_SUBNET_GROUP \
            --vpc-security-group-ids $RDS_SG \
            --db-name $DB_NAME \
            --backup-retention-period 7 \
            --no-publicly-accessible \
            --tags "Key=Name,Value=$DB_INSTANCE_ID" "Key=Environment,Value=$ENVIRONMENT"

        print_success "RDS 實例創建中: $DB_INSTANCE_ID (需要 5-10 分鐘)"
        echo "  稍後可以使用以下命令檢查狀態:"
        echo "  aws rds describe-db-instances --region $REGION --db-instance-identifier $DB_INSTANCE_ID --query 'DBInstances[0].DBInstanceStatus'"
    fi
else
    print_warning "跳過 RDS 創建"
fi

###############################################################################
# 3. 創建 IAM Roles
###############################################################################

print_step "3. 創建 IAM Roles"

# ECS Task Execution Role
if aws iam get-role --role-name ecsTaskExecutionRole &>/dev/null; then
    print_warning "ecsTaskExecutionRole 已存在"
else
    # 創建信任策略
    cat > /tmp/ecs-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    aws iam create-role \
        --role-name ecsTaskExecutionRole \
        --assume-role-policy-document file:///tmp/ecs-trust-policy.json \
        --description "ECS Task Execution Role for $PROJECT_NAME"

    aws iam attach-role-policy \
        --role-name ecsTaskExecutionRole \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

    print_success "ecsTaskExecutionRole 已創建"
    rm /tmp/ecs-trust-policy.json
fi

# ECS Task Role
if aws iam get-role --role-name ecsTaskRole &>/dev/null; then
    print_warning "ecsTaskRole 已存在"
else
    aws iam create-role \
        --role-name ecsTaskRole \
        --assume-role-policy-document file:///tmp/ecs-trust-policy.json \
        --description "ECS Task Role for $PROJECT_NAME"

    print_success "ecsTaskRole 已創建"
fi

###############################################################################
# 4. 創建 ECR Repository
###############################################################################

print_step "4. 創建 ECR Repository"

if resource_exists ecr $ECR_REPO &>/dev/null; then
    print_warning "ECR Repository 已存在: $ECR_REPO"
else
    aws ecr create-repository \
        --region $REGION \
        --repository-name $ECR_REPO \
        --image-tag-mutability MUTABLE \
        --tags "Key=Name,Value=$ECR_REPO" "Key=Environment,Value=$ENVIRONMENT"

    print_success "ECR Repository 已創建: $ECR_REPO"
fi

ECR_URI=$(aws ecr describe-repositories --region $REGION \
    --repository-names $ECR_REPO \
    --query 'repositories[0].repositoryUri' --output text)
echo "  URI: $ECR_URI"

###############################################################################
# 5. 創建 CloudWatch Log Group
###############################################################################

print_step "5. 創建 CloudWatch Log Group"

if resource_exists log-group $LOG_GROUP &>/dev/null; then
    print_warning "Log Group 已存在: $LOG_GROUP"
else
    aws logs create-log-group \
        --region $REGION \
        --log-group-name $LOG_GROUP

    aws logs put-retention-policy \
        --region $REGION \
        --log-group-name $LOG_GROUP \
        --retention-in-days 7

    print_success "Log Group 已創建: $LOG_GROUP"
fi

###############################################################################
# 6. 創建 ECS Cluster
###############################################################################

print_step "6. 創建 ECS Cluster"

if resource_exists ecs-cluster $CLUSTER_NAME &>/dev/null; then
    print_warning "ECS Cluster 已存在: $CLUSTER_NAME"
else
    aws ecs create-cluster \
        --region $REGION \
        --cluster-name $CLUSTER_NAME \
        --tags "key=Name,value=$CLUSTER_NAME" "key=Environment,value=$ENVIRONMENT"

    print_success "ECS Cluster 已創建: $CLUSTER_NAME"
fi

###############################################################################
# 7. 創建 Application Load Balancer
###############################################################################

print_step "7. 創建 Application Load Balancer"

# 檢查 ALB 是否存在
ALB_ARN=$(aws elbv2 describe-load-balancers --region $REGION \
    --names $ALB_NAME \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")

if [ "$ALB_ARN" != "None" ] && [ -n "$ALB_ARN" ]; then
    print_warning "ALB 已存在: $ALB_NAME"
else
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --region $REGION \
        --name $ALB_NAME \
        --subnets $PUBLIC_SUBNET_1 $PUBLIC_SUBNET_2 \
        --security-groups $ALB_SG \
        --scheme internet-facing \
        --type application \
        --ip-address-type ipv4 \
        --tags "Key=Name,Value=$ALB_NAME" "Key=Environment,Value=$ENVIRONMENT" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)

    print_success "ALB 已創建: $ALB_NAME"
fi

echo "  ALB ARN: $ALB_ARN"

# 獲取 ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers --region $REGION \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].DNSName' --output text)
echo "  ALB DNS: $ALB_DNS"

###############################################################################
# 8. 創建 Target Group
###############################################################################

print_step "8. 創建 Target Group"

TG_ARN=$(aws elbv2 describe-target-groups --region $REGION \
    --names $TG_NAME \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")

if [ "$TG_ARN" != "None" ] && [ -n "$TG_ARN" ]; then
    print_warning "Target Group 已存在: $TG_NAME"
else
    TG_ARN=$(aws elbv2 create-target-group \
        --region $REGION \
        --name $TG_NAME \
        --protocol HTTP \
        --port 3000 \
        --vpc-id $VPC_ID \
        --target-type ip \
        --health-check-enabled \
        --health-check-protocol HTTP \
        --health-check-path /health \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --tags "Key=Name,Value=$TG_NAME" "Key=Environment,Value=$ENVIRONMENT" \
        --query 'TargetGroups[0].TargetGroupArn' --output text)

    print_success "Target Group 已創建: $TG_NAME"
fi

echo "  TG ARN: $TG_ARN"

###############################################################################
# 9. 創建 ALB Listener
###############################################################################

print_step "9. 創建 ALB Listener"

LISTENER_ARN=$(aws elbv2 describe-listeners --region $REGION \
    --load-balancer-arn $ALB_ARN \
    --query 'Listeners[?Port==`80`].ListenerArn' --output text 2>/dev/null)

if [ -n "$LISTENER_ARN" ]; then
    print_warning "Listener 已存在"
else
    aws elbv2 create-listener \
        --region $REGION \
        --load-balancer-arn $ALB_ARN \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn=$TG_ARN

    print_success "Listener 已創建"
fi

###############################################################################
# 10. 總結
###############################################################################

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Infrastructure Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}\n"

echo -e "${BLUE}📝 資源總結：${NC}"
echo "  Region: $REGION"
echo "  Account ID: $ACCOUNT_ID"
echo "  VPC ID: $VPC_ID"
echo "  ECS Cluster: $CLUSTER_NAME"
echo "  ECR Repository: $ECR_URI"
echo "  ALB DNS: $ALB_DNS"
echo "  Target Group: $TG_NAME"
echo "  Log Group: $LOG_GROUP"

if [[ $create_rds =~ ^[Yy]$ ]]; then
    echo "  RDS Instance: $DB_INSTANCE_ID (創建中...)"
    echo "    檢查狀態: aws rds describe-db-instances --region $REGION --db-instance-identifier $DB_INSTANCE_ID"
fi

echo -e "\n${YELLOW}⚠️  下一步：${NC}"
echo "1. 等待 RDS 實例創建完成 (如果有創建)"
echo "2. 獲取 RDS endpoint:"
echo "   RDS_ENDPOINT=\$(aws rds describe-db-instances --region $REGION --db-instance-identifier $DB_INSTANCE_ID --query 'DBInstances[0].Endpoint.Address' --output text)"
echo "3. 更新 backend/task-definition.json 配置"
echo "4. 構建並推送 Docker 映像到 ECR"
echo "5. 註冊 Task Definition"
echo "6. 創建 ECS Service"

echo -e "\n${BLUE}📖 詳細步驟請參考：${NC}"
echo "  - AWS_CHEAT_SHEET.md (快速命令)"
echo "  - NEXT_STEPS.md (完整指南)"

# 保存配置到文件
cat > infrastructure-config.env <<EOF
# AWS Infrastructure Configuration
# Generated on $(date)

export REGION="$REGION"
export ACCOUNT_ID="$ACCOUNT_ID"
export PROJECT_NAME="$PROJECT_NAME"
export ENVIRONMENT="$ENVIRONMENT"

# Network
export VPC_ID="$VPC_ID"
export PRIVATE_SUBNET_1="$PRIVATE_SUBNET_1"
export PRIVATE_SUBNET_2="$PRIVATE_SUBNET_2"
export PUBLIC_SUBNET_1="$PUBLIC_SUBNET_1"
export PUBLIC_SUBNET_2="$PUBLIC_SUBNET_2"

# Security Groups
export ALB_SG="$ALB_SG"
export ECS_SG="$ECS_SG"
export RDS_SG="$RDS_SG"

# ECS
export CLUSTER_NAME="$CLUSTER_NAME"
export SERVICE_NAME="$SERVICE_NAME"
export ECR_REPO="$ECR_REPO"
export ECR_URI="$ECR_URI"
export LOG_GROUP="$LOG_GROUP"

# Load Balancer
export ALB_NAME="$ALB_NAME"
export ALB_ARN="$ALB_ARN"
export ALB_DNS="$ALB_DNS"
export TG_NAME="$TG_NAME"
export TG_ARN="$TG_ARN"

# RDS (if created)
export DB_INSTANCE_ID="$DB_INSTANCE_ID"
export DB_NAME="$DB_NAME"
export DB_USERNAME="$DB_USERNAME"
EOF

print_success "配置已保存到: infrastructure-config.env"
echo "  使用方式: source infrastructure-config.env"

echo -e "\n${GREEN}🎉 完成！${NC}\n"

