#!/bin/bash

# ================= 配置项 =================
NEXUS_URL="https://nexus.zaqbest.com"  # Nexus 地址，不要以 / 结尾
USERNAME="admin"                          # 管理员用户名
PASSWORD="admin123"                  # 管理员密码
REPOSITORY="maven-releases"               # 要清理的仓库名称
KEEP_COUNT=3                              # 每个组件保留的最新版本数量
DRY_RUN=false                              # true 为演练模式（只打印不删除），false 为真正执行删除
# ==========================================

AUTH="${USERNAME}:${PASSWORD}"
API_URL="${NEXUS_URL}/service/rest/v1"

echo "开始连接 Nexus: ${NEXUS_URL}, 仓库: ${REPOSITORY}"

# 1. 分页获取所有组件并存储到临时文件
TMP_FILE=$(mktemp)
CONTINUATION_TOKEN=""

while true; do
    URL="${API_URL}/components?repository=${REPOSITORY}"
    if [ -n "$CONTINUATION_TOKEN" ]; then
        URL="${URL}&continuationToken=${CONTINUATION_TOKEN}"
    fi

    RESPONSE=$(curl -s -u "$AUTH" "$URL")

    if echo "$RESPONSE" | jq -e '.items' >/dev/null 2>&1; then
        echo "$RESPONSE" | jq -c '.items[]' >> "$TMP_FILE"
    else
        echo "获取组件失败或已结束: $RESPONSE"
        break
    fi

    CONTINUATION_TOKEN=$(echo "$RESPONSE" | jq -r '.continuationToken // empty')
    [ -z "$CONTINUATION_TOKEN" ] && break
done

TOTAL_COUNT=$(wc -l < "$TMP_FILE")
echo "共获取到 ${TOTAL_COUNT} 个构件记录。"

# 2. 提取所有唯一的 (group, name) 组合
UNIQUE_GROUPS_NAMES=$(jq -r '[.group, .name] | @tsv' "$TMP_FILE" | sort -u)

DELETED_COUNT=0

# 3. 遍历每个唯一组件
while IFS=$'\t' read -r GROUP NAME; do
    [ -z "$NAME" ] && continue
    
    echo ""
    echo "--------------------------------------------------"
    echo "检查组件: ${GROUP}:${NAME}"

    # 获取该组件下的所有版本，并按版本降序排序 (sort -V)
    # 输出格式: version \t id
    VERSIONS_DATA=$(jq -r --arg g "$GROUP" --arg n "$NAME" \
        'select(.group == $g and .name == $n) | [.version, .id] | @tsv' "$TMP_FILE" | \
        sort -V -r)

    TOTAL_VERSIONS=$(echo "$VERSIONS_DATA" | grep -c .)
    echo "  -> 总版本数: ${TOTAL_VERSIONS}"

    # 用计数器替代 mapfile，逐行读取排序后的版本数据
    INDEX=0
    while IFS=$'\t' read -r VERSION ID; do
        [ -z "$VERSION" ] && continue

        if [ "$INDEX" -lt "$KEEP_COUNT" ]; then
            echo "  -> [保留] 版本: ${VERSION} (ID: ${ID})"
        else
            if [ "$DRY_RUN" = true ]; then
                echo "  -> [DRY-RUN 模拟删除] 版本: ${VERSION} (ID: ${ID})"
            else
                echo -n "  -> [正在删除] 版本: ${VERSION} (ID: ${ID}) ... "
                DEL_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -u "$AUTH" "${API_URL}/components/${ID}")
                if [ "$DEL_RESP" -eq 204 ]; then
                    echo "成功"
                    DELETED_COUNT=$((DELETED_COUNT + 1))
                else
                    echo "失败 (HTTP状态码: ${DEL_RESP})"
                fi
            fi
        fi
        INDEX=$((INDEX + 1))
    done <<< "$VERSIONS_DATA"

done <<< "$UNIQUE_GROUPS_NAMES"

# 清理临时文件
rm -f "$TMP_FILE"

echo ""
echo "=================================================="
if [ "$DRY_RUN" = true ]; then
    echo "当前为模拟运行 (DRY_RUN=true)，未实际删除任何文件。确认无误后请将脚本中的 DRY_RUN 改为 false。"
else
    echo "清理完成！共成功删除了 ${DELETED_COUNT} 个旧版本。"
    echo "提示：清理完成后建议登录 Nexus 管理后台执行 Compact Blob Store 任务来释放磁盘空间。"
fi

