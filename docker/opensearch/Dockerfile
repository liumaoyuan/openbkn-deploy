# OpenSearch —— 兼容 ARMv8.0（Cortex-A72 / 飞腾 FT-2000 等）的自建镜像
#
# 官方镜像基于 Amazon Linux 2023，其 glibc 要求 CPU 至少 ARMv8.2-a，
# 在 ARMv8.0 机器上启动即报：
#   Fatal glibc error: This version of Amazon Linux requires a newer ARM64
#   processor compliant with at least ARM architecture 8.2-a ...
#
# 做法：只把操作系统层换成 Ubuntu（arm64 基线为 ARMv8.0），
# OpenSearch 本体、内置 JDK、插件和官方入口脚本都从官方镜像原样搬过来。
# 入口脚本会解析 discovery.type / bootstrap.memory_lock / DISABLE_SECURITY_PLUGIN
# 等环境变量并转成 -E 参数，这部分逻辑保持不变，compose.yml 无需调整。

ARG OPENSEARCH_VERSION=2.19.1

########################### 来源：官方镜像 ##########################
# 只用它的文件系统，不运行它的系统层。
FROM opensearchproject/opensearch:${OPENSEARCH_VERSION} AS upstream

########################### 运行：Ubuntu ###########################
FROM ubuntu:24.04

# 与官方镜像保持一致的环境变量（plugins/opensearch-knn 需要 LD_LIBRARY_PATH）
ENV OPENSEARCH_HOME=/usr/share/opensearch \
    JAVA_HOME=/usr/share/opensearch/jdk \
    LD_LIBRARY_PATH=/usr/share/opensearch/plugins/opensearch-knn/lib \
    LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/share/opensearch/jdk/bin:/usr/share/opensearch/bin

COPY --from=upstream /usr/share/opensearch /usr/share/opensearch

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl bash procps libnss3 \
 && rm -rf /var/lib/apt/lists/* \
 && chown -R 1000:1000 /usr/share/opensearch
# 注：Ubuntu 基础镜像自带 UID/GID 1000（ubuntu 用户），无需新建；
# USER 1000 用的是数字，用户名叫什么不影响。

USER 1000
WORKDIR /usr/share/opensearch

EXPOSE 9200 9600
ENTRYPOINT ["./opensearch-docker-entrypoint.sh"]
CMD ["opensearch"]
