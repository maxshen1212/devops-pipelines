#!/bin/bash

###############################################################################
# Deploy ECS Service Script
# 部署或更新 ECS Service
###############################################################################

set -e

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 檢查是否已載入配置
if [ -z "$CLUSTER_NAME" ]; then
    if [ -f "infrastructure-config.env" ]; then
        source infrastructure-config.env
        echo -e "${GREEN}✅ 已載入配置文件${NC}"
    else
        echo -e "${RED}❌ 找不到配置文件，請先運行 setup-aws-infrastructure.sh${NC}"
        exit 1
    fi
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}ECS Service Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo "  Cluster: $CLUSTER_NAME"
echo "  Service: $SERVICE_NAME"
echo "  Region: $REGION"
echo -e "${BLUE}========================================${NC}\n"

###############################################################################
# 檢查 Service 是否存在
###############################################################################

SERVICE_EXISTS=$(aws ecs describe-services \
    --region $REGION \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --query 'services[0].serviceName' \
    --output text 2>/dev/null || echo "None")

if [ "$SERVICE_EXISTS" == "None" ] || [ -z "$SERVICE_EXISTS" ]; then
    echo -e "${YELLOW}📝 Service 不存在，開始創建...${NC}\n"
    CREATE_SERVICE=true
else
    echo -e "${YELLOW}📝 Service 已存在，將進行更新...${NC}\n"
    CREATE_SERVICE=false
fi

###############################################################################
# 創建 ECS Service
###############################################################################

if [ "$CREATE_SERVICE" = true ]; then
    echo -e "${BLUE}▶ 創建 ECS Service${NC}"

    # 獲取最新的 Task Definition
    TASK_DEF_ARN=$(aws ecs describe-task-definition \
        --region $REGION \
        --task-definition doublespot-backend \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)

    if [ -z "$TASK_DEF_ARN" ]; then
        echo -e "${RED}❌ Task Definition 不存在，請先註冊 Task Definition${NC}"
        echo "  運行: aws ecs register-task-definition --region $REGION --cli-input-json file://backend/task-definition.json"
        exit 1
    fi

    echo "  使用 Task Definition: $TASK_DEF_ARN"

    # 創建 Service
    aws ecs create-service \
        --region $REGION \
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition doublespot-backend \
        --desired-count 1 \
        --launch-type FARGATE \
        --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" \
        --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}" \
        --load-balancers "targetGroupArn=$TG_ARN,containerName=backend,containerPort=3000" \
        --health-check-grace-period-seconds 60 \
        --tags "key=Environment,value=$ENVIRONMENT"

    echo -e "${GREEN}✅ Service 已創建${NC}\n"
else
    ###########################################################################
    # 更新 ECS Service
    ###########################################################################

    echo -e "${BLUE}▶ 更新 ECS Service${NC}"

    aws ecs update-service \
        --region $REGION \
        --cluster $CLUSTER_NAME \
        --service $SERVICE_NAME \
        --force-new-deployment

    echo -e "${GREEN}✅ Service 更新已觸發${NC}\n"
fi

###############################################################################
# 監控部署狀態
###############################################################################

echo -e "${BLUE}▶ 監控部署狀態...${NC}\n"

# 等待一下讓 Service 開始更新
sleep 5

for i in {1..60}; do
    STATUS=$(aws ecs describe-services \
        --region $REGION \
        --cluster $CLUSTER_NAME \
        --services $SERVICE_NAME \
        --query 'services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount}' \
        --output json)

    RUNNING=$(echo $STATUS | jq -r '.Running')
    DESIRED=$(echo $STATUS | jq -r '.Desired')
    PENDING=$(echo $STATUS | jq -r '.Pending')

    echo -e "  [$i/60] Running: $RUNNING/$DESIRED, Pending: $PENDING"

    if [ "$RUNNING" -eq "$DESIRED" ] && [ "$PENDING" -eq 0 ]; then
        echo -e "\n${GREEN}✅ 部署成功！${NC}"
        break
    fi

    if [ $i -eq 60 ]; then
        echo -e "\n${YELLOW}⚠️  部署時間過長，請檢查日誌${NC}"
        echo "  查看日誌: aws logs tail $LOG_GROUP --region $REGION --follow"
    fi

    sleep 10
done

###############################################################################
# 檢查健康狀態
###############################################################################

echo -e "\n${BLUE}▶ 檢查 Target Group 健康狀態...${NC}\n"

sleep 10  # 等待健康檢查

TARGET_HEALTH=$(aws elbv2 describe-target-health \
    --region $REGION \
    --target-group-arn $TG_ARN \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text)

echo "  狀態: $TARGET_HEALTH"

if [ "$TARGET_HEALTH" == "healthy" ]; then
    echo -e "${GREEN}✅ 健康檢查通過${NC}"
elif [ "$TARGET_HEALTH" == "initial" ]; then
    echo -e "${YELLOW}⏳ 正在進行初始健康檢查...${NC}"
    echo "  等待約 30-60 秒後再次檢查"
else
    echo -e "${RED}❌ 健康檢查失敗${NC}"
    echo "  檢查日誌: aws logs tail $LOG_GROUP --region $REGION --follow"
fi

###############################################################################
# 測試端點
###############################################################################

echo -e "\n${BLUE}▶ 測試 ALB 端點...${NC}\n"

echo "  ALB URL: http://$ALB_DNS"
echo "  測試健康檢查: curl http://$ALB_DNS/health"

if command -v curl &> /dev/null; then
    echo -e "\n  執行測試..."
    curl -s -o /dev/null -w "  HTTP Status: %{http_code}\n" http://$ALB_DNS/health || true
fi

###############################################################################
# 總結
###############################################################################

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}部署完成！${NC}"
echo -e "${GREEN}========================================${NC}\n"

echo -e "${BLUE}📝 資源信息：${NC}"
echo "  Cluster: $CLUSTER_NAME"
echo "  Service: $SERVICE_NAME"
echo "  ALB DNS: $ALB_DNS"
echo "  Health Check: http://$ALB_DNS/health"

echo -e "\n${BLUE}🔍 監控命令：${NC}"
echo "  查看服務狀態:"
echo "    aws ecs describe-services --region $REGION --cluster $CLUSTER_NAME --services $SERVICE_NAME"
echo ""
echo "  查看日誌:"
echo "    aws logs tail $LOG_GROUP --region $REGION --follow"
echo ""
echo "  查看健康狀態:"
echo "    aws elbv2 describe-target-health --region $REGION --target-group-arn $TG_ARN"

echo -e "\n${GREEN}🎉 完成！${NC}\n"

