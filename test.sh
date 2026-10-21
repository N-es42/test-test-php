#!/bin/bash

# CloudLinux PHP INI Update
# ALT-PHP + EA-PHP + Native PHP
# cPanel + LiteSpeed / LSAPI
# PHP 5.6 dahil tum kurulu surumler

set -u
set -o pipefail

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
LSAPI_STATUS="NOT_APPLICABLE"
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)

if [ "$(id -u)" -ne 0 ]; then
    echo "FAIL - Root yetkisi gerekli"
    exit 1
fi

ok() {
    echo -e "${GREEN}OK - $1${NC}"
}

fail() {
    echo -e "${RED}FAIL - $1${NC}"
    FAIL=$((FAIL + 1))
}

warn() {
    echo -e "${YELLOW}UYARI - $1${NC}"
}

section() {
    echo ""
    echo "======================================"
    echo " $1"
    echo "======================================"
}

# ------------------------------------------------
# PHP INI dosyasini guvenli guncelle
# ------------------------------------------------

update_ini() {
    local INI="$1"
    local TEMP
    local BACKUP

    if [ ! -f "$INI" ]; then
        fail "INI bulunamadi: $INI"
        return 1
    fi

    echo ""
    echo "INI: $INI"

    BACKUP="${INI}.bak.${BACKUP_DATE}"

    if ! cp -p "$INI" "$BACKUP"; then
        fail "Yedek alinamadi: $INI"
        return 1
    fi

    TEMP=$(mktemp "${INI}.tmp.XXXXXXXX") || {
        fail "Gecici dosya olusturulamadi: $INI"
        return 1
    }

    # Onceki tum aktif tanimlari temizle.
    # Yeni degerleri en basa ekle.
    if ! awk -v post="$POST_MAX" \
             -v upload="$UPLOAD_MAX" '
        BEGIN {
            print "post_max_size = " post
            print "upload_max_filesize = " upload
            print ""
        }

        /^[[:space:]]*(post_max_size|upload_max_filesize)[[:space:]]*=/ {
            next
        }

        {
            print
        }
    ' "$INI" > "$TEMP"; then

        rm -f "$TEMP"
        fail "INI duzenleme hatasi: $INI"
        return 1
    fi

    # Dosyanin izin ve sahipligini koru.
    if ! chmod --reference="$INI" "$TEMP" ||
       ! chown --reference="$INI" "$TEMP"; then

        rm -f "$TEMP"
        fail "INI izinleri korunamadi: $INI"
        return 1
    fi

    if ! mv -f "$TEMP" "$INI"; then
        rm -f "$TEMP"
        fail "INI kaydedilemedi: $INI"
        return 1
    fi

    CHANGED=$((CHANGED + 1))
    ok "INI guncellendi"
}

# ------------------------------------------------
# PHP ini_get() kontrolu
# ------------------------------------------------

verify_php() {
    local PHP_BIN="$1"
    local VERSION
    local VALUES
    local POST_VALUE
    local UPLOAD_VALUE

    if [ ! -x "$PHP_BIN" ]; then
        fail "PHP binary bulunamadi: $PHP_BIN"
        return 1
    fi

    TOTAL=$((TOTAL + 1))

    VALUES=$("$PHP_BIN" -r '
        echo PHP_VERSION, "\n";
        echo ini_get("post_max_size"), "\n";
        echo ini_get("upload_max_filesize"), "\n";
    ' 2>/dev/null)

    if [ $? -ne 0 ]; then
        fail "PHP calistirilamadi: $PHP_BIN"
        return 1
    fi

    VERSION=$(printf '%s\n' "$VALUES" | sed -n '1p')
    POST_VALUE=$(printf '%s\n' "$VALUES" | sed -n '2p')
    UPLOAD_VALUE=$(printf '%s\n' "$VALUES" | sed -n '3p')

    echo ""
    echo "PHP: ${VERSION:-unknown}"
    echo "BIN: $PHP_BIN"

    if [ "$POST_VALUE" = "$POST_MAX" ]; then
        ok "post_max_size = $POST_VALUE"
        SUCCESS=$((SUCCESS + 1))
    else
        fail "post_max_size = ${POST_VALUE:-EMPTY} (Beklenen: $POST_MAX)"
    fi

    if [ "$UPLOAD_VALUE" = "$UPLOAD_MAX" ]; then
        ok "upload_max_filesize = $UPLOAD_VALUE"
        SUCCESS=$((SUCCESS + 1))
    else
        fail "upload_max_filesize = ${UPLOAD_VALUE:-EMPTY} (Beklenen: $UPLOAD_MAX)"
    fi
}

# ------------------------------------------------
# Baslangic
# ------------------------------------------------

section "CloudLinux PHP INI Guncelleme"

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

if [ "$CHANGED" -eq 0 ]; then
    fail "Hicbir PHP INI dosyasi guncellenmedi"
fi

# ------------------------------------------------
# PHP servis restart
# ------------------------------------------------

section "PHP Servisleri Yenileniyor"

# cPanel PHP-FPM
if [ -x /scripts/restartsrv_apache_php_fpm ]; then

    echo "Restart: cPanel PHP-FPM"

    if /scripts/restartsrv_apache_php_fpm; then
        ok "cPanel PHP-FPM restart"
    else
        fail "cPanel PHP-FPM restart"
    fi
fi

# Diger aktif PHP-FPM servisleri
if command -v systemctl >/dev/null 2>&1; then

    while IFS= read -r SERVICE; do

        [ -n "$SERVICE" ] || continue

        echo "Restart: $SERVICE"

        if systemctl restart "$SERVICE"; then
            ok "$SERVICE restart"
        else
            fail "$SERVICE restart"
        fi

    done < <(
        systemctl list-units \
            --type=service \
            --state=running \
            --no-legend \
            --plain |
        awk '{print $1}' |
        grep -E \
        '^(ea-php[0-9]+-php-fpm|alt-php[0-9]+-php-fpm|php-fpm)\.service$' |
        sort -u || true
    )
fi

# ------------------------------------------------
# LiteSpeed LSAPI restart
# ------------------------------------------------

section "LiteSpeed LSAPI Yenileme"

LSAPI_RESTART="/usr/local/lsws/admin/tmp/.lsphp_restart.txt"

if [ -d /usr/local/lsws/admin/tmp ]; then

    if touch "$LSAPI_RESTART"; then
        LSAPI_STATUS="TRIGGERED"
        ok "LiteSpeed LSAPI worker restart tetiklendi"
    else
        LSAPI_STATUS="FAILED"
        fail "LiteSpeed LSAPI worker restart"
    fi

else

    warn "LiteSpeed dizini bulunamadi"
    LSAPI_STATUS="NOT_APPLICABLE"

fi

# ------------------------------------------------
# PHP dogrulama
# ------------------------------------------------

section "PHP ini_get() Dogrulama"

# ALT-PHP
for DIR in /opt/alt/php[0-9]*; do

    [ -d "$DIR" ] || continue

    verify_php "$DIR/usr/bin/php"

done

# EA-PHP
for DIR in /opt/cpanel/ea-php[0-9]*; do

    [ -d "$DIR" ] || continue

    verify_php "$DIR/root/usr/bin/php"

done

# Native PHP
if [ -f /etc/php.ini ]; then
    verify_php /usr/bin/php
fi

# ------------------------------------------------
# Sonuc
# ------------------------------------------------

section "SONUC"

echo "Kontrol edilen PHP : $TOTAL"
echo "Guncellenen INI   : $CHANGED"
echo "Basarili kontrol  : $SUCCESS"
echo "Basarisiz kontrol : $FAIL"
echo "LSAPI durumu      : $LSAPI_STATUS"

echo ""

if [ "$FAIL" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then

    echo -e "${GREEN}OK OK OK OK${NC}"
    echo -e "${GREEN}Tum CLI PHP INI kontrolleri basarili${NC}"

    if [ "$LSAPI_STATUS" = "TRIGGERED" ]; then
        ok "LSAPI yenileme istegi gonderildi"
    fi

    warn "Web PHP ini_get degerleri ayrica dogrulanmalidir"

    exit 0

else

    echo -e "${RED}FAIL - Kontrol gerektiren hatalar var${NC}"

    exit 1

fi
