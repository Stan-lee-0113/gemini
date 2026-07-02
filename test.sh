#!/bin/bash
# 优化的 GCP Vertex AI 密钥管理工具 (独立版 - 全自动单功能)
# 流程: 解绑所有项目结算 -> 创建3个无组织新项目 -> 绑定默认结算 -> 提取 Vertex AQ 密钥
# 版本: 3.0.0

set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="3.0.0"
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
NUM_PROJECTS="${NUM_PROJECTS:-3}"
TEMP_DIR=""

# Vertex模式配置
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"

# ===== 初始化 =====
TEMP_DIR=$(mktemp -d -t gcp_vertex_XXXXXX) || { echo "错误：无法创建临时目录"; exit 1; }
SECONDS=0

# ===== 日志与错误处理 =====
log() { 
    local level="${1:-INFO}"
    local msg="${2:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "INFO")     echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" ;;
        "SUCCESS")  echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" ;;
        "WARN")     echo -e "${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" >&2 ;;
        "ERROR")    echo -e "${RED}[${timestamp}] [ERROR] ${msg}${NC}" >&2 ;;
    esac
}

handle_error() {
    local exit_code=$?
    case $exit_code in 141|130) return 0 ;; esac
    if [ $exit_code -gt 1 ]; then return $exit_code; else return 0; fi
}
trap 'handle_error' ERR

cleanup_resources() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR" 2>/dev/null || true; fi
    echo -e "\n${CYAN}喵酱期待下次为主人服务喵～${NC}"
}
trap cleanup_resources EXIT

# ===== 工具函数 =====
retry() {
    local max="$MAX_RETRY_ATTEMPTS"; local attempt=1; local delay
    while [ $attempt -le $max ]; do
        if "$@"; then return 0; fi
        if [ $attempt -ge $max ]; then return 1; fi
        delay=$(( attempt * 3 + RANDOM % 3 ))
        sleep $delay
        attempt=$((attempt + 1))
    done
}

require_cmd() { 
    if ! command -v "$1" &>/dev/null; then log "ERROR" "缺少依赖: $1"; exit 1; fi
}

unique_suffix() { 
    if command -v uuidgen &>/dev/null; then uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]'
    else echo "$(date +%s%N 2>/dev/null || date +%s)${RANDOM}" | sha256sum | cut -c1-6; fi
}

new_project_id() {
    local prefix="${1:-$PROJECT_PREFIX}"
    echo "${prefix}-$(unique_suffix)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30
}

check_env() {
    log "INFO" "检查环境配置..."
    require_cmd gcloud
    if ! gcloud config list account --quiet &>/dev/null; then log "ERROR" "请先运行 'gcloud init' 初始化"; exit 1; fi
    log "SUCCESS" "环境检查通过"
}

# ===== 解绑结算账户下的所有项目 (来自 fangfa.sh 的方法) =====
unlink_all_projects_from_billing() {
    local billing_id="$1"
    local linked_projects
    linked_projects=$(gcloud billing projects list --billing-account="$billing_id" --format='value(projectId)' 2>/dev/null)
    if [ -z "$linked_projects" ]; then
        log "INFO" "结算账户 ${billing_id} 下没有已绑定的项目，无需解绑喵。"
        return 0
    fi
    log "WARN" "开始解绑结算账户 ${billing_id} 下的所有项目，释放配额..."
    local count=0
    while IFS= read -r project_id; do
        [ -z "$project_id" ] && continue
        log "INFO" "正在解绑项目: ${project_id}"
        retry gcloud billing projects unlink "$project_id" --quiet &>/dev/null && count=$((count+1)) || true
    done <<< "$linked_projects"
    log "SUCCESS" "已解绑 ${count} 个项目喵！"
    return 0
}

enable_all_services() {
    local proj="$1"
    local services=(
        "aiplatform.googleapis.com"
        "generativelanguage.googleapis.com"
        "discoveryengine.googleapis.com"
        "iam.googleapis.com"
        "iamcredentials.googleapis.com"
        "cloudresourcemanager.googleapis.com"
        "apikeys.googleapis.com"
        "compute.googleapis.com"
    )
    log "INFO" "正在为项目 ${proj} 强力开通全部核心 API 权限..."
    for svc in "${services[@]}"; do
        retry gcloud services enable "$svc" --project="$proj" --quiet >/dev/null 2>&1 || true
    done
    log "INFO" "等待 API 权限在全局节点同步 (组织架构耗时较长)..."
    sleep 10
}

# ===== 核心：提取 AQ. 格式专属密钥 (带智能降级机制) =====
setup_and_extract_aq_key() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    
    # 1. 确保服务账号存在
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Agent SA" --project="$project_id" --quiet >/dev/null 2>&1 || true
        log "INFO" "等待服务账号在组织架构中生效..."
        sleep 10
    fi
    
    # 2. 赋予最高权限
    local roles=("roles/editor" "roles/aiplatform.admin" "roles/iam.serviceAccountUser")
    for role in "${roles[@]}"; do
        retry gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="$role" --quiet >/dev/null 2>&1 || true
    done
    sleep 5 # 给 IAM 同步一点时间

    # 3. 寻找已有 AQ. 格式密钥
    local keys_list
    keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    if [ -n "$keys_list" ]; then
        for key_name in $keys_list; do
            key_name=$(echo "$key_name" | tr -d '\r' | xargs)
            [ -z "$key_name" ] && continue
            local api_key
            api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
            if [[ "$api_key" == AQ.* ]]; then
                echo "$api_key"
                return 0
            fi
        done
    fi

    # 4. 强制生成 AQ 密钥并打印错误日志
    log "INFO" "正在请求生成 AQ. 格式专属密钥..."
    local attempt=1
    local create_success=false
    while [ $attempt -le 6 ]; do
        local create_err
        if create_err=$(gcloud beta services api-keys create --project="$project_id" --display-name="Agent Platform Key" --service-account="$sa_email" --quiet 2>&1); then
            create_success=true
            break
        fi
        
        # 提取报错信息的最后一行展示给主人
        local err_msg
        err_msg=$(echo "$create_err" | tail -n 1 | tr -d '\r')
        log "WARN" "接口未就绪或被拦截 ($attempt/6) -> 错误信息: $err_msg"
        
        # 如果是策略拦截，直接跳出重试不浪费时间
        if [[ "$err_msg" == *"Policy"* ]] || [[ "$err_msg" == *"PermissionDenied"* && "$attempt" -ge 4 ]]; then
            log "WARN" "检测到组织策略拦截或权限持续被拒，终止 AQ 密钥尝试喵。"
            break
        fi
        
        sleep 15
        attempt=$((attempt+1))
    done

    # B计划（降级方案）：如果 AQ 创建失败，生成普通的 AIza 密钥保底
    if [ "$create_success" = false ]; then
        log "WARN" "AQ. 格式密钥生成失败，启动 B 计划降级生成普通 API 密钥(AIza)..."
        gcloud services api-keys create --project="$project_id" --display-name="Fallback API Key" --quiet >/dev/null 2>&1 || true
    fi

    # 5. 再次拉取获取密钥
    keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    if [ -n "$keys_list" ]; then
        local fallback_key=""
        for key_name in $keys_list; do
            key_name=$(echo "$key_name" | tr -d '\r' | xargs)
            [ -z "$key_name" ] && continue
            local api_key
            api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
            if [[ "$api_key" == AQ.* ]]; then
                echo "$api_key"
                return 0
            fi
            if [[ "$api_key" == AIza* ]]; then
                fallback_key="$api_key"
            fi
        done
        
        if [ -n "$fallback_key" ]; then
            echo "$fallback_key"
            return 0
        fi
    fi

    return 1
}

# ===== 唯一功能：解绑所有项目 -> 建无组织新项目 -> 绑定结算 -> 提取密钥 =====
vertex_auto_flow() {
    log "INFO" "====== 全自动流程：解绑旧项目 + 创建无组织新项目 + 提取 Vertex 密钥 ======"
    local GENERATED_API_KEYS=()

    # 步骤一：解绑该结算账户下的所有项目
    unlink_all_projects_from_billing "$BILLING_ACCOUNT"

    # 步骤二：创建无组织新项目并绑定默认结算账户
    log "INFO" "开始创建 ${NUM_PROJECTS} 个无组织的新项目..."
    local success=0; local failed=0; local i=1
    while [ $i -le "$NUM_PROJECTS" ]; do
        local project_id
        project_id=$(new_project_id "$PROJECT_PREFIX")
        log "INFO" "[${i}/${NUM_PROJECTS}] 处理项目: ${project_id}"

        # 无组织：不指定 --organization / --folder，创建为无父级项目
        if ! gcloud projects create "$project_id" --no-enable-cloud-apis --quiet >/dev/null 2>&1; then
            # 部分环境不支持 --no-enable-cloud-apis，退回普通创建
            gcloud projects create "$project_id" --quiet >/dev/null 2>&1 || { log "WARN" "项目 ${project_id} 创建失败"; failed=$((failed+1)); i=$((i+1)); continue; }
        fi

        # 绑定默认可用的结算账户
        retry gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet >/dev/null 2>&1 || true
        local billing_info
        billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
        if [ -z "$billing_info" ]; then
            log "WARN" "项目 ${project_id} 结算绑定失败，跳过密钥提取喵。"
            failed=$((failed+1)); i=$((i+1)); continue
        fi

        # 步骤三：开通 API + 按原流程提取 Vertex 密钥
        enable_all_services "$project_id"

        local api_key
        if api_key=$(setup_and_extract_aq_key "$project_id"); then
            GENERATED_API_KEYS+=("$api_key")
            if [[ "$api_key" == AQ.* ]]; then
                log "SUCCESS" "AQ. 格式 API 密钥提取成功！"
            else
                log "SUCCESS" "AIza 普通格式 API 密钥降级提取成功！"
            fi
            success=$((success+1))
        else
            log "WARN" "API 密钥提取失败！"
            failed=$((failed+1))
        fi
        i=$((i+1))
    done

    echo -e "\n${GREEN}====== 全部操作完成 ======${NC}"
    echo "总计成功: ${success}, 失败: ${failed}"
    if [ ${#GENERATED_API_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 本次提取的 Agent Platform API 密钥 ======${NC}"
        for k in "${GENERATED_API_KEYS[@]}"; do echo "$k"; done
        echo
    fi
}

# ===== 主程序 =====
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        Vertex AI 独立密钥管理工具 v${VERSION}               ║"
    echo "║   (全自动: 解绑旧项目 -> 建无组织新项目 -> 提取密钥)    ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_env
    
    log "INFO" "检查结算账户..."
    local billing_accounts
    billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' 2>/dev/null || echo "")
    if [ -z "$billing_accounts" ]; then
        log "ERROR" "未找到任何开放的结算账户"
        exit 1
    fi
    
    local billing_array=()
    while IFS=$'\t' read -r id name; do billing_array+=("${id##*/} - $name"); done <<< "$billing_accounts"
    local billing_count=${#billing_array[@]}
    
    if [ "$billing_count" -eq 1 ]; then
        BILLING_ACCOUNT="${billing_array[0]%% - *}"
        log "INFO" "自动使用默认结算账户: ${BILLING_ACCOUNT}"
    else
        echo "可用的结算账户:"
        for ((i=0; i<billing_count; i++)); do echo "$((i+1)). ${billing_array[i]}"; done
        echo
        local acc_num
        read -r -p "请选择结算账户 [1-${billing_count}]: " acc_num
        if [[ "$acc_num" =~ ^[0-9]+$ ]] && [ "$acc_num" -ge 1 ] && [ "$acc_num" -le "$billing_count" ]; then
            BILLING_ACCOUNT="${billing_array[$((acc_num-1))]%% - *}"
            log "INFO" "选择结算账户: ${BILLING_ACCOUNT}"
        else
            log "ERROR" "无效的选择"; exit 1
        fi
    fi

    vertex_auto_flow
}

main
