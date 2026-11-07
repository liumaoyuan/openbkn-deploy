CREATE DATABASE IF NOT EXISTS openbkn CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS safe CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS bkn_trace CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS sandbox CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS adp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS oss_gateway CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
-- data-migrator 的迁移管控库（t_schema_migration_task / history）
CREATE DATABASE IF NOT EXISTS deploy CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
-- agent-observability 的审计事件库（migration 031 建表）
CREATE DATABASE IF NOT EXISTS bkn_audit CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

GRANT ALL PRIVILEGES ON bkn_audit.* TO 'openbkn'@'%';

GRANT ALL PRIVILEGES ON deploy.* TO 'openbkn'@'%';
GRANT ALL PRIVILEGES ON safe.* TO 'openbkn'@'%';
GRANT ALL PRIVILEGES ON bkn_trace.* TO 'openbkn'@'%';
GRANT ALL PRIVILEGES ON sandbox.* TO 'openbkn'@'%';
GRANT ALL PRIVILEGES ON adp.* TO 'openbkn'@'%';
GRANT ALL PRIVILEGES ON oss_gateway.* TO 'openbkn'@'%';
