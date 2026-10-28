#!/bin/sh
# devops-kit PATH 脚本（兼容 bash / zsh / sh）
# 把 tools/ 下 docker、git、elasticsearch、nexus 四个目录加到 PATH

DEVOPS_KIT_DIR=$(cd "$(dirname "$0")/.." && pwd)
export DEVOPS_KIT_DIR

TOOLS_DIR="$DEVOPS_KIT_DIR/tools"
export TOOLS_DIR

for d in docker git elasticsearch nexus; do
    dir="$TOOLS_DIR/$d"
    [ -d "$dir" ] || continue
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) PATH="$dir:$PATH" ;;
    esac
done

export PATH
