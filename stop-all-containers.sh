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
LOG_FILE="/mnt/user/logs/docker_stop_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)

# 定义超时时间（秒）
TIMEOUT=3
FINAL_WAIT=3

# 确保日志和备份目录存在
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" "$CONFIG_BACKUP_DIR"

# 检查必要的命令是否存在
for cmd in docker docker-compose tar zstd; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_message "错误: 未找到必要的命令: $cmd"
        exit 1
    fi
done

# 解析真实路径
resolve_path() {
    local path=$1
    if [ -L "$path" ]; then
        echo $(readlink -f "$path")
    else
        echo "$path"
    fi
}

# 日志函数
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# 检查目录是否存在且可访问
check_directory() {
    local dir=$1
    dir=$(resolve_path "$dir")  # 解析真实路径
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

# 查找 docker-compose 文件
find_compose_file() {
    local dir=$1
    dir=$(resolve_path "$dir")  # 解析真实路径
    local compose_file=""
    
    # 检查常见的文件名
    for filename in "docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml"; do
        if [ -f "$dir/$filename" ]; then
            compose_file="$dir/$filename"
            break
        fi
    done
    
    echo "$compose_file"
}

# 备份容器配置文件
backup_container_configs() {
    local container_name=$1
    local compose_dir=$2
    compose_dir=$(resolve_path "$compose_dir")  # 解析真实路径
    local backup_path="$CONFIG_BACKUP_DIR/${container_name}_${BACKUP_DATE}.tar.gz"
    
    log_message "备份配置目录: $compose_dir"
    
    # 直接打包整个源目录
    tar -czf "$backup_path" -C "$(dirname "$compose_dir")" "$(basename "$compose_dir")"
    
    if [ $? -eq 0 ]; then
        log_message "✓ 目录已备份到: $backup_path"
    else
        log_message "! 警告: 目录备份失败"
    fi
}

# 备份容器状态
backup_container_state() {
    local container=$1
    local container_name=$(docker inspect -f '{{.Name}}' $container | sed 's/\///')
    local backup_file="$BACKUP_DIR/${container_name}_${BACKUP_DATE}.json"
    
    log_message "备份容器状态: $container_name"
    
    # 获取容器详细信息
    docker inspect "$container" > "$backup_file"
    
    # 显示备份内容摘要
    log_message "备份内容摘要:"
    log_message "  - 镜像: $(docker inspect -f '{{.Config.Image}}' "$container")"
    log_message "  - 状态: $(docker inspect -f '{{.State.Status}}' "$container")"
    log_message "  - 网络: $(docker inspect -f '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' "$container")"
    log_message "备份文件已保存到: $backup_file"
}

# 备份整个 appdata 目录
backup_appdata() {
    local backup_path="$CONFIG_BACKUP_DIR/appdata_${BACKUP_DATE}.tar.zst"
    local snapshot_file="$CONFIG_BACKUP_DIR/.snapshot"
    local last_full_backup=""
    local is_full_backup=false
    
    # 获取CPU核心数
    local cpu_cores=$(nproc 2>/dev/null || echo 4)
    # 使用CPU核心数的75%
    local threads=$((cpu_cores * 3 / 4))
    [ "$threads" -lt 1 ] && threads=1
    
    # 检查是否需要进行全量备份
    # 每周进行一次全量备份，其他时候进行增量备份
    if [ ! -f "$snapshot_file" ] || [ $(find "$CONFIG_BACKUP_DIR" -name ".snapshot" -mtime +7) ]; then
        is_full_backup=true
        log_message "执行全量备份..."
        # 创建新的 snapshot 文件
        : > "$snapshot_file"
    else
        log_message "执行增量备份..."
        # 查找最近的全量备份
        last_full_backup=$(find "$CONFIG_BACKUP_DIR" -name "appdata_*.tar.zst" -mtime -7 | sort -r | head -n 1)
        if [ -z "$last_full_backup" ]; then
            is_full_backup=true
            log_message "未找到最近的全量备份，切换到全量备份..."
            : > "$snapshot_file"
        fi
    fi
    
    log_message "开始备份 appdata 目录..."
    log_message "源目录: $BASE_DIR"
    log_message "备份文件: $backup_path"
    log_message "使用 zstd 压缩 (线程数: $threads, 压缩级别: 3)"
    
    # 使用 tar 的增量备份功能，配合 zstd 多线程压缩
    if $is_full_backup; then
        if tar --create \
            --file=- \
            --listed-incremental="$snapshot_file" \
            --verbose \
            -C "$(dirname "$BASE_DIR")" "$(basename "$BASE_DIR")" 2>/dev/null | \
            zstd -T$threads -3 > "$backup_path"; then
            log_message "✓ 全量备份完成"
        else
            log_message "! 错误: 全量备份失败"
            return 1
        fi
    else
        if tar --create \
            --file=- \
            --listed-incremental="$snapshot_file" \
            --verbose \
            -C "$(dirname "$BASE_DIR")" "$(basename "$BASE_DIR")" 2>/dev/null | \
            zstd -T$threads -3 > "$backup_path"; then
            log_message "✓ 增量备份完成"
            log_message "基于全量备份: $(basename "$last_full_backup")"
        else
            log_message "! 错误: 增量备份失败"
            return 1
        fi
    fi
    
    # 显示备份文件大小
    local size=$(du -h "$backup_path" | cut -f1)
    local original_size=$(du -h "$BASE_DIR" | cut -f1)
    log_message "原始大小: $original_size"
    log_message "备份大小: $size"
    
    # 验证备份文件完整性
    log_message "正在验证备份完整性..."
    if zstd -t "$backup_path" >/dev/null 2>&1; then
        log_message "✓ 备份文件验证成功"
        
        # 保留最近 30 天的备份，删除更早的备份
        log_message "清理超过 30 天的旧备份..."
        find "$CONFIG_BACKUP_DIR" -name "appdata_*.tar.*" -mtime +30 -delete
        
        return 0
    else
        log_message "! 错误: 备份文件验证失败"
        return 1
    fi
}

# 检查容器健康状态
check_container_health() {
    local container=$1
    local health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")
    echo "$health_status"
}

# 获取容器依赖关系
get_container_dependencies() {
    local container=$1
    docker inspect --format '{{range $k, $v := .HostConfig.Links}}{{$v}} {{end}}' "$container"
}

# 按依赖顺序停止容器
stop_containers() {
    local dir=$1
    dir=$(resolve_path "$dir")  # 解析真实路径
    local compose_file
    
    # 检查目录是否可访问
    if ! check_directory "$dir"; then
        return 1
    fi

    # 查找 docker-compose 文件
    compose_file=$(find_compose_file "$dir")
    if [ -z "$compose_file" ]; then
        log_message "跳过 $dir: 未找到 docker-compose 文件"
        return 0
    else
        log_message "找到配置文件: $compose_file"
    fi

    cd "$dir" || {
        log_message "错误: 无法切换到目录 $dir"
        return 1
    }

    log_message "正在处理 $dir 中的容器..."
    
    # 获取运行中的容器
    running_containers=$(docker-compose ps -q 2>/dev/null)
    if [ -z "$running_containers" ]; then
        log_message "目录 $dir 中没有运行中的容器"
        return 0
    fi

    # 显示找到的容器
    log_message "找到以下运行中的容器:"
    for container in $running_containers; do
        local name=$(docker inspect -f '{{.Name}}' "$container" 2>/dev/null | sed 's/\///')
        log_message "- $name"
    done

    # 备份所有容器的当前状态
    for container in $running_containers; do
        backup_container_state "$container"
    done

    # 首先停止没有依赖的容器
    log_message "按依赖顺序停止容器..."
    for container in $running_containers; do
        local deps=$(get_container_dependencies "$container")
        if [ -z "$deps" ]; then
            stop_single_container "$container"
        fi
    done

    # 然后停止其他容器
    for container in $running_containers; do
        if docker inspect "$container" >/dev/null 2>&1; then
            stop_single_container "$container"
        fi
    done

    # 最终验证
    sleep $FINAL_WAIT
    still_running=$(docker-compose ps -q 2>/dev/null)
    if [ -n "$still_running" ]; then
        log_message "! 警告: $dir 中可能还有容器未完全停止"
        return 1
    fi

    log_message "✓ $dir 中的所有容器已安全停止"
    return 0
}

# 停止单个容器
stop_single_container() {
    local container=$1
    local container_name=$(docker inspect -f '{{.Name}}' "$container" 2>/dev/null | sed 's/\///')
    
    log_message "正在停止容器: $container_name"
    
    # 检查容器健康状态
    local health=$(check_container_health "$container")
    log_message "容器健康状态: $health"

    # 1. 尝试优雅停止
    log_message "正在优雅停止容器 (等待 ${TIMEOUT} 秒)..."
    if docker stop -t $TIMEOUT "$container"; then
        log_message "✓ 成功停止容器: $container_name"
        return 0
    fi

    # 2. 如果优雅停止失败，发送 SIGTERM 信号
    log_message "! 优雅停止失败，尝试 SIGTERM..."
    docker kill --signal=SIGTERM "$container"
    sleep 10

    # 3. 检查容器是否已停止
    if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"; then
        log_message "✓ 容器已响应 SIGTERM 信号并停止: $container_name"
        return 0
    fi

    # 4. 最后尝试强制终止
    log_message "! 警告: 容器未响应 SIGTERM，尝试强制终止..."
    if docker kill "$container"; then
        log_message "✓ 已强制终止容器: $container_name"
    else
        log_message "! 错误: 无法停止容器: $container_name"
        return 1
    fi
}

# 主程序开始
# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
    log_message "错误: 请以 root 权限运行此脚本"
    exit 1
fi

# 检查 Docker 是否正在运行
if ! docker info >/dev/null 2>&1; then
    log_message "错误: Docker 服务未运行或无法访问"
    exit 1
fi

log_message "开始安全停止所有 Docker Compose 容器..."
log_message "基础目录: $BASE_DIR"
log_message "日志文件位置: $LOG_FILE"
log_message "容器状态备份位置: $BACKUP_DIR"
log_message "----------------------------------------"

# 记录开始时间
start_time=$(date +%s)

# 显示基础目录内容
log_message "基础目录内容:"
ls -la "$BASE_DIR" | while read -r line; do
    log_message "  $line"
done

# 查找所有包含 docker-compose.yml 或 docker-compose.yaml 的子目录
log_message "查找包含 docker-compose 文件的目录..."
log_message "执行查找命令: find -L \"$BASE_DIR\" -maxdepth 2 -type f \( -name \"docker-compose.yml\" -o -name \"docker-compose.yaml\" \)"

found_dirs=0
failed_dirs=0

while IFS= read -r compose_file; do
    if [ -n "$compose_file" ]; then
        dir=$(dirname "$compose_file")
        log_message "----------------------------------------"
        log_message "找到配置文件: $compose_file"
        log_message "处理目录: $dir"
        if ! stop_containers "$dir"; then
            ((failed_dirs++))
        fi
        ((found_dirs++))
    fi
done < <(find -L "$BASE_DIR" -maxdepth 2 -type f \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \))

if [ "$found_dirs" -eq 0 ]; then
    log_message "错误: 未找到任何包含 docker-compose.yml 的目录"
    log_message "请检查以下可能的问题:"
    log_message "1. 目录权限是否正确"
    log_message "2. docker-compose.yml 文件是否存在"
    log_message "3. 文件名是否正确（区分大小写）"
    log_message "4. 基础目录 $BASE_DIR 是否正确"
    log_message "5. 符号链接是否正确: $(readlink -f "$BASE_DIR")"
    exit 1
fi

# 如果所有容器都已成功停止，则备份整个目录
if [ "$failed_dirs" -eq 0 ]; then
    log_message "----------------------------------------"
    log_message "所有容器已成功停止，开始备份 appdata 目录..."
    if backup_appdata; then
        log_message "✓ 备份完成"
    else
        log_message "! 警告: 备份过程中出现错误"
    fi
else
    log_message "! 警告: 由于有容器停止失败，跳过目录备份"
fi

# 计算总耗时
end_time=$(date +%s)
duration=$((end_time - start_time))
log_message "----------------------------------------"
log_message "所有操作已完成！"
log_message "共处理 $found_dirs 个目录"
[ "$failed_dirs" -gt 0 ] && log_message "停止失败: $failed_dirs 个目录"
log_message "总耗时: ${duration} 秒"
log_message "完整日志已保存到: $LOG_FILE" 