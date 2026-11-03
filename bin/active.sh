#!/bin/sh

DEVOPS_KIT_DIR="/opt/apps/devops-kit"
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
