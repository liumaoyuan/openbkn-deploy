# OpenBKN Docker 单机部署说明

本文面向**非开发人员**，说明如何把 OpenBKN 部署到一台不能上外网的内网机器。

整套流程分两台机器完成：

| 角色 | 要求 | 做什么 |
|---|---|---|
| 联网机 | 能上外网，装好 Docker Desktop | 填写配置、打包镜像、下载安装包 |
| 内网机 | 麒麟 V10（或任意 Linux），**不上网** | 安装 Docker、导入镜像、启动 |

建议内网机配置：8 核 CPU、16 GB 内存、40 GB 可用磁盘。

> 这套 Compose 栈用于单机开发、演示和联调，不替代 Kubernetes/Helm 生产部署。
> 全部配置都通过**编辑文本文件**完成，不需要安装 Python 或任何其他运行时。

---

## 一、联网机：制作离线包

### 1. 准备环境

- Docker Desktop（Windows/macOS 均可）
- 源码目录保持同级：`bkn-foundry`、`bkn-studio`、`openbkn-deploy`

### 2. 填写配置

配置分两部分，**两边的密码必须一致**：

| 位置 | 作用 | 谁来读 |
|---|---|---|
| `docker/.env` | 基础设施容器的密码 | MariaDB、Redis、Kafka、MinIO 等容器 |
| `docker/config/` | 应用服务自己的配置文件 | 后端服务、Agent、Studio |

#### 2.1 填写 `.env`

```powershell
cd E:\workspace\qy\openbkn\openbkn-deploy\docker
Copy-Item .env.example .env
```

打开 `.env`，把所有 `CHANGE_ME_*` 替换成你自己的强密码。

需要生成随机密码时：

```powershell
# PowerShell：生成 32 位随机字符串
-join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})
```

```bash
# Linux / macOS / Git Bash
openssl rand -base64 24
```

注意 `OSS_CRYPTO_AES_KEY` 需要 32 个字符。

同时修改访问地址：

```
OPENBKN_PUBLIC_BASE_URL=http://192.168.1.100:8080
OPENBKN_BIND_ADDRESS=0.0.0.0
```

#### 2.2 运行时配置会自动生成

应用服务读取的 `config/` 目录由 `config-init` 容器在启动时按 `.env` 自动渲染，**不需要手工编辑，也不要把密码写进配置文件**。

- `config.template/`：模板，随仓库提供，一般不需要动
- `config/`：启动时自动生成，已加入 `.gitignore`

所以日常只需要维护 `.env` 一个文件。改完 `.env` 后执行：

```bash
docker compose --env-file .env up -d
```

`config-init` 会重新生成配置，相关服务随之重建。

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

把整个 `openbkn-deploy` 目录拷到内网机：

```
openbkn-deploy\
├── docker\              ← compose.yml、.env、config\、脚本、本说明
│   └── app\             ← Docker 安装包（见第二章）
└── build\               ← openbkn-images.tar 等镜像包
```

> `.env` 和 `config\` 里都是密码，请按敏感文件保管。

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

下载地址见文末「附录 B」。`app/checksums.txt` 是 Compose 官方校验和，可用 `sha256sum` 核对。

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

> 如果之前改过 `docker/config/` 或 `.env`，重启对应服务即可生效：
> `docker compose --env-file .env restart`

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

1. 在联网机用新版本源码重新打包镜像；
2. 把新镜像包拷到内网机，`bash load-images.sh` 导入；
3. `docker compose --env-file .env up -d` 重建容器。

数据库升级由 `data-migrator` 自动完成，**命名卷里的数据会保留**。
`docker/.env` 与 `docker/config/` 可以继续沿用，除非新版本说明里要求新增配置项。

---

## 六、常见问题

**页面打不开**

1. 确认内网机防火墙放行了 8080 端口；
2. 确认 `.env` 里 `OPENBKN_BIND_ADDRESS=0.0.0.0`；
3. 确认浏览器访问的地址与 `OPENBKN_PUBLIC_BASE_URL` 完全一致（IP、端口、http/https）。

**登录失败 / 页面反复刷新**

几乎都是访问地址与 `OPENBKN_PUBLIC_BASE_URL` 不一致导致：

```bash
# 修改 .env 后重启
docker compose --env-file .env up -d
```

**服务报“Access denied”“认证失败”**

不要手工改 `config/`（它会被 `config-init` 覆盖）。直接改 `.env` 里对应的密码，然后：

```bash
docker compose --env-file .env up -d
```

如果容器是从旧版本遗留的，配置目录里可能残留旧值。正确顺序是：

```bash
docker compose --env-file .env down
rm -rf config
docker compose --env-file .env up -d
```

不要在容器运行期间直接删除 `config/`，否则 Docker Desktop 可能残留挂载缓存，之后创建目录会报 "file exists"。

**Docker 起不来**

```bash
journalctl -u docker -n 100 --no-pager
```

麒麟 V10 还要确认 KySec 没有拦截 `dockerd`、`containerd` 或相关内核模块。

**磁盘空间不足**

镜像约 2.8 GB，运行后数据库、对象存储、日志还会继续增长，建议预留 40 GB 以上。

**端口被占用**

修改 `.env` 里的 `OPENBKN_HTTP_PORT`，同时同步修改 `OPENBKN_PUBLIC_BASE_URL` 的端口，然后 `docker compose --env-file .env up -d`。

---

## 附录 A：目录结构

```
openbkn-deploy/
├── docker/
│   ├── compose.yml              服务编排
│   ├── .env.example             配置模板（复制为 .env 后填写）
│   ├── .env                     本机配置与密码（不提交）
│   ├── config.template/         运行时配置模板（由 config-init 渲染）
│   ├── config/                  自动生成的运行时配置（不提交）
│   ├── render-config.sh         config-init 使用的渲染脚本
│   ├── app/                     Docker 安装包（按架构）
│   ├── gateway.conf             网关路由
│   ├── mariadb-init.sql         数据库初始化
│   ├── package-images.sh/.ps1   打包镜像（联网机）
│   ├── load-images.sh/.ps1      导入镜像（内网机）
│   ├── install-docker.sh        安装 Docker（内网机）
│   └── Docker部署说明.md        本文档
└── build/
    ├── openbkn-images.tar       镜像包
    ├── openbkn-images.tar.sha256
    └── images.txt
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

下载后可用 `checksums.txt` 核对完整性。

## 附录 C：安全提醒

- 只有 Gateway 的 8080 端口暴露给宿主机，数据库、Redis、Kafka、OpenSearch 等只在 Docker 网络内可见。
- `.env` 与 `config/` 保存所有密码，连同内网机一起按敏感资料管理。
- 本栈未配置 TLS；如需对外网或不可信网络开放，请在前面加一层 HTTPS 反向代理。
- OpenSearch 在开发栈中关闭了安全插件，不要在生产环境复用此配置。
- 修改密码不会自动轮换已有数据库里的凭据，修改前先备份数据。
