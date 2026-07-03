#!/bin/bash
# Создание баз и пользователей приложений экосистемы. Выполняется entrypoint'ом
# MariaDB ТОЛЬКО при первой инициализации пустого volume. Пароли приходят из
# environment сервиса mariadb (см. docker-compose.yml / .env).
set -euo pipefail

mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS ai_box     CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS ai_box_dr  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS ai_box_mcp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'ai_box'@'%'     IDENTIFIED BY '${AI_BOX_DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'ai_box_dr'@'%'  IDENTIFIED BY '${AI_BOX_DR_DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'ai_box_mcp'@'%' IDENTIFIED BY '${AI_BOX_MCP_DB_PASSWORD}';

GRANT ALL PRIVILEGES ON ai_box.*     TO 'ai_box'@'%';
GRANT ALL PRIVILEGES ON ai_box_dr.*  TO 'ai_box_dr'@'%';
GRANT ALL PRIVILEGES ON ai_box_mcp.* TO 'ai_box_mcp'@'%';

FLUSH PRIVILEGES;
SQL
