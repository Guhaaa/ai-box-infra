#!/usr/bin/env bash
# Идемпотентный пост-деплой infra-стека (вызывается make eco-deploy после up).
# Повтор безопасен. STAND экспортирован Makefile'ом. Для infra шаг тонкий —
# перечитка nginx с рендером шаблонов: штатный envsubst образа nginx отрабатывает
# только в entrypoint при старте, поэтому после git pull шаблонов нужен явный
# render+test+reload (см. цель nginx-reload и грабку ai-box-back-99co).
#
# ВНИМАНИЕ: certs-init сюда НЕ входит — он занимает :80 в standalone-режиме и
# конфликтует с уже работающим nginx. Первичный сертификат — ручной шаг ДО
# первого up (см. Makefile: certs-init).
#
# App-репо наследуют этот файл как ШАБЛОН и дописывают свои идемпотентные шаги:
# php artisan migrate --force; php artisan queue:restart;
# php artisan mcp:register-config-builtin — каждый повтор безопасен.
set -euo pipefail

STAND="${STAND:-local}"
echo "[post-deploy] stand=${STAND}"

make nginx-reload

echo "[post-deploy] done"
