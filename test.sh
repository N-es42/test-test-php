#!/bin/bash

# CloudLinux - Tum PHP surumlerinde INI guncelleme
# ALT-PHP + EA-PHP + Native PHP

set -u

POST_MAX="32M"
UPLOAD_MAX="32M"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SUCCESS=0
FAIL=0
TOTAL=0
CHANGED=0

if [ "$(id -u)" -ne 0 ]; then
    echo "Bu script root olarak calistirilmali."
    exit 1
fi

BACKUP_DATE=$(date +%Y%m%d_%H%M%S)

update_ini() {
    local INI="$1"

    [ -f "$INI" ] || return 0

    echo ""
    echo "Guncelleniyor: $INI"

    if ! cp -p "$INI" "${INI}.bak.${BACKUP_DATE}"; then
        echo -e "${RED}FAIL - Yedek alinamadi${NC}"
        FAIL=$((FAIL + 1))
        return 1
    fi

    # Onceki aktif tanimlari kaldir.
    if ! sed -i -E \
        '/^[[:space:]]*(post_max_size|upload_max_filesize)[[:space:]]*=/d' \
        "$INI"; then
        echo -e "${RED}FAIL - INI duzenlenemedi${NC}"
        FAIL=$((FAIL + 1))
        return 1
    fi

    # Yeni degerleri ekle.
    if ! printf '\npost_max_size = %s\nupload_max_filesize = %s\n' \
        "$POST_MAX" "$UPLOAD_MAX" >> "$INI"; then
        echo -e "${RED}FAIL - INI yazilamadi${NC}"
        FAIL=$((FAIL + 1))
        return 1
    fi

    CHANGED=$((CHANGED + 1))
    echo -e "${GREEN}OK - INI guncellendi${NC}"
}

verify_php() {
    local PHP_BIN="$1"
    local VERSION
    local POST_VALUE
    local UPLOAD_VALUE

    [ -x "$PHP_BIN" ] || return 0

    TOTAL=$((TOTAL + 1))

    VERSION=$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)

    POST_VALUE=$("$PHP_BIN" -r \
        'echo ini_get("post_max_size");' 2>/dev/null)

    UPLOAD_VALUE=$("$PHP_BIN" -r \
        'echo ini_get("upload_max_filesize");' 2>/dev/null)

    echo ""
    echo "PHP ${VERSION:-unknown} - $PHP_BIN"

    if [ "$POST_VALUE" = "$POST_MAX" ]; then
        echo -e "post_max_size: ${GREEN}OK ($POST_VALUE)${NC}"
        SUCCESS=$((SUCCESS + 1))
    else
        echo -e "post_max_size: ${RED}FAIL ($POST_VALUE)${NC}"
        FAIL=$((FAIL + 1))
    fi

    if [ "$UPLOAD_VALUE" = "$UPLOAD_MAX" ]; then
        echo -e "upload_max_filesize: ${GREEN}OK ($UPLOAD_VALUE)${NC}"
        SUCCESS=$((SUCCESS + 1))
    else
        echo -e "upload_max_filesize: ${RED}FAIL ($UPLOAD_VALUE)${NC}"
        FAIL=$((FAIL + 1))
    fi
}

echo "======================================"
echo " CloudLinux PHP INI Guncelleme"
echo "======================================"

# ALT-PHP
for DIR in /opt/alt/php[0-9]*; do
    [ -d "$DIR" ] || continue
    update_ini "$DIR/etc/php.ini"
done

# EA-PHP
for DIR in /opt/cpanel/ea-php[0-9]*; do
    [ -d "$DIR" ] || continue
    update_ini "$DIR/root/etc/php.ini"
done

# Native PHP
if [ -f /etc/php.ini ]; then
    update_ini /etc/php.ini
fi

echo ""
echo "======================================"
echo " PHP Servisleri Yeniden Baslatiliyor"
echo "======================================"

# cPanel PHP-FPM
if [ -x /scripts/restartsrv_apache_php_fpm ]; then
    /scripts/restartsrv_apache_php_fpm
fi

# Calisan PHP-FPM servisleri
if command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r SERVICE; do
        [ -n "$SERVICE" ] || continue

        echo "Restart: $SERVICE"
        if ! systemctl restart "$SERVICE"; then
            echo -e "${RED}FAIL - Restart: $SERVICE${NC}"
            FAIL=$((FAIL + 1))
        fi
    done < <(
        systemctl list-units --type=service \
            --state=running --no-legend --plain |
        awk '{print $1}' |
        grep -E '^(ea-php[0-9]+-php-fpm|alt-php[0-9]+-php-fpm|php-fpm)\.service$' || true
    )

    # LiteSpeed / OpenLiteSpeed
    for SERVICE in lsws.service lshttpd.service; do
        if systemctl is-active --quiet "$SERVICE"; then
            echo "Restart: $SERVICE"
            if ! systemctl restart "$SERVICE"; then
                echo -e "${RED}FAIL - Restart: $SERVICE${NC}"
                FAIL=$((FAIL + 1))
            fi
        fi
    done

     # LiteSpeed LSAPI PHP worker'larini yenile
    if [ -d /usr/local/lsws/admin/tmp ]; then
        if touch /usr/local/lsws/admin/tmp/.lsphp_restart.txt; then
            echo -e "${GREEN}OK - LiteSpeed PHP worker restart tetiklendi${NC}"
        else
            echo -e "${RED}FAIL - LiteSpeed PHP worker restart${NC}"
            FAIL=$((FAIL + 1))
        fi
    fi
fi

# LiteSpeed PHP worker'larini yenile
if [ -d /usr/local/lsws/admin/tmp ]; then
    touch /usr/local/lsws/admin/tmp/.lsphp_restart.txt
    echo "OK - LiteSpeed PHP worker restart tetiklendi"
fi

echo ""
echo "======================================"
echo " PHP ini_get() Dogrulama"
echo "======================================"

# ALT-PHP kontrol
for DIR in /opt/alt/php[0-9]*; do
    verify_php "$DIR/usr/bin/php"
done

# EA-PHP kontrol
for DIR in /opt/cpanel/ea-php[0-9]*; do
    verify_php "$DIR/root/usr/bin/php"
done

# Native PHP kontrol
if [ -x /usr/bin/php ] && [ -f /etc/php.ini ]; then
    verify_php /usr/bin/php
fi

echo ""
echo "======================================"
echo " SONUC"
echo "======================================"
echo "Kontrol edilen PHP: $TOTAL"
echo "Guncellenen INI: $CHANGED"
echo -e "Basarili kontrol: ${GREEN}$SUCCESS${NC}"
echo -e "Basarisiz kontrol: ${RED}$FAIL${NC}"

if [ "$FAIL" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
    echo -e "${GREEN}OK OK OK OK - Tum kontroller basarili${NC}"
    exit 0
else
    echo -e "${RED}FAIL - Kontrol gerektiren ayarlar var${NC}"
    exit 1
fi
