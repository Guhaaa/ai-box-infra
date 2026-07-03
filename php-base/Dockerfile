# Общий базовый прод-образ PHP для всех приложений экосистемы AiBox
# (ai-box, ai-box-data-registry, ai-box-mcp). Приложения используют его как
# FROM aibox/php-base:8.3 — либо напрямую image: в compose, задавая
# working_dir и command.
#
# Сборка: make build-base (тег aibox/php-base:8.3).
# Расширения — объединение потребностей всех приложений; сейчас их наборы идентичны.

FROM php:8.3-fpm

# Системные зависимости
RUN apt-get update && apt-get install -y \
    bash \
    curl \
    libcurl4-gnutls-dev \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    libgnutls28-dev \
    zip \
    libzip-dev \
    unzip \
    libicu-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# PHP расширения
RUN docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mbstring \
        zip \
        bcmath \
        intl \
        opcache \
        pcntl \
        gd \
        sockets

# Redis расширение
RUN pecl install redis && docker-php-ext-enable redis

# Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Рабочую директорию задаёт приложение (working_dir в compose или свой Dockerfile)
WORKDIR /var/www

CMD ["php-fpm"]
