# OpenBKN Docker 单机部署说明

本文面向**非开发人员**，说明如何把 OpenBKN 部署到一台不能上外网的内网机器。

整套流程分两台机器完成：

| 角色 | 要求 | 做什么 |
|---|---|---|
| 联网机 | 能上外网，装好 Docker Desktop 和 Python | 生成配置、打包镜像、下载安装包 |
| 内网机 | 麒麟 V10（或任意 Linux），**不上网** | 安装 Docker、导入镜像、启动 |

建议内网机配置：8 核 CPU、16 GB 内存、40 GB 可用磁盘。

> 这套 Compose 栈用于单机开发、演示和联调，不替代 Kubernetes/Helm 生产部署。

---

## 一、联网机：制作离线包

### 1. 准备环境

- Docker Desktop（Windows/macOS 均可）
- Python 3.10 或更高版本
- PyYAML（只用来渲染配置，装一次即可）：

```powershell
python -m pip install pyyaml
```

- 源码目录保持同级：`bkn-foundry`、`bkn-studio`、`openbkn-deploy`

### 2. 生成配置

把地址换成内网机实际要用的 IP 和端口：

```powershell
cd E:\workspace\qy\openbkn\openbkn-deploy\docker
python init.py --public-base-url http://192.168.1.100:8080
```

这条命令会：

- 首次运行时生成 `docker\.env`（自动填入随机密码）
- 把对外访问地址写成 `http://192.168.1.100:8080`
- 自动把监听地址设为 `0.0.0.0`，允许其他机器访问
- 在 `openbkn-deploy\build\docker\config` 下生成运行时配置

> 地址必须和内网机实际访问地址完全一致，否则登录会失败。
> 只想在本机试用时，直接运行 `python init.py` 即可（默认 `http://localhost:8080`）。

### 3. 打包镜像

Git Bash：

```powershell
bash package-images.sh
```

或纯 PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\package-images.ps1
```

产物在 `openbkn-deploy\build\`：

| 文件 | 说明 |
|---|---|
| `openbkn-images.tar` | 23 个镜像，约 2.8 GB |
| `openbkn-images.tar.sha256` | 校验和 |
| `images.txt` | 镜像清单 |

### 4. 拷贝到内网机

把整个 `openbkn-deploy` 目录拷到内网机（U 盘、移动硬盘、内网文件服务器均可）：

```
openbkn-deploy\
├── docker\          ← 必须：compose.yml、.env、脚本、本说明
└── build\           ← 必须：openbkn-images.tar、docker\config 运行时配置
```

> `docker\.env` 里有数据库、对象存储和初始管理员密码，请按敏感文件保管。

---

## 二、内网机：安装 Docker

### 1. 确认安装文件

安装包放在 `docker/app/` 下，按内网机架构选择（`uname -m` 输出 `x86_64` 或 `aarch64`）：

```
docker/app/
├── amd64/
│   ├── docker-28.5.2.tgz
│   └── docker-compose-linux-x86_64
└── arm64/
    ├── docker-28.5.2.tgz
    └── docker-compose-linux-aarch64
```

下载地址见文末「附录 B」，文件名保持原样即可，不需要重命名。
`app/checksums.txt` 是 Compose 官方校验和，可用 `sha256sum` 核对。

### 2. 执行安装

在 `docker` 目录下按架构执行其中一条：

```bash
# x86_64
sudo bash install-docker.sh app/amd64/docker-28.5.2.tgz app/amd64/docker-compose-linux-x86_64

# aarch64（飞腾 / 鲲鹏）
sudo bash install-docker.sh app/arm64/docker-28.5.2.tgz app/arm64/docker-compose-linux-aarch64
```

脚本会安装 Docker 引擎和 Compose 插件、写入日志轮转配置、启动服务，最后自动自检：

```
Docker Engine 28.5.2 (linux/amd64)
Docker Compose version v2.32.4
```

看到这两行即安装成功。

---

## 三、内网机：导入镜像并启动

```bash
cd /path/to/openbkn-deploy/docker

# 1. 导入并核对镜像（优先校验 sha256）
bash load-images.sh

# 2. 启动
docker compose --env-file .env up -d
```

首次启动会自动初始化数据库和执行数据迁移，大约 1~3 分钟。查看进度：

```bash
docker compose --env-file .env ps
```

全部服务显示 `Up` 即启动完成。

---

## 四、登录系统

浏览器打开：

```
http://192.168.1.100:8080/studio/
```

- 用户名：`admin`
- 初始密码：`docker/.env` 里的 `BKN_SAFE_INITIAL_PASSWORD`

查看密码：

```bash
grep BKN_SAFE_INITIAL_PASSWORD .env
```

> 首次登录后请尽快修改管理员密码。第一次打开页面如果显示异常，按 `Ctrl+Shift+R` 强制刷新一次。

---

## 五、日常操作

```bash
cd /path/to/openbkn-deploy/docker

docker compose --env-file .env ps                  # 查看状态
docker compose --env-file .env logs -f gateway     # 查看网关日志
docker compose --env-file .env restart             # 重启全部服务
docker compose --env-file .env down                # 停止（保留数据）
docker compose --env-file .env up -d               # 再次启动
```

> **不要执行 `docker compose down -v`**，它会删除所有数据卷，数据无法恢复。

### 版本升级

1. 在联网机用新版本源码重新执行第 2、3 步，生成新的镜像包和配置；
2. 把新包拷到内网机，`bash load-images.sh` 导入；
3. `docker compose --env-file .env up -d` 重建容器。

数据库升级由 `data-migrator` 自动完成，**命名卷里的数据会保留**。

---

## 六、常见问题

**页面打不开**

1. 确认内网机防火墙放行了 8080 端口；
2. 确认 `.env` 里 `OPENBKN_BIND_ADDRESS=0.0.0.0`；
3. 确认浏览器访问的地址与 `OPENBKN_PUBLIC_BASE_URL` 完全一致（IP、端口、http/https）。

**Docker 起不来**

```bash
journalctl -u docker -n 100 --no-pager
```

麒麟 V10 还要确认 KySec 没有拦截 `dockerd`、`containerd` 或相关内核模块。

**登录失败 / 页面反复刷新**

几乎都是访问地址与 `OPENBKN_PUBLIC_BASE_URL` 不一致导致。

改地址最简单的方式是直接在内网机编辑 `docker/.env`：

```bash
# 修改这两行（端口有变化时一起改）
OPENBKN_PUBLIC_BASE_URL=http://192.168.1.100:8080
OPENBKN_HTTP_PORT=8080

docker compose --env-file .env up -d
```

这个地址是容器启动时读取的，不需要重新渲染配置。

只有在**同时改动了密码类配置**（数据库、Redis、MinIO 等）时，才需要回联网机重新执行 `python init.py` 并重新打包配置。

**磁盘空间不足**

镜像约 2.8 GB，运行后数据库、对象存储、日志还会继续增长，建议预留 40 GB 以上。

**端口被占用**

修改 `.env` 里的 `OPENBKN_HTTP_PORT`，同时同步修改 `OPENBKN_PUBLIC_BASE_URL` 的端口，然后重新执行 `init.py`。

---

## 附录 A：目录结构

```
openbkn-deploy/
├── docker/
│   ├── compose.yml              服务编排
│   ├── .env                     本机配置与密码（不要外传）
│   ├── gateway.conf            网关路由
│   ├── mariadb-init.sql        数据库初始化
│   ├── init.py                 生成配置（仅联网机需要）
│   ├── render_config.py        渲染配置（仅联网机需要）
│   ├── package-images.sh/.ps1  打包镜像（联网机）
│   ├── load-images.sh/.ps1     导入镜像（内网机）
│   ├── install-docker.sh       安装 Docker（内网机）
│   └── Docker部署说明.md        本文档
└── build/
    ├── openbkn-images.tar      镜像包
    ├── openbkn-images.tar.sha256
    ├── images.txt
    └── docker/config/          运行时配置（不要手动改）
```

## 附录 B：安装包下载地址

**Docker 静态包（28.5.2）**

```
# x86_64
https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/static/stable/x86_64/docker-28.5.2.tgz
https://mirrors.ustc.edu.cn/docker-ce/linux/static/stable/x86_64/docker-28.5.2.tgz

# aarch64（飞腾 / 鲲鹏）
https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/static/stable/aarch64/docker-28.5.2.tgz
https://mirrors.ustc.edu.cn/docker-ce/linux/static/stable/aarch64/docker-28.5.2.tgz
```

**Compose 插件（v2.32.4）**

```
https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64
https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-aarch64
https://github.com/docker/compose/releases/download/v2.32.4/checksums.txt
```

下载后可用 `checksums.txt` 核对完整性，并把文件重命名为 `docker-compose`。

## 附录 C：安全提醒

- 只有 Gateway 的 8080 端口暴露给宿主机，数据库、Redis、Kafka、OpenSearch 等只在 Docker 网络内可见。
- `.env` 保存所有密码，连同内网机一起按敏感资料管理。
- 本栈未配置 TLS；如需对外网或不可信网络开放，请在前面加一层 HTTPS 反向代理。
- OpenSearch 在开发栈中关闭了安全插件，不要在生产环境复用此配置。
- 修改 `.env` 中的密码不会自动轮换已有数据库里的凭据，修改前先备份数据。
