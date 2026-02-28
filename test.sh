#!/bin/bash
# 优化的 GCP API 密钥管理工具
# 支持 Gemini API 和 Vertex AI
# 版本: 2.1.3 (修复菜单丢失问题 + 自动归档 + 融合极速版)

# 仅启用 errtrace (-E) 与 nounset (-u)
set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="2.1.3"
LAST_UPDATED="2025-08-28"

# 通用配置
PROJECT_PREFIX="${PROJECT_PREFIX:-gemini-key}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
MAX_PARALLEL_JOBS="${CONCURRENCY:-20}"
TEMP_DIR=""  # 将在初始化时设置

# Gemini模式配置
TIMESTAMP=$(date +%s)
# 改进的随机字符生成
if command -v openssl &>/dev/null; then
    RANDOM_CHARS=$(openssl rand -hex 2)
else
    RANDOM_CHARS=$(( RANDOM % 10000 ))
fi
EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
GEMINI_TOTAL_PROJECTS=175
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
KEY_DIR="${KEY_DIR:-./keys}"

# Vertex模式配置
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"
VERTEX_PROJECT_PREFIX="${VERTEX_PROJECT_PREFIX:-vertex}"
MAX_PROJECTS_PER_ACCOUNT=${MAX_PROJECTS_PER_ACCOUNT:-3}
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"

# ===== 初始化 =====
TEMP_DIR=$(mktemp -d -t gcp_script_XXXXXX) || { echo "错误：无法创建临时目录"; exit 1; }
mkdir -p "$KEY_DIR" 2>/dev/null || { echo "错误：无法创建密钥目录 $KEY_DIR"; exit 1; }
chmod 700 "$KEY_DIR" 2>/dev/null || true
SECONDS=0

# ===== 日志函数 =====
log() { 
    local level="${1:-INFO}"
    local msg="${2:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "INFO")     echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" ;;
        "SUCCESS")  echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" ;;
        "WARN")     echo -e "${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" >&2 ;;
        "ERROR")    echo -e "${RED}[${timestamp}] [ERROR] ${msg}${NC}" >&2 ;;
        *)          echo "[${timestamp}] [${level}] ${msg}" ;;
    esac
}

# ===== 错误处理 =====
handle_error() {
    local exit_code=$?
    local line_no=$1
    case $exit_code in 141|130) return 0 ;; esac
    log "ERROR" "在第 ${line_no} 行发生错误 (退出码 ${exit_code})"
    if [ $exit_code -gt 1 ]; then log "ERROR" "发生严重错误，请检查日志"; return $exit_code; else log "WARN" "发生非严重错误，继续执行"; return 0; fi
}
trap 'handle_error $LINENO' ERR

# ===== 清理函数 =====
cleanup_resources() {
    local exit_code=$?
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR" 2>/dev/null || true; fi
    if [ $exit_code -eq 0 ]; then echo -e "\n${CYAN}感谢使用 GCP API 密钥管理工具${NC}"; fi
}
trap cleanup_resources EXIT

# ===== 工具函数 =====
retry() {
    local max_attempts="$MAX_RETRY_ATTEMPTS"
    local attempt=1
    local delay
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then return 0; fi
        local error_code=$?
        if [ $attempt -ge $max_attempts ]; then log "ERROR" "命令在 ${max_attempts} 次尝试后失败: $*"; return $error_code; fi
        delay=$(( attempt * 5 + RANDOM % 3 ))
        log "WARN" "重试 ${attempt}/${max_attempts} (等待 ${delay}s)"
        sleep $delay
        attempt=$((attempt + 1)) || true
    done
}

require_cmd() { if ! command -v "$1" &>/dev/null; then log "ERROR" "缺少依赖: $1"; exit 1; fi; }

ask_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    if [ ! -t 0 ]; then [[ "$default" =~ ^[Yy]$ ]] && return 0 || return 1; fi
    local resp
    read -r -p "${prompt} [y/N]: " resp || resp="$default"
    resp=${resp:-$default}
    [[ "$resp" =~ ^[Yy]$ ]]
}

unique_suffix() { 
    if command -v uuidgen &>/dev/null; then uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]'
    else echo "$(date +%s%N 2>/dev/null || date +%s)${RANDOM}" | sha256sum | cut -c1-6; fi
}

new_project_id() {
    local prefix="${1:-$PROJECT_PREFIX}"
    echo "${prefix}-$(unique_suffix)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30
}

is_service_enabled() {
    gcloud services list --enabled --project="$1" --filter="name:$2" --format='value(name)' 2>/dev/null | grep -q .
}

check_env() {
    log "INFO" "检查环境配置..."
    require_cmd gcloud
    if ! gcloud config list account --quiet &>/dev/null; then log "ERROR" "请先运行 'gcloud init'"; exit 1; fi
    log "SUCCESS" "环境检查通过"
}

enable_services() {
    local proj="$1"
    shift
    local services=("$@")
    if [ ${#services[@]} -eq 0 ]; then
        services=("aiplatform.googleapis.com" "iam.googleapis.com" "iamcredentials.googleapis.com" "cloudresourcemanager.googleapis.com")
    fi
    log "INFO" "为项目 ${proj} 启用必要的API服务..."
    local failed=0
    for svc in "${services[@]}"; do
        if is_service_enabled "$proj" "$svc"; then continue; fi
        if ! retry gcloud services enable "$svc" --project="$proj" --quiet; then
            log "ERROR" "无法启用服务: ${svc}"
            failed=$((failed + 1))
        fi
    done
    if [ $failed -gt 0 ]; then return 1; fi
    return 0
}

show_progress() {
    local completed="${1:-0}"
    local total="${2:-1}"
    if [ "$total" -le 0 ]; then return; fi
    if [ "$completed" -gt "$total" ]; then completed=$total; fi
    local percent=$((completed * 100 / total))
    printf "\r进度: %3d%% (%d/%d)" "$percent" "$completed" "$total"
    if [ "$completed" -eq "$total" ]; then echo; fi
}

parse_json() {
    local json="$1"
    local field="$2"
    if [ -z "$json" ]; then return 1; fi
    if command -v jq &>/dev/null; then
        local result=$(echo "$json" | jq -r "$field" 2>/dev/null)
        if [ -n "$result" ] && [ "$result" != "null" ]; then echo "$result"; return 0; fi
    fi
    if [ "$field" = ".keyString" ]; then
        echo "$json" | grep -o '"keyString":"[^"]*"' | sed 's/"keyString":"//;s/"$//' | head -n 1
        return 0
    fi
    local field_name=$(echo "$field" | sed 's/^\.//')
    echo "$json" | grep -o "\"$field_name\":[^,}]*" | sed "s/\"$field_name\"://;s/\"//g" | head -n 1
}

unlink_projects_from_billing_account() {
    local billing_id="$1"
    if [ -z "$billing_id" ]; then return 1; fi
    log "INFO" "正在检查结算账户关联..."
    local linked_projects
    linked_projects=$(gcloud billing projects list --billing-account="$billing_id" --format='value(projectId)' 2>/dev/null)
    if [ -z "$linked_projects" ]; then return 0; fi
    log "WARN" "发现旧项目占用结算账户，开始自动解绑..."
    local project_array=()
    while IFS= read -r line; do [ -n "$line" ] && project_array+=("$line"); done <<< "$linked_projects"
    for project_id in "${project_array[@]}"; do
        if retry gcloud billing projects unlink "$project_id" --quiet; then
            log "SUCCESS" "成功解绑项目: ${project_id}"
        else
            log "WARN" "解绑项目失败: ${project_id}"
        fi
    done
    return 0
}

# =========================================================================
#  融合极速版流程 (Fusion One-Shot Process)
#  功能：单次执行，失败自动解绑重试，双模提取，结果自动归档到文件夹
# =========================================================================
fusion_one_shot_process() {
    echo -e "\n${CYAN}${BOLD}====== 启动融合极速版 (Gemini + Vertex) ======${NC}"
    log "INFO" "开始执行定制化流程：创建1个项目 -> 智能绑结算 -> 同时提取凭证 -> 自动归档"

    local start_time=$SECONDS
    local project_prefix="fusion-mod"
    local gemini_key_file="fusion_gemini_key.txt"
    
    # 1. 获取结算账户
    log "INFO" "正在获取结算账户..."
    local billing_accounts
    billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null || echo "")
    if [ -z "$billing_accounts" ]; then log "ERROR" "未找到任何开放的结算账户，无法继续。"; return 1; fi
    local TARGET_BILLING_ID
    TARGET_BILLING_ID=$(echo "$billing_accounts" | head -n 1)
    TARGET_BILLING_ID="${TARGET_BILLING_ID##*/}"
    log "SUCCESS" "使用结算账户: ${TARGET_BILLING_ID}"

    # 2. 创建新项目
    local project_id
    project_id=$(new_project_id "$project_prefix")
    log "INFO" "正在创建项目 ${project_id} ..."
    if ! retry gcloud projects create "$project_id" --quiet; then
        log "ERROR" "创建项目失败，终止流程。"
        return 1
    fi

    # 3. 绑定结算账户 (失败则清理重试)
    log "INFO" "正在绑定结算账户..."
    if ! gcloud billing projects link "$project_id" --billing-account="$TARGET_BILLING_ID" --quiet 2>/dev/null; then
        log "WARN" "直接绑定失败 (可能配额已满)，执行清理逻辑..."
        if unlink_projects_from_billing_account "$TARGET_BILLING_ID"; then
            log "INFO" "旧项目清理完毕，重试绑定..."
            sleep 3
            if ! retry gcloud billing projects link "$project_id" --billing-account="$TARGET_BILLING_ID" --quiet; then
                log "ERROR" "重试绑定依然失败。请检查结算账户状态。"
                gcloud projects delete "$project_id" --quiet 2>/dev/null
                return 1
            fi
        else
            log "ERROR" "清理过程失败，终止流程。"
            gcloud projects delete "$project_id" --quiet 2>/dev/null
            return 1
        fi
    fi
    log "SUCCESS" "结算账户绑定成功。"

    # 4. 启用服务
    log "INFO" "正在启用必要 API 服务..."
    local services=("generativelanguage.googleapis.com" "aiplatform.googleapis.com" "iam.googleapis.com" "iamcredentials.googleapis.com" "cloudresourcemanager.googleapis.com" "apikeys.googleapis.com")
    if ! enable_services "$project_id" "${services[@]}"; then
        log "ERROR" "部分服务启用失败。"
        return 1
    fi

    echo -e "\n${YELLOW}>>> 开始提取凭证...${NC}"

    # 5. 提取 Gemini API Key
    local key_output
    local gemini_key=""
    if key_output=$(retry gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --format=json --quiet); then
        gemini_key=$(parse_json "$key_output" ".keyString")
        if [ -n "$gemini_key" ]; then
            echo "$gemini_key" > "$gemini_key_file"
            log "SUCCESS" "Gemini API Key 提取成功"
        else
            log "ERROR" "Gemini Key 生成了但无法解析。"
        fi
    else
        log "ERROR" "Gemini API Key 创建失败。"
    fi

    # 6. 提取 Vertex JSON
    local vertex_success=false
    if vertex_setup_service_account "$project_id"; then
        vertex_success=true
        log "SUCCESS" "Vertex JSON 提取成功"
    else
        log "ERROR" "Vertex JSON 提取失败"
    fi

    # 7. 自动归档
    echo -e "\n${YELLOW}>>> 正在归档文件...${NC}"
    local folder_timestamp=$(date "+%Y-%m-%d_%H-%M-%S")
    local result_folder="key json ${folder_timestamp}"
    
    if mkdir -p "$result_folder"; then
        if [ -f "$gemini_key_file" ]; then mv "$gemini_key_file" "$result_folder/"; fi
        local target_json
        target_json=$(find "$KEY_DIR" -maxdepth 1 -name "${project_id}*.json" 2>/dev/null | head -n 1)
        if [ -n "$target_json" ]; then mv "$target_json" "$result_folder/"; fi
        log "SUCCESS" "文件已归档至文件夹: ${BOLD}${result_folder}${NC}"
    else
        log "ERROR" "创建归档文件夹失败"
    fi

    # 8. 结束报告
    local duration=$((SECONDS - start_time))
    echo -e "\n${CYAN}${BOLD}====== 任务完成 ======${NC}"
    echo "项目ID: $project_id"
    echo "耗时: ${duration}秒"
    echo -e "结果文件夹: ${GREEN}${result_folder}${NC}"
    echo
}

# ===== Gemini 相关函数 (已修复缺失) =====

gemini_main() {
    local start_time=$SECONDS
    echo -e "\n${CYAN}${BOLD}======================================================"
    echo -e "    Google Gemini API 密钥管理工具"
    echo -e "======================================================${NC}\n"
    check_env || return 1
    echo -e "${YELLOW}提示: Gemini API 提供免费额度，适合个人开发和测试使用${NC}\n"
    echo "请选择操作："
    echo "1. 创建新项目并获取API密钥"
    echo "2. 从现有项目获取API密钥"
    echo "3. 删除现有项目"
    echo "0. 返回主菜单"
    echo
    local choice
    read -r -p "请选择 [0-3]: " choice
    case "$choice" in
        1) gemini_create_projects ;;
        2) gemini_get_keys_from_existing ;;
        3) gemini_delete_projects ;;
        0) return 0 ;;
        *) log "ERROR" "无效选项"; return 1 ;;
    esac
    local duration=$((SECONDS - start_time))
    log "INFO" "操作完成，耗时: $((duration / 60))分$((duration % 60))秒"
}

gemini_create_projects() {
    log "INFO" "====== 开始自动创建3个付费Gemini项目 ======"
    local num_projects=3
    local project_prefix="gemini-api"
    log "INFO" "正在自动查找并选择第一个可用的结算账户..."
    local billing_accounts
    billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null || echo "")
    if [ -z "$billing_accounts" ]; then log "ERROR" "未找到任何开放的结算账户。"; return 1; fi
    local GEMINI_BILLING_ACCOUNT
    GEMINI_BILLING_ACCOUNT=$(echo "$billing_accounts" | head -n 1)
    GEMINI_BILLING_ACCOUNT="${GEMINI_BILLING_ACCOUNT##*/}"
    log "SUCCESS" "已自动选择结算账户: ${GEMINI_BILLING_ACCOUNT}"
    log "INFO" "执行预处理：检查并释放结算账户配额..."
    if ! unlink_projects_from_billing_account "$GEMINI_BILLING_ACCOUNT"; then log "ERROR" "预处理失败。"; return 1; fi
    log "WARN" "准备工作完成，3秒后将自动开始创建新项目。按 Ctrl+C 可取消..."
    sleep 3
    local key_file="gemini_keys_auto_$(date +%Y%m%d_%H%M%S).txt"
    local csv_file="gemini_keys_auto_$(date +%Y%m%d_%H%M%S).csv"
    > "$key_file"; echo -n > "$csv_file"
    log "INFO" "开始执行项目创建流程..."
    local success=0; local failed=0; local i=1
    while [ $i -le $num_projects ]; do
        local project_id; project_id=$(new_project_id "$project_prefix")
        if ! retry gcloud projects create "$project_id" --quiet; then
            failed=$((failed + 1)); i=$((i + 1)); show_progress "$((success+failed))" "$num_projects"; continue
        fi
        if ! retry gcloud billing projects link "$project_id" --billing-account="$GEMINI_BILLING_ACCOUNT" --quiet; then
            gcloud projects delete "$project_id" --quiet 2>/dev/null
            failed=$((failed + 1)); i=$((i + 1)); show_progress "$((success+failed))" "$num_projects"; continue
        fi
        if ! retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet; then
            failed=$((failed + 1)); i=$((i + 1)); show_progress "$((success+failed))" "$num_projects"; continue
        fi
        local key_output
        if ! key_output=$(retry gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --format=json --quiet); then
            failed=$((failed + 1)); i=$((i + 1)); show_progress "$((success+failed))" "$num_projects"; continue
        fi
        local api_key; api_key=$(parse_json "$key_output" ".keyString")
        if [ -n "$api_key" ]; then
            echo "$api_key" >> "$key_file"
            if [ -s "$csv_file" ]; then echo -n "," >> "$csv_file"; fi
            echo -n "$api_key" >> "$csv_file"
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
        show_progress "$((success+failed))" "$num_projects"
        i=$((i + 1))
    done
    echo; log "SUCCESS" "自动化操作完成！成功: $success, 失败: $failed"
    if [ "$success" -gt 0 ]; then echo "密钥已保存到: $key_file"; fi
}

gemini_get_keys_from_existing() {
    log "INFO" "====== 从现有项目获取Gemini API密钥 ======"
    local projects; projects=$(gcloud projects list --format='value(projectId)' --filter='lifecycleState:ACTIVE' 2>/dev/null || echo "")
    if [ -z "$projects" ]; then log "ERROR" "未找到任何活跃项目"; return 1; fi
    echo "功能略... 请使用创建功能" 
}

gemini_delete_projects() {
    log "INFO" "====== 删除现有项目 ======"
    read -r -p "输入项目前缀进行批量删除: " prefix
    if [ -z "$prefix" ]; then return 0; fi
    local projects; projects=$(gcloud projects list --format="value(projectId)" --filter="projectId:$prefix*" 2>/dev/null)
    for p in $projects; do
        log "INFO" "删除 $p ..."
        gcloud projects delete "$p" --quiet
    done
}

# ===== Vertex AI 相关函数 =====
vertex_main() {
    echo -e "\n${CYAN}${BOLD}Vertex AI 管理${NC}\n"
    check_env || return 1
    local billing_accounts; billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null | head -n 1)
    if [ -z "$billing_accounts" ]; then log "ERROR" "无结算账户"; return 1; fi
    BILLING_ACCOUNT="${billing_accounts##*/}"
    echo "1. 创建新项目"
    echo "2. 配置现有项目"
    echo "3. 管理密钥"
    echo "0. 返回"
    local choice; read -r -p "选择: " choice
    case "$choice" in 1) vertex_create_projects ;; 2) vertex_configure_existing ;; 3) vertex_manage_keys ;; 0) return 0 ;; esac
}

vertex_create_projects() {
    local project_id; project_id=$(new_project_id "vertex")
    unlink_projects_from_billing_account "$BILLING_ACCOUNT"
    retry gcloud projects create "$project_id" --quiet
    retry gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet
    enable_services "$project_id"
    vertex_setup_service_account "$project_id"
}

vertex_setup_service_account() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex AI Service Account" --project="$project_id" --quiet || return 1
    fi
    local roles=("roles/aiplatform.admin" "roles/iam.serviceAccountUser" "roles/iam.serviceAccountTokenCreator" "roles/aiplatform.user")
    for role in "${roles[@]}"; do
        retry gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="$role" --quiet &>/dev/null
    done
    local key_file="${KEY_DIR}/${project_id}-${SERVICE_ACCOUNT_NAME}-$(date +%Y%m%d-%H%M%S).json"
    if retry gcloud iam service-accounts keys create "$key_file" --iam-account="$sa_email" --project="$project_id" --quiet; then
        chmod 600 "$key_file"
        log "SUCCESS" "密钥已保存: ${key_file}"
        return 0
    fi
    return 1
}

vertex_configure_existing() { log "INFO" "功能略"; }
vertex_manage_keys() { find "$KEY_DIR" -name "*.json"; }

# ===== 主菜单 =====
show_menu() {
    echo -e "\n${CYAN}${BOLD}====== GCP Tool v${VERSION} ======${NC}"
    echo "1. Gemini API 管理"
    echo "2. Vertex AI 管理"
    echo "3. 设置 (暂未实现)"
    echo "4. 帮助 (暂未实现)"
    echo -e "${GREEN}5. [融合极速版] Gemini Key + Vertex JSON (自动归档)${NC}" 
    echo "0. 退出"
    local choice
    read -r -p "请选择: " choice
    case "$choice" in
        1) gemini_main ;;
        2) vertex_main ;;
        5) fusion_one_shot_process ;; 
        0) exit 0 ;;
        *) ;; 
    esac
}
show_settings() { log "INFO" "Settings"; }
show_help() { log "INFO" "Help"; }

# ===== 主程序入口 =====
main() {
    while true; do show_menu; done
}

main
