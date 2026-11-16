#!/usr/bin/env bash
###############################################################################
# rotate-sni.sh — авто-подбор сайтов маскировки для Reality инбаунда
#
# Что делает:
#   1. Тестирует список кандидатов SNI (TLS 1.3, H2, доступность)
#   2. Выбирает 3 самых быстрых и доступных
#   3. Обновляет инбаунд "vless-reality-auto" через API 3x-ui:
#        - dest = лучший SNI:443
#        - serverNames = топ-3 SNI + базовый домен
#   4. Логирует результат в /var/log/rotate-sni.log
#
# Запуск: вручную или через cron (см. install.sh).
###############################################################################

set -euo pipefail

CONF="/etc/x-ui/rotator.conf"
LOG="/var/log/rotate-sni.log"
LOCK="/var/run/rotate-sni.lock"

exec 9>"$LOCK"
flock -n 9 || { echo "[rotate-sni] уже запущен, выход"; exit 0; }

log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

[[ -f "$CONF" ]] || { log "Нет $CONF — ротатор не настроен"; exit 0; }
# shellcheck disable=SC1090
source "$CONF"

[[ -z "${ROTATE_INBOUND_ID:-}" ]] && { log "ROTATE_INBOUND_ID пуст"; exit 0; }

# Список кандидатов SNI (НЕ заблокированы в РФ, TLS 1.3, H2)
CANDIDATES="${SNI_LIST:-www.microsoft.com www.icloud.com www.amazon.com www.samsung.com www.swift.com www.tesla.com www.apple.com addons.mozilla.org www.lovelive.us www.door.casino}"

log "=== Старт ротации SNI для inbound #$ROTATE_INBOUND_ID ==="

# Тестируем каждого кандидата
declare -A SNI_TIME
declare -A SNI_OK
BEST_SNIS=()

for sni in $CANDIDATES; do
    # 1. Доступен ли по HTTPS, поддерживает ли TLS 1.3 и H2
    t=$( { curl -o /dev/null -s \
            --connect-timeout 5 --max-time 8 \
            --http2 \
            --tlsv1.3 \
            -w '%{time_total}' \
            "https://$sni/" ; } 2>/dev/null || echo "999" )
    # Проверяем валидность сертификата (через openssl)
    cert_ok=$( echo | timeout 8 openssl s_client -connect "$sni:443" \
                -servername "$sni" -tls1_3 2>/dev/null \
                | grep -c 'Verify return code: 0' || echo 0 )

    if [[ "$t" != "999" && "$cert_ok" == "1" ]]; then
        SNI_TIME["$sni"]="$t"
        SNI_OK["$sni"]="1"
        log "  [OK]   $sni  ${t}s"
    else
        log "  [SKIP] $sni  (недоступен/невалидный сертификат)"
    fi
done

# Сортируем по времени, берём топ-3
SORTED=$( for k in "${!SNI_TIME[@]}"; do echo "${SNI_TIME[$k]} $k"; done \
          | sort -n | head -3 | awk '{print $2}' )

if [[ -z "$SORTED" ]]; then
    log "Нет доступных SNI, оставляем текущую конфигурацию"
    exit 0
fi

mapfile -t NEW_SNIS <<< "$SORTED"
BEST="${NEW_SNIS[0]}"
SECOND="${NEW_SNIS[1]:-$BEST}"
THIRD="${NEW_SNIS[2]:-$BEST}"

log "Лучшие SNI: 1) $BEST  2) $SECOND  3) $THIRD"

# Обновляем инбаунд через API 3x-ui (через Python, т.к. JSON-в-JSON сложный)
export ROTATE_INBOUND_ID BEST SECOND THIRD
export DOMAIN PANEL_USER PANEL_PASS PANEL_PATH REALITY_PRIV REALITY_SHORT_ID_2 REALITY_UUID REALITY_PUB
export CONF

python3 <<'PYEOF2'
import os, json, urllib.request, http.cookiejar, ssl

domain      = os.environ['DOMAIN']
panel_path  = os.environ['PANEL_PATH']
user        = os.environ['PANEL_USER']
pwd         = os.environ['PANEL_PASS']
inbound_id  = os.environ['ROTATE_INBOUND_ID']
best        = os.environ['BEST']
second      = os.environ['SECOND']
third       = os.environ['THIRD']
priv        = os.environ['REALITY_PRIV']
sid         = os.environ['REALITY_SHORT_ID_2']

base = f"https://{domain}{panel_path}".rstrip('/')

cj = http.cookiejar.CookieJar()
ctx = ssl.create_default_context()
opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(cj),
    urllib.request.HTTPSHandler(context=ctx)
)

# Логин
body = json.dumps({"username": user, "password": pwd}).encode()
req = urllib.request.Request(f"{base}/login", data=body, method='POST')
req.add_header('Content-Type', 'application/json')
opener.open(req, timeout=30).read()

# Получаем текущий инбаунд
req = urllib.request.Request(f"{base}/panel/api/inbounds/get/{inbound_id}")
resp = opener.open(req, timeout=30)
data = json.loads(resp.read().decode())
if not data.get('success'):
    print(f"Не удалось получить инбаунд #{inbound_id}: {data}", flush=True)
    raise SystemExit(1)
inbound = data['obj']

# Разбираем текущие streamSettings
stream = json.loads(inbound['streamSettings'])
reality = stream.get('realitySettings', {})

# Проверяем, изменился ли SNI
old_dest = reality.get('dest', '')
old_sn   = reality.get('serverNames', [])
new_sn   = [best, second, third]
if old_dest == f"{best}:443" and set(old_sn) == set(new_sn):
    print("SNI не изменился, обновление не требуется", flush=True)
    raise SystemExit(0)

# Обновляем
reality['dest'] = f"{best}:443"
reality['serverNames'] = new_sn
stream['realitySettings'] = reality
inbound['streamSettings'] = json.dumps(stream, ensure_ascii=False)

# Полный объект для update (включая id и обязательные поля)
update_payload = {
    "id": int(inbound_id),
    "up": inbound.get('up', 0),
    "down": inbound.get('down', 0),
    "total": inbound.get('total', 0),
    "remark": inbound.get('remark', 'vless-reality-auto'),
    "enable": inbound.get('enable', True),
    "expiryTime": inbound.get('expiryTime', 0),
    "listen": inbound.get('listen', '0.0.0.0'),
    "port": inbound.get('port'),
    "protocol": inbound.get('protocol', 'vless'),
    "settings": inbound.get('settings'),
    "streamSettings": inbound['streamSettings'],
    "sniffing": inbound.get('sniffing'),
    "tag": inbound.get('tag', f'inbound-{inbound_id}'),
}

body = json.dumps(update_payload).encode()
req = urllib.request.Request(f"{base}/panel/api/inbounds/update/{inbound_id}", data=body, method='POST')
req.add_header('Content-Type', 'application/json')
resp = opener.open(req, timeout=30)
result = json.loads(resp.read().decode())
if result.get('success'):
    print(f"SNI обновлён: dest={best}:443, serverNames={new_sn}", flush=True)
else:
    print(f"Ошибка обновления: {result}", flush=True)
    raise SystemExit(1)
PYEOF2

log "=== Ротация завершена. Текущий SNI: $BEST ==="
