#!/bin/bash

# 设置错误时退出，但允许某些命令失败
set +e

# 定义基础目录
USER_BASE_DIR="/mnt/user/appdata"
CACHE_BASE_DIR="/mnt/cache/appdata"
# 检测实际使用的基础目录
if [ -L "$USER_BASE_DIR" ]; then
    BASE_DIR=$(readlink -f "$USER_BASE_DIR")
    log_message "检测到符号链接，使用实际路径: $BASE_DIR"
else
    BASE_DIR="$USER_BASE_DIR"
    log_message "使用用户共享路径: $BASE_DIR"
fi

# 确保基础目录存在
if [ ! -d "$BASE_DIR" ]; then
    if [ -d "$CACHE_BASE_DIR" ]; then
        BASE_DIR="$CACHE_BASE_DIR"
        log_message "使用缓存目录路径: $BASE_DIR"
    else
        log_message "错误: 无法找到有效的 appdata 目录"
        exit 1
    fi
fi

BACKUP_DIR="/mnt/user/backups/docker_state"
CONFIG_BACKUP_DIR="/mnt/user/backups/docker_configs"
LOG_FILE="/mnt/user/logs/docker_restore_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/docker_restore_$$"
MAX_PARALLEL=3  # 最大并行恢复数量

# 解析真实路径
resolve_path() {
    local path=$1
    if [ -L "$path" ]; then
        echo $(readlink -f "$path")
    else
        echo "$path"
    fi
}

# 清理临时文件和目录
cleanup() {
    log_message "开始清理临时文件..."
    
    # 清理临时目录
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log_message "✓ 临时目录已清理"
    fi
    
    # 清理旧日志
    local log_dir=$(dirname "$LOG_FILE")
    local log_count=$(find "$log_dir" -name "docker_restore_*.log" -type f | wc -l)
    if [ "$log_count" -gt 5 ]; then
        log_message "清理旧日志文件..."
        find "$log_dir" -name "docker_restore_*.log" -type f | sort -r | tail -n +6 | xargs rm -f
        log_message "✓ 已保留最新的5个日志文件"
    fi
    
    # 清理可能的孤立容器
    local orphaned=$(docker ps -aq --filter status=exited --filter status=created)
    if [ -n "$orphaned" ]; then
        log_message "清理孤立容器..."
        docker rm $orphaned >/dev/null 2>&1
        log_message "✓ 孤立容器已清理"
    fi
}

# 设置退出时的清理操作
trap cleanup EXIT

# 确保临时目录存在
mkdir -p "$TEMP_DIR"

# 日志函数
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# 显示进度条
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((percentage * width / 100))
    local empty=$((width - filled))
    local elapsed=$3
    
    printf "\r进度: ["
    printf "%${filled}s" "" | tr ' ' '#'
    printf "%${empty}s" "" | tr ' ' '-'
    printf "] %3d%% (%d/%d)" "$percentage" "$current" "$total"
    
    if [ -n "$elapsed" ]; then
        local eta=$(( (elapsed * (total - current)) / current ))
        printf " - 已用时间: %02d:%02d:%02d" $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60))
        printf " - 预计剩余: %02d:%02d:%02d" $((eta/3600)) $((eta%3600/60)) $((eta%60))
    fi
}

# 检查目录是否存在且可访问
check_directory() {
    local dir=$1
    if [ ! -d "$dir" ]; then
        log_message "错误: 目录不存在: $dir"
        return 1
    fi
    if [ ! -r "$dir" ]; then
        log_message "错误: 无法读取目录: $dir"
        return 1
    fi
    return 0
}

# 获取最新的备份时间戳
get_latest_backup() {
    local latest_timestamp=""
    local latest_file=""
    
    # 查找最新的备份文件（支持 .tar.gz 和 .tar.zst）
    for file in "$CONFIG_BACKUP_DIR"/appdata_*.tar.*; do
        if [ -f "$file" ]; then
            local timestamp=$(basename "$file" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            if [ -n "$timestamp" ]; then
                if [ -z "$latest_timestamp" ] || [ "$timestamp" \> "$latest_timestamp" ]; then
                    latest_timestamp=$timestamp
                    latest_file=$file
                fi
            fi
        fi
    done
    
    if [ -n "$latest_timestamp" ]; then
        local date_part=${latest_timestamp:0:8}
        local time_part=${latest_timestamp:9:6}
        log_message "找到最新备份: ${date_part:0:4}-${date_part:4:2}-${date_part:6:2} ${time_part:0:2}:${time_part:2:2}:${time_part:4:2}"
        echo "$latest_timestamp"
    else
        log_message "错误: 未找到任何备份文件"
        return 1
    fi
}

# 获取需要恢复的备份文件列表
get_backup_chain() {
    local target_timestamp=$1
    local backup_files=()
    local full_backup=""
    
    # 查找最近的全量备份（支持 .tar.gz 和 .tar.zst）
    for file in "$CONFIG_BACKUP_DIR"/appdata_*.tar.*; do
        if [ -f "$file" ]; then
            local timestamp=$(basename "$file" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            if [ -n "$timestamp" ] && [ "$timestamp" \< "$target_timestamp" ]; then
                # 检查是否为全量备份
                if [[ "$file" == *.tar.zst ]]; then
                    if zstd -dc "$file" 2>/dev/null | tar -t 2>/dev/null | grep -q "^.*\.$"; then
                        if [ -z "$full_backup" ] || [ "$timestamp" \> "$(basename "$full_backup" | grep -o '[0-9]\{8\}_[0-9]\{6\}')" ]; then
                            full_backup=$file
                        fi
                    fi
                else
                    if tar -tf "$file" 2>/dev/null | grep -q "^.*\.$"; then
                        if [ -z "$full_backup" ] || [ "$timestamp" \> "$(basename "$full_backup" | grep -o '[0-9]\{8\}_[0-9]\{6\}')" ]; then
                            full_backup=$file
                        fi
                    fi
                fi
            fi
        fi
    done
    
    if [ -z "$full_backup" ]; then
        log_message "错误: 未找到有效的全量备份"
        return 1
    fi
    
    backup_files+=("$full_backup")
    local full_backup_timestamp=$(basename "$full_backup" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
    
    # 查找全量备份之后的增量备份
    for file in "$CONFIG_BACKUP_DIR"/appdata_*.tar.*; do
        if [ -f "$file" ]; then
            local timestamp=$(basename "$file" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            if [ -n "$timestamp" ] && [ "$timestamp" \> "$full_backup_timestamp" ] && [ "$timestamp" \<= "$target_timestamp" ]; then
                backup_files+=("$file")
            fi
        fi
    done
    
    # 按时间顺序排序备份文件
    printf "%s\n" "${backup_files[@]}" | sort
}

# 解压备份文件
extract_backup() {
    local backup_file=$1
    local target_dir=$2
    
    if [[ "$backup_file" == *.tar.zst ]]; then
        log_message "使用 zstd 解压: $(basename "$backup_file")"
        # 获取CPU核心数并计算线程数
        local cpu_cores=$(nproc 2>/dev/null || echo 4)
        local threads=$((cpu_cores * 3 / 4))
        [ "$threads" -lt 1 ] && threads=1
        
        if ! zstd -dc -T$threads "$backup_file" 2>/dev/null | tar -xf - -C "$target_dir" 2>/dev/null; then
            return 1
        fi
    else
        log_message "使用 gzip 解压: $(basename "$backup_file")"
        if ! tar -xzf "$backup_file" -C "$target_dir" 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}

# 恢复配置文件
restore_configs() {
    local timestamp=$1
    local backup_chain=()
    
    # 获取备份链
    while IFS= read -r backup_file; do
        backup_chain+=("$backup_file")
    done < <(get_backup_chain "$timestamp")
    
    if [ ${#backup_chain[@]} -eq 0 ]; then
        log_message "错误: 未找到有效的备份链"
        return 1
    fi
    
    log_message "找到 ${#backup_chain[@]} 个备份文件需要恢复"
    log_message "开始恢复备份链..."
    
    # 创建临时恢复目录
    local temp_restore_dir="$TEMP_DIR/restore_$$"
    mkdir -p "$temp_restore_dir"
    
    # 按顺序应用备份
    local index=1
    for backup_file in "${backup_chain[@]}"; do
        log_message "正在应用备份 ($index/${#backup_chain[@]}): $(basename "$backup_file")"
        
        if ! extract_backup "$backup_file" "$temp_restore_dir"; then
            log_message "! 错误: 备份文件解压失败: $(basename "$backup_file")"
            rm -rf "$temp_restore_dir"
            return 1
        fi
        ((index++))
    done
    
    # 将恢复的文件移动到目标位置
    if [ -d "$temp_restore_dir/appdata" ]; then
        log_message "正在将恢复的文件移动到目标位置..."
        if rsync -a --delete --info=progress2 "$temp_restore_dir/appdata/" "$BASE_DIR/"; then
            log_message "✓ 文件恢复完成"
            rm -rf "$temp_restore_dir"
            return 0
        else
            log_message "! 错误: 文件移动失败"
            rm -rf "$temp_restore_dir"
            return 1
        fi
    else
        log_message "! 错误: 恢复目录结构不正确"
        rm -rf "$temp_restore_dir"
        return 1
    fi
}

# 从备份恢复容器
restore_container() {
    local container_name=$1
    local timestamp=$2
    local state_file="$BACKUP_DIR/${container_name}_${timestamp}.json"
    local status_file="$TEMP_DIR/${container_name}.status"
    local retry_count=3
    local retry_delay=5
    
    {
        if [ ! -f "$state_file" ]; then
            log_message "错误: 未找到状态备份文件: $state_file"
            echo "failed" > "$status_file"
            return 1
        fi
        
        log_message "正在恢复容器: $container_name"
        
        # 停止现有容器（如果存在）
        if docker ps -q --filter name="$container_name" | grep -q .; then
            log_message "停止现有容器: $container_name"
            docker stop "$container_name" >/dev/null 2>&1
            docker rm "$container_name" >/dev/null 2>&1
        fi
        
        # 从状态文件中获取原始目录名
        local original_dir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container_name" 2>/dev/null || echo "")
        if [ -z "$original_dir" ]; then
            original_dir=$(dirname "$(find "$BASE_DIR" -name "docker-compose.yml" -o -name "docker-compose.yaml" | head -n 1)")
        fi
        
        if [ -z "$original_dir" ]; then
            log_message "错误: 无法确定容器的工作目录"
            echo "failed" > "$status_file"
            return 1
        fi
        
        # 切换到容器目录
        cd "$original_dir" || {
            log_message "错误: 无法切换到目录: $original_dir"
            echo "failed" > "$status_file"
            return 1
        }
        
        # 检查 docker-compose 文件
        if [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ]; then
            log_message "错误: 未找到 docker-compose 文件"
            echo "failed" > "$status_file"
            return 1
        }
        
        # 添加重试机制
        while [ $retry_count -gt 0 ]; do
            if docker-compose up -d; then
                # 添加启动后的健康检查
                local health_check_timeout=30
                local health_check_interval=2
                
                while [ $health_check_timeout -gt 0 ]; do
                    local health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_name" 2>/dev/null)
                    
                    if [ "$health" = "healthy" ] || [ "$health" = "running" ]; then
                        log_message "✓ 容器已成功启动并健康运行: $container_name"
                        echo "success" > "$status_file"
                        return 0
                    fi
                    
                    sleep $health_check_interval
                    health_check_timeout=$((health_check_timeout - health_check_interval))
                done
                
                log_message "! 警告: 容器启动但未达到健康状态: $container_name"
                break
            else
                retry_count=$((retry_count - 1))
                if [ $retry_count -gt 0 ]; then
                    log_message "重试启动容器 ($((3-retry_count))/3): $container_name"
                    sleep $retry_delay
                fi
            fi
        done
    } &
}

# 建议添加的新函数
verify_backup_chain() {
    local backup_files=("$@")
    local previous_timestamp=""
    
    for file in "${backup_files[@]}"; do
        local timestamp=$(basename "$file" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
        
        if [ -n "$previous_timestamp" ] && [ "$timestamp" \< "$previous_timestamp" ]; then
            log_message "错误: 备份链时间顺序不正确"
            return 1
        fi
        
        # 验证文件完整性
        if [[ "$file" == *.tar.zst ]]; then
            if ! zstd -t "$file" >/dev/null 2>&1; then
                log_message "错误: 备份文件损坏: $(basename "$file")"
                return 1
            fi
        else
            if ! tar -tzf "$file" >/dev/null 2>&1; then
                log_message "错误: 备份文件损坏: $(basename "$file")"
                return 1
            fi
        fi
        
        previous_timestamp=$timestamp
    done
    return 0
}

# 建议添加错误收集函数
collect_error_info() {
    local container=$1
    local error_file="$TEMP_DIR/${container}_error.log"
    
    {
        echo "===== 容器信息 ====="
        docker inspect "$container" 2>/dev/null || echo "无法获取容器信息"
        
        echo -e "\n===== 容器日志 ====="
        docker logs --tail 50 "$container" 2>/dev/null || echo "无法获取容器日志"
        
        echo -e "\n===== Docker Compose 配置 ====="
        cat docker-compose.yml 2>/dev/null || echo "无法读取 docker-compose.yml"
    } > "$error_file"
    
    log_message "详细错误信息已保存到: $error_file"
}

# 主程序开始
# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
    log_message "错误: 请以 root 权限运行此脚本"
    exit 1
fi

# 检查必要的命令是否存在
for cmd in docker docker-compose rsync tar zstd; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_message "错误: 未找到必要的命令: $cmd"
        exit 1
    fi
done

# 检查基础目录是否存在且可访问
if ! check_directory "$BASE_DIR"; then
    log_message "错误: 无法访问基础目录: $BASE_DIR"
    exit 1
fi

# 检查备份目录是否存在且可访问
if ! check_directory "$BACKUP_DIR" || ! check_directory "$CONFIG_BACKUP_DIR"; then
    log_message "错误: 无法访问备份目录"
    exit 1
fi

# 检查 Docker 是否正在运行
if ! docker info >/dev/null 2>&1; then
    log_message "错误: Docker 服务未运行或无法访问"
    exit 1
fi

# 获取最新的备份时间戳
TIMESTAMP=$(get_latest_backup)
if [ -z "$TIMESTAMP" ]; then
    exit 1
fi

log_message "开始恢复最新备份..."
log_message "----------------------------------------"

# 首先恢复整个 appdata 目录
log_message "正在恢复 appdata 目录..."
if ! restore_configs "$TIMESTAMP"; then
    log_message "错误: appdata 目录恢复失败"
    exit 1
fi
log_message "✓ appdata 目录恢复完成"

# 获取需要恢复的容器列表
containers=()
for state_file in "$BACKUP_DIR"/*_"$TIMESTAMP".json; do
    if [ -f "$state_file" ]; then
        container_name=$(basename "$state_file" | sed "s/_${TIMESTAMP}.json//")
        containers+=("$container_name")
    fi
done

total_containers=${#containers[@]}
if [ "$total_containers" -eq 0 ]; then
    log_message "错误: 未找到任何容器备份"
    exit 1
fi

log_message "找到 $total_containers 个容器需要恢复"
restored=0
failed=0

# 并行恢复容器
for ((i=0; i<${#containers[@]}; i+=MAX_PARALLEL)); do
    # 启动最多 MAX_PARALLEL 个并行任务
    for ((j=i; j<i+MAX_PARALLEL && j<${#containers[@]}; j++)); do
        restore_container "${containers[j]}" "$TIMESTAMP"
    done
    
    # 等待当前批次完成
    wait
    
    # 检查恢复状态
    for ((j=i; j<i+MAX_PARALLEL && j<${#containers[@]}; j++)); do
        container_name="${containers[j]}"
        status_file="$TEMP_DIR/${container_name}.status"
        if [ -f "$status_file" ]; then
            if [ "$(cat "$status_file")" = "success" ]; then
                ((restored++))
            else
                ((failed++))
            fi
            rm -f "$status_file"
        fi
        show_progress "$((j+1))" "$total_containers"
    done
done

echo  # 换行，结束进度条

log_message "----------------------------------------"
log_message "恢复操作已完成！"
log_message "成功恢复: $restored 个容器"
[ "$failed" -gt 0 ] && log_message "恢复失败: $failed 个容器"
log_message "完整日志已保存到: $LOG_FILE" 