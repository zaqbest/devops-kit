# v2rayA 安装脚本

`install.sh` 用于在 **Debian、Ubuntu、CentOS** 上自动安装或更新 v2rayA。

## 使用方式

```bash
cd /path/to/devops-kit/v2raya
sudo ./install.sh
```

脚本会：

1. 检查操作系统和 root 权限；
2. 使用系统包管理器安装 `curl`、`unzip` 和 `ca-certificates`；
3. 下载并执行 v2rayA 官方安装器，由官方安装器选择最新版本、系统架构并校验文件；
4. 重新加载 systemd，启动 v2rayA，并设置为开机启动。

支持的包管理器：

- Debian / Ubuntu：`apt-get`
- CentOS：优先使用 `dnf`，否则使用 `yum`

## 参数

```bash
sudo ./install.sh --no-start    # 安装但不启动服务
sudo ./install.sh --no-enable   # 不设置开机启动
sudo ./install.sh --help
```

安装完成后访问：`http://服务器IP:2017`。

> 脚本需要联网，并且会从 v2rayA 官方 GitHub 仓库获取安装器。