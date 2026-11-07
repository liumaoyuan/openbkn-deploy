# OpenBKN Docker Compose 部署说明

此 Compose 栈用于单机开发、功能演示和联调。它从当前工作区的 bkn-foundry 与 bkn-studio 源码构建镜像；首次构建需要可访问 Docker Hub、GHCR、Go modules 和 Python 包源。它不替代 Kubernetes/Helm 生产部署，也未配置 TLS、高可用、备份策略或生产级密钥管理。

## 环境要求

- Docker Engine 或 Docker Desktop，包含 Docker Compose v2；Windows/macOS 使用 Linux 容器模式。
- Python 3.10 或更高版本，以及 PyYAML。
- 对象存储使用 PGSTY Silo（MinIO fork），兼容此开发栈所需的 S3 接口；Compose 固定使用已验证可拉取的镜像版本。
- 建议至少 8 核 CPU、16 GiB 内存和 40 GiB 可用磁盘。OpenSearch、Kafka 和多项模型服务会占用较多资源。
- 从工作区根目录保留 bkn-foundry、bkn-studio、openbkn-deploy 三个目录的相对位置。

首次使用前安装 PyYAML 并生成本机密钥和运行时配置：

~~~powershell
Set-Location E:/workspace/qy/openbkn/openbkn-deploy/docker
python -m pip install PyYAML
python .\init.py
docker compose --env-file .env config --quiet
~~~

初始化脚本首次创建本地 .env，后续不会覆盖它；生成的 .env 不应提交到版本库。把 OPENBKN_PUBLIC_BASE_URL 改为用户浏览器实际访问 Gateway 的 URL，并确保 OPENBKN_HTTP_PORT 与 URL 端口一致。默认仅监听本机 127.0.0.1:8080。需要局域网访问时，将绑定地址改为 0.0.0.0，并设置实际 IP 或域名。

## 启动与日常操作

从 openbkn-deploy/docker 执行：

~~~powershell
docker compose --env-file .env up --build -d
docker compose --env-file .env ps
docker compose --env-file .env logs -f gateway
~~~

Compose 会先等待 MariaDB、PostgreSQL、Redis、Kafka、OpenSearch 和 MinIO 就绪，再执行 Hydra SQL migration 与 OpenBKN 数据库迁移，然后启动应用。Studio 入口为 http://localhost:8080/studio/；API、登录页和 OAuth/OIDC 公共端点由同一个 Gateway 提供。

如果构建时报错 `failed to fetch anonymous token`、`auth.docker.io` 连接超时或多个基础镜像拉取被中断，这是 Docker Engine 到 Docker Hub 的网络连接问题，不是 Compose YAML 配置问题。先单独验证失败日志中提到的基础镜像：

~~~powershell
docker pull docker.io/library/golang:1.26.9
docker pull docker.io/library/python:3.11-slim
docker pull docker.io/library/ubuntu:22.04
~~~

如果这些命令也在 `auth.docker.io` 超时，检查 Docker Desktop 的代理/VPN/DNS/防火墙设置，或配置组织提供的 Docker Hub Registry Mirror；`docker login` 不能修复 TCP 连接超时。确认镜像可拉取后再重试：

~~~powershell
docker compose --env-file .env up --build -d
~~~

查看全部日志：

~~~powershell
docker compose --env-file .env logs -f
~~~

停止但保留数据：

~~~powershell
docker compose --env-file .env down
~~~

数据保存在 Compose 命名卷。重新构建应用镜像可执行 docker compose --env-file .env build，之后再执行 up -d。

## 离线 / 内网迁移

把整套栈搬到不能访问外网的内网机器时，镜像不是全部。运行期还依赖本目录下的 compose 配置、渲染出来的运行时配置和一次性初始化（Hydra 客户端注册、数据库初始化），这些都不在镜像里。

### 构建来源

应用镜像由 `docker compose build` 从**本机工作区源码**构建（`../../bkn-foundry`、`../../bkn-studio`），不使用 GitHub Actions 发布的镜像。也就是说，打出来的镜像包含当前工作区的代码状态（包括未提交的改动）。如果需要可复现的产物，应当先在干净检出的对应分支上构建。

### 在联网机器上打包

~~~powershell
cd openbkn-deploy/docker

# 方式一：Git Bash
bash package-images.sh              # 构建 + 导出全部镜像
bash package-images.sh --list       # 只查看清单与体积

# 方式二：纯 PowerShell（无需 Git Bash）
powershell -File .\package-images.ps1
powershell -File .\package-images.ps1 -List
~~~

> PowerShell 里直接输入 `bash` 可能命中 WSL 的启动器（`C:\Windows\System32\bash.exe`）。若 WSL 没有可用发行版，会报 `execvpe(/bin/bash) failed: No such file or directory`——改用 Git Bash 的完整路径，或直接用 `.ps1` 版本。
>
> Windows 客户端默认执行策略为 `Restricted`，脚本可能被拦截。可选：`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`（一次性），或单次运行加 `-ExecutionPolicy Bypass`。

产物（默认写到 `openbkn-deploy/build/`）：

- `openbkn-images.tar`：23 个镜像（14 个应用镜像 + 9 个运行期依赖），约 2.8 GB
- `openbkn-images.tar.sha256`：校验和
- `images.txt`：镜像清单

应用镜像名固定为 `openbkn/<service>:<tag>`，`<tag>` 由 `.env` 中的 `OPENBKN_IMAGE_TAG` 决定，默认 `local`。

### 在内网机器上导入

需要提前准备 Docker Engine、Docker Compose v2，以及同架构的运行环境（`docker version` 查看 `Os/Arch`）。

~~~powershell
cd openbkn-deploy/docker

# Git Bash
bash load-images.sh                 # 校验 sha256 → docker load → 逐个核对镜像

# 或者纯 PowerShell
powershell -File .\load-images.ps1
~~~

然后生成配置并启动：

~~~bash
cp .env.example .env
# 修改 OPENBKN_BIND_ADDRESS=0.0.0.0 和 OPENBKN_PUBLIC_BASE_URL=http://<内网IP>:8080
python3 init.py
docker compose --env-file .env up -d      # 不要加 --build
~~~

### 注意事项

- **Hydra 的 OAuth 客户端存在 PostgreSQL 数据卷里**。内网机器上必须让数据卷从空开始，`hydra-client-seed` 才会按新的 `OPENBKN_PUBLIC_BASE_URL` 注册 `openbkn-studio`；拷贝旧数据卷会导致回调地址仍是旧 URL，登录失败。
- **沙箱执行模板镜像不在打包范围内**：`sandbox-control-plane` 运行时会按自身配置拉取执行模板镜像，内网环境需要自备并改配置，否则代码执行类功能不可用。
- **模型服务需要单独准备**：`mf-model-*` 只是管理面，推理走你在 Studio 里配置的模型提供商。
- 修改 `OPENBKN_PUBLIC_BASE_URL` 后需要重新执行 `init.py`，并重启 `gateway`、`bkn-safe`、`studio`、`hydra`。

## 安全与限制

- Gateway 是唯一发布到宿主机的服务端口。数据库、Kafka、Redis、OpenSearch、MinIO、Hydra 管理端及内部 API 只在 Docker 网络内可达。
- OpenSearch 在此开发栈中关闭 Security Plugin，且没有映射宿主机端口，不应在生产或不可信网络中直接复用该配置。
- Sandbox 控制面挂载 Docker Socket，以便创建执行容器。能访问 Docker Socket 的进程通常拥有宿主机级控制权限；不要在共享主机或生产环境运行此开发 Compose。
- Sandbox 执行镜像由控制面按其默认配置拉取。隔离执行还依赖宿主机 Docker 的安全配置；Compose 中禁用了 Bubblewrap，仅供本地开发测试。
- MinIO 和 Hydra 使用生成的本地密钥；修改 .env 中密钥不会自动轮换已初始化数据库/存储中的凭据。妥善保管 .env，轮换前先备份数据并按服务文档执行。
- Hydra 对浏览器声明的 Issuer 和 Studio 回调依赖 OPENBKN_PUBLIC_BASE_URL。更改访问地址后，重新生成配置并重建或重启相关服务。
- 应用服务的健康检查不完整；docker compose ps 显示容器运行不代表所有业务流程已验收。模型服务还需要在 Studio 中配置实际模型提供商和凭据。
- 默认 Trace Evidence 内容存储为进程内存；单机测试可用，重启后会丢失。不要将其当作审计归档。

## 数据维护

先停止服务，再使用数据库与对象存储自身工具备份 named volumes。删除卷会永久删除对应数据库、Kafka、OpenSearch、Redis 或 MinIO 数据。

~~~
docker compose --env-file .env down
~~~

不要执行 docker compose down -v，除非明确要清空所有本地数据。
