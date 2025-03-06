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

# 定义日志文件
LOG_FILE="/mnt/user/logs/docker_start_$(date +%Y%m%d_%H%M%S).log"

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"

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

# 检查并重建自定义网络
check_and_rebuild_network() {
    local network_name=$1
    local network_config

    # 检查网络是否存在
    if docker network inspect "$network_name" >/dev/null 2>&1; then
        log_message "检测到自定义网络: $network_name"
        
        # 检查网络状态
        network_config=$(docker network inspect "$network_name" 2>/dev/null)
        if [ $? -ne 0 ] || ! echo "$network_config" | grep -q '"EnableIPv6": false' || ! echo "$network_config" | grep -q '"Internal": false'; then
            log_message "网络 $network_name 状态异常，尝试重建..."
            
            # 获取连接到此网络的容器列表
            local containers
            containers=$(docker network inspect "$network_name" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)
            
            # 断开所有容器
            for container in $containers; do
                log_message "断开容器 $container 与网络 $network_name 的连接"
                docker network disconnect -f "$network_name" "$container" 2>/dev/null
            done
            
            # 删除网络
            log_message "删除网络 $network_name"
            docker network rm "$network_name" 2>/dev/null
            
            # 重建网络
            log_message "重建网络 $network_name"
            if docker network create --driver bridge "$network_name"; then
                log_message "✓ 网络 $network_name 重建成功"
            else
                log_message "! 错误: 网络 $network_name 重建失败"
                return 1
            fi
        else
            log_message "✓ 网络 $network_name 状态正常"
        fi
    fi
    return 0
}

# 检查容器健康状态
check_container_health() {
    local container_id=$1
    local container_name=$2
    local max_retries=30  # 最多等待30次
    local retry_interval=2  # 每次等待2秒
    local retry_count=0
    local status
    local health
    
    log_message "检查容器健康状态: $container_name"
    
    while [ $retry_count -lt $max_retries ]; do
        # 检查容器是否仍在运行
        status=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)
        if [ "$status" != "running" ]; then
            log_message "! 错误: 容器 $container_name 未运行，状态: $status"
            return 1
        fi
        
        # 检查容器是否定义了健康检查
        if docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null | grep -q "none"; then
            # 如果容器没有定义健康检查，则检查是否有进程在运行
            if [ "$(docker top "$container_id" 2>/dev/null | wc -l)" -gt 1 ]; then
                log_message "✓ 容器 $container_name 正在运行（无健康检查）"
                return 0
            fi
        else
            # 如果容器定义了健康检查，则检查健康状态
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container_id" 2>/dev/null)
            if [ "$health" = "healthy" ]; then
                log_message "✓ 容器 $container_name 健康状态: $health"
                return 0
            elif [ "$health" = "unhealthy" ]; then
                log_message "! 错误: 容器 $container_name 不健康"
                return 1
            fi
        fi
        
        ((retry_count++))
        log_message "等待容器 $container_name 启动... ($retry_count/$max_retries)"
        sleep $retry_interval
    done
    
    log_message "! 错误: 容器 $container_name 启动超时"
    return 1
}

# 启动容器
start_containers() {
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

    # 检查 compose 文件中使用的网络
    log_message "检查网络配置..."
    local networks
    networks=$(grep -A 5 "networks:" "$compose_file" 2>/dev/null | grep -v "networks:" | grep -v "^-" | awk '{print $1}' | grep -v "^$")
    
    if [ -n "$networks" ]; then
        log_message "发现自定义网络配置:"
        echo "$networks" | while read -r network; do
            log_message "- 检查网络: $network"
            if ! check_and_rebuild_network "$network"; then
                log_message "! 警告: 网络 $network 处理失败"
            fi
        done
    fi

    # 停止并删除现有容器
    log_message "停止并删除现有容器..."
    if docker-compose down --remove-orphans; then
        log_message "✓ 现有容器已清理"
    else
        log_message "! 警告: 容器清理可能不完整"
    fi

    # 拉取最新镜像
    log_message "正在检查并更新镜像..."
    if docker-compose pull; then
        log_message "✓ 镜像更新检查完成"
    else
        log_message "! 警告: 部分镜像可能更新失败"
    fi

    # 尝试启动容器
    log_message "正在启动容器..."
    if docker-compose up -d; then
        log_message "✓ 容器已启动，正在验证运行状态..."
        
        # 获取刚启动的容器列表
        local containers
        containers=$(docker-compose ps -q)
        local all_healthy=true
        
        # 检查每个容器的健康状态
        for container_id in $containers; do
            local container_name
            container_name=$(docker inspect --format='{{.Name}}' "$container_id" | sed 's/^\///')
            
            if ! check_container_health "$container_id" "$container_name"; then
                all_healthy=false
                log_message "! 警告: 容器 $container_name 可能未正常运行"
                # 收集容器日志以帮助诊断
                log_message "容器日志 (最后10行):"
                docker logs --tail 10 "$container_id" 2>&1 | while read -r line; do
                    log_message "  $line"
                done
            fi
        done
        
        # 显示启动的容器状态
        log_message "容器状态:"
        log_message "----------------------------------------"
        log_message "容器名称    镜像    状态    运行时间    端口"
        docker-compose ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}\t{{.Ports}}" | while read -r line; do
            log_message "$line"
        done
        log_message "----------------------------------------"

        # 清理旧镜像
        log_message "正在清理旧镜像..."
        if docker image prune -f > /dev/null 2>&1; then
            log_message "✓ 旧镜像清理完成"
        else
            log_message "! 警告: 旧镜像清理失败"
        fi

        if [ "$all_healthy" = true ]; then
            return 0
        else
            log_message "! 错误: 部分容器未能正常运行"
            return 1
        fi
    else
        log_message "! 错误: 容器启动失败"
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

log_message "开始启动所有 Docker Compose 容器..."
log_message "基础目录: $BASE_DIR"
log_message "日志文件位置: $LOG_FILE"
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
success_count=0
failed_count=0

while IFS= read -r compose_file; do
    if [ -n "$compose_file" ]; then
        dir=$(dirname "$compose_file")
        log_message "----------------------------------------"
        log_message "找到配置文件: $compose_file"
        log_message "处理目录: $dir"
        if start_containers "$dir"; then
            ((success_count++))
        else
            ((failed_count++))
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

# 计算总耗时
end_time=$(date +%s)
duration=$((end_time - start_time))
log_message "----------------------------------------"
log_message "所有容器启动操作已完成！"
log_message "共处理 $found_dirs 个目录"
log_message "成功启动: $success_count 个"
[ "$failed_count" -gt 0 ] && log_message "启动失败: $failed_count 个"
log_message "总耗时: ${duration} 秒"
log_message "完整日志已保存到: $LOG_FILE"

# 检查是否所有容器都已成功启动
if [ "$failed_count" -eq 0 ]; then
    log_message "----------------------------------------"
    log_message "所有容器启动成功，开始执行清理操作..."
    
    # 获取当前运行的容器数量
    running_containers=$(docker ps -q | wc -l)
    log_message "当前运行容器数量: $running_containers"
    
    if [ "$running_containers" -gt 0 ]; then
        # 清理未使用的网络
        log_message "----------------------------------------"
        log_message "正在清理未使用的网络..."
        unused_networks=$(docker network ls --filter "type=custom" --filter "driver=bridge" --format "{{.Name}}" | grep -v "br0" | grep -v "br1")
        if [ -n "$unused_networks" ]; then
            for network in $unused_networks; do
                # 检查网络是否有容器连接
                if [ -z "$(docker network inspect "$network" -f '{{range .Containers}}{{.Name}}{{end}}')" ]; then
                    log_message "删除未使用的网络: $network"
                    if docker network rm "$network" > /dev/null 2>&1; then
                        log_message "✓ 网络 $network 已删除"
                    else
                        log_message "! 警告: 无法删除网络 $network"
                    fi
                fi
            done
        else
            log_message "没有发现未使用的网络"
        fi

        # 清理未使用的存储卷
        log_message "----------------------------------------"
        log_message "正在清理未使用的存储卷..."
        # 获取所有存储卷列表
        volumes=$(docker volume ls -q)
        if [ -n "$volumes" ]; then
            # 检查每个存储卷
            for volume in $volumes; do
                # 检查存储卷是否被使用
                if [ -z "$(docker ps -a --filter volume="$volume" -q)" ]; then
                    # 获取存储卷详细信息用于日志
                    volume_info=$(docker volume inspect "$volume" --format '{{.Name}} ({{.Driver}})')
                    log_message "发现未使用的存储卷: $volume_info"
                    
                    # 尝试删除存储卷
                    if docker volume rm "$volume" > /dev/null 2>&1; then
                        log_message "✓ 存储卷已删除: $volume"
                    else
                        log_message "! 警告: 无法删除存储卷 $volume，可能正在被使用或有其他依赖"
                    fi
                fi
            done
        else
            log_message "没有发现任何存储卷"
        fi
        
        log_message "----------------------------------------"
        log_message "清理操作已完成"
    else
        log_message "! 警告: 未检测到运行中的容器，跳过清理操作以防止误删"
    fi
else
    log_message "----------------------------------------"
    log_message "! 警告: 由于部分容器启动失败，跳过清理操作以防止误删"
fi

# 显示如何查看容器状态
log_message "提示: 可以使用 'docker ps' 命令查看所有容器的运行状态" 