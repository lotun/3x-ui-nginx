#!/usr/bin/env bash
###############################################################################
# 3x-ui Pro Installer with Nginx + Landing Page
# Версия для обхода российских блокировок (актуально на 2025-2026)
#
# Что делает скрипт:
#   1. Устанавливает 3x-ui (MHSanaei) + Xray-core
#   2. Устанавливает Nginx как reverse-proxy с Let's Encrypt SSL
#   3. Размещает лендинг-страницу-заглушку в корне домена (маскировка)
#   4. Панель 3x-ui доступна по секретному пути
#   5. Преднастраивает рабочие в РФ инбаунды:
#        - Trojan + WS + TLS (через домен)         [стабильно работает в РФ]
#        - VLESS + WS + TLS (через домен, CDN-ready)
#        - VLESS + Reality + Vision (порт 8443)     [фиксированный SNI: microsoft.com]
#        - VLESS + Reality + Vision (порт 8444)     [авто-ротация SNI маскировки]
#        - Hysteria2 (UDP)                          [DPI-устойчивый]
#   6. Ставит rotate-sni.sh + cron для авто-подбора сайтов маскировки
#   7. Настраивает UFW firewall
#
# Использование:
#   sudo bash install.sh
#   sudo bash install.sh --domain example.com --email admin@example.com
#   sudo bash install.sh --domain example.com --email a@b.c --non-interactive
#
# Требования:
#   - VPS на Ubuntu 20.04+ / Debian 11+
#   - root права
#   - Домен с A-записью, указывающей на IP сервера
#   - Открытые порты 80, 443 (для nginx и сертификации)
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Цвета и логирование
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Переменные по умолчанию
# ---------------------------------------------------------------------------
DOMAIN=""
EMAIL=""
INTERACTIVE=1
PANEL_USER_DEFAULT="admin"
LANDING_COMPANY_NAME="CloudEdge Solutions"

# Порты и пути (могут быть переопределены через конфиг)
PANEL_PORT=2053
SUB_PORT=2096
TROJAN_PORT=10001
VLESS_PORT=10002
REALITY_PORT=8443
REALITY_ROTATE_PORT=8444
HYSTERIA_PORT=36712

# Список сайтов-кандидатов для маскировки Reality (НЕ заблокированы в РФ,
# поддерживают TLS 1.3 и H2). Используется rotate-sni.sh
REALITY_SNI_LIST=(
    "www.microsoft.com"
    "www.icloud.com"
    "www.amazon.com"
    "www.samsung.com"
    "www.swift.com"
    "www.tesla.com"
    "www.apple.com"
    "addons.mozilla.org"
    "www.lovelive.us"
    "www.door.casino"
)

# ---------------------------------------------------------------------------
# Парсинг аргументов
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Использование: sudo bash install.sh [ОПЦИИ]

Опции:
  --domain DOMAIN        Главный домен (обязательно)
  --email EMAIL          Email для Let's Encrypt (обязательно)
  --user USER            Имя пользователя панели (по умолчанию: admin)
  --non-interactive      Без интерактивных запросов
  --help, -h             Эта справка

Пример:
  sudo bash install.sh --domain vpn.example.com --email me@example.com
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)        DOMAIN="$2"; shift 2 ;;
        --email)         EMAIL="$2"; shift 2 ;;
        --user)          PANEL_USER_DEFAULT="$2"; shift 2 ;;
        --non-interactive) INTERACTIVE=0; shift ;;
        --help|-h)       usage ;;
        *)               die "Неизвестный аргумент: $1 (используйте --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Интерактивный ввод недостающих параметров
# ---------------------------------------------------------------------------
if [[ "$INTERACTIVE" -eq 1 ]]; then
    if [[ -z "$DOMAIN" ]]; then
        echo -ne "${CYAN}Введите домен${NC} (например, vpn.example.com): "
        read -r DOMAIN
    fi
    if [[ -z "$EMAIL" ]]; then
        echo -ne "${CYAN}Введите email для SSL${NC}: "
        read -r EMAIL
    fi
fi

[[ -z "$DOMAIN" ]] && die "Домен обязателен (--domain)"
[[ -z "$EMAIL" ]] && die "Email обязателен (--email)"

# Проверка формата email
[[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && die "Некорректный email: $EMAIL"

# ---------------------------------------------------------------------------
# Предполётные проверки
# ---------------------------------------------------------------------------
log "Предполётные проверки..."

[[ $EUID -ne 0 ]] && die "Запустите скрипт от root: sudo bash install.sh"

# OS check
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
else
    die "Не удалось определить ОС (/etc/os-release отсутствует)"
fi

case "$OS_ID" in
    ubuntu|debian) ;;
    *)
        warn "Скрипт тестировался на Ubuntu/Debian. Текущая ОС: $OS_ID $OS_VERSION"
        if [[ "$INTERACTIVE" -eq 1 ]]; then
            read -rp "Продолжить? (y/N): " ans
            [[ "$ans" =~ ^[Yy]$ ]] || die "Отменено"
        fi
        ;;
esac

# Проверка DNS (домен должен указывать на этот сервер)
SERVER_IP=$(curl -fsS4 https://api.ipify.org 2>/dev/null || curl -fsS4 https://ifconfig.me 2>/dev/null || echo "")
DOMAIN_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || echo "")

if [[ -n "$SERVER_IP" && -n "$DOMAIN_IP" && "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    warn "ВНИМАНИЕ: IP сервера ($SERVER_IP) не совпадает с IP домена ($DOMAIN_IP)"
    warn "Убедитесь, что A-запись домена указывает на этот сервер."
    if [[ "$INTERACTIVE" -eq 1 ]]; then
        read -rp "Продолжить? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || die "Отменено пользователем"
    fi
fi

log "Сервер IP: ${SERVER_IP:-не определён}"
log "Домен: $DOMAIN"

# ---------------------------------------------------------------------------
# Генератор случайностей
# ---------------------------------------------------------------------------
rand_hex()   { openssl rand -hex "${1:-8}"; }
rand_str()   { openssl rand -base64 "${1:-24}" | tr -d '/+=' | head -c "${2:-16}"; }
rand_uuid()  { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || python3 -c "import uuid;print(uuid.uuid4())"; }

# ---------------------------------------------------------------------------
# Установка системных зависимостей
# ---------------------------------------------------------------------------
log "Установка системных зависимостей..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq \
    nginx \
    certbot \
    python3 \
    curl \
    ca-certificates \
    jq \
    sqlite3 \
    openssl \
    ufw \
    cron \
    lsof \
    net-tools \
    >/dev/null 2>&1

log "Системные зависимости установлены"

# ---------------------------------------------------------------------------
# Установка 3x-ui
# ---------------------------------------------------------------------------
XUI_BIN="/usr/local/x-ui/x-ui"
XRAY_BIN=""

if [[ -x "$XUI_BIN" ]]; then
    log "3x-ui уже установлен, обновляем..."
    bash <(curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) update >/dev/null 2>&1 || true
else
    log "Устанавливаем 3x-ui (MHSanaei)..."
    bash <(curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) install >/dev/null 2>&1
fi

[[ ! -x "$XUI_BIN" ]] && die "3x-ui не установлен. Проверьте логи установки."

# Находим бинарник xray для генерации ключей Reality
XRAY_BIN=$(command -v xray 2>/dev/null || true)
if [[ -z "$XRAY_BIN" ]]; then
    for candidate in /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/bin/xray; do
        if [[ -x "$candidate" ]]; then
            XRAY_BIN="$candidate"
            break
        fi
    done
fi
[[ -z "$XRAY_BIN" || ! -x "$XRAY_BIN" ]] && die "Бинарник xray не найден. Установка 3x-ui не завершилась корректно."
log "Xray: $XRAY_BIN"

# ---------------------------------------------------------------------------
# Генерация всех секретов
# ---------------------------------------------------------------------------
log "Генерация секретов и путей..."

PANEL_PATH="/$(rand_hex 8)/"
SUB_PATH="/sub-$(rand_hex 6)/"
WS_PATH_TROJAN="/trojan-$(rand_hex 8)"
WS_PATH_VLESS="/vless-$(rand_hex 8)"
TROJAN_PASS=$(rand_uuid)
VLESS_UUID=$(rand_uuid)
REALITY_UUID=$(rand_uuid)
HY2_PASS=$(rand_str 32 24)

# Reality ключи (x25519)
KEY_OUT=$("$XRAY_BIN" x25519 2>/dev/null)
REALITY_PRIV=$(echo "$KEY_OUT" | grep -iE 'private' | awk -F':\\s*' '{print $2}' | head -1)
REALITY_PUB=$(echo "$KEY_OUT"  | grep -iE 'public'  | awk -F':\\s*' '{print $2}' | head -1)

[[ -z "$REALITY_PRIV" || -z "$REALITY_PUB" ]] && die "Не удалось сгенерировать Reality ключи через xray x25519"

REALITY_SHORT_ID=$(rand_hex 8)
REALITY_SHORT_ID_2=$(rand_hex 8)

PANEL_USER="$PANEL_USER_DEFAULT"
PANEL_PASS=$(rand_str 32 18)

log "Секреты сгенерированы"

# Сохраняем конфигурацию (для повторного запуска и rotate-sni.sh)
mkdir -p /etc/x-ui
umask 077
cat > /etc/x-ui/install.conf <<CONFEOF
# Сгенерировано install.sh $(date)
DOMAIN=$DOMAIN
EMAIL=$EMAIL
SERVER_IP=$SERVER_IP

PANEL_USER=$PANEL_USER
PANEL_PASS=$PANEL_PASS
PANEL_PATH=$PANEL_PATH
PANEL_PORT=$PANEL_PORT

SUB_PATH=$SUB_PATH
SUB_PORT=$SUB_PORT

WS_PATH_TROJAN=$WS_PATH_TROJAN
WS_PATH_VLESS=$WS_PATH_VLESS
TROJAN_PORT=$TROJAN_PORT
TROJAN_PASS=$TROJAN_PASS

VLESS_UUID=$VLESS_UUID
VLESS_PORT=$VLESS_PORT

REALITY_PORT=$REALITY_PORT
REALITY_ROTATE_PORT=$REALITY_ROTATE_PORT
REALITY_UUID=$REALITY_UUID
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_SHORT_ID=$REALITY_SHORT_ID
REALITY_SHORT_ID_2=$REALITY_SHORT_ID_2

HYSTERIA_PORT=$HYSTERIA_PORT
HY2_PASS=$HY2_PASS

XRAY_BIN=$XRAY_BIN
CONFEOF
chmod 600 /etc/x-ui/install.conf
log "Конфигурация сохранена: /etc/x-ui/install.conf"

# ---------------------------------------------------------------------------
# Настройка панели 3x-ui (через x-ui setting)
# ---------------------------------------------------------------------------
log "Настройка панели 3x-ui..."

# Сначала остановим панель — иначе SQLite-база залочена запущенным сервисом
# и x-ui setting не сможет записать параметры.
systemctl stop x-ui >/dev/null 2>&1 || true
sleep 1

# Обязательные параметры (должны пройти).
# ВАЖНО: в текущем MHSanaei/3x-ui флаг называется -listenIP (НЕ -panelListen).
if ! "$XUI_BIN" setting \
        -username "$PANEL_USER" \
        -password "$PANEL_PASS" \
        -port "$PANEL_PORT" \
        -listenIP "127.0.0.1" \
        -webBasePath "$PANEL_PATH" \
        >/tmp/x-ui-setting.err 2>&1; then
    echo "--- вывод x-ui setting ---"
    cat /tmp/x-ui-setting.err
    echo "----------------------------"
    die "x-ui setting: не удалось задать основные параметры панели (см. вывод выше)"
fi

# Затем параметры подписки (опционально — флаги зависят от версии 3x-ui)
"$XUI_BIN" setting \
    -subEnable "true" \
    -subListen "127.0.0.1" \
    -subPort "$SUB_PORT" \
    -subPath "$SUB_PATH" \
    -subEncrypt "true" \
    -subShowInfo "true" \
    -subUpdates "12" \
    >/tmp/x-ui-sub.err 2>&1 || {
        warn "x-ui setting: часть флагов подписки не поддерживается вашей версией 3x-ui (не критично, подписку можно настроить через панель)"
        cat /tmp/x-ui-sub.err
    }

# Перезапуск панели для применения настроек
systemctl restart x-ui
sleep 3

# Проверка что панель слушает
if ! ss -ltn 2>/dev/null | grep -q ":${PANEL_PORT}"; then
    warn "Панель не отвечает на порту $PANEL_PORT, проверьте: systemctl status x-ui"
fi
log "Панель 3x-ui настроена (слушает 127.0.0.1:$PANEL_PORT, путь $PANEL_PATH)"

# ---------------------------------------------------------------------------
# Создание лендинга-заглушки
# ---------------------------------------------------------------------------
log "Создание лендинг-страницы..."

mkdir -p /var/www/landing
cat > /var/www/landing/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CloudEdge Solutions — Облачные решения для бизнеса</title>
<meta name="description" content="CloudEdge Solutions: надёжная облачная инфраструктура, виртуальные серверы, резервное копирование и CDN для бизнеса в России и СНГ.">
<style>
  :root {
    --bg: #0f172a;
    --bg-soft: #1e293b;
    --fg: #f1f5f9;
    --muted: #94a3b8;
    --accent: #38bdf8;
    --accent-2: #818cf8;
    --card: rgba(30, 41, 59, 0.7);
    --border: rgba(148, 163, 184, 0.15);
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html { scroll-behavior: smooth; }
  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif;
    background: radial-gradient(1200px 600px at 50% -10%, rgba(56,189,248,0.18), transparent 60%), var(--bg);
    color: var(--fg);
    line-height: 1.6;
    min-height: 100vh;
  }
  a { color: inherit; text-decoration: none; }
  .container { max-width: 1120px; margin: 0 auto; padding: 0 24px; }
  header {
    position: sticky; top: 0; z-index: 50;
    backdrop-filter: blur(12px);
    background: rgba(15, 23, 42, 0.7);
    border-bottom: 1px solid var(--border);
  }
  .nav { display: flex; align-items: center; justify-content: space-between; padding: 16px 0; }
  .brand { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 18px; }
  .brand .logo {
    width: 32px; height: 32px; border-radius: 8px;
    background: linear-gradient(135deg, var(--accent), var(--accent-2));
    display: grid; place-items: center; color: #0f172a; font-weight: 900;
  }
  .nav ul { display: flex; gap: 28px; list-style: none; }
  .nav ul a { color: var(--muted); font-size: 14px; transition: color .2s; }
  .nav ul a:hover { color: var(--fg); }
  .btn {
    display: inline-block; padding: 12px 22px; border-radius: 10px;
    background: linear-gradient(135deg, var(--accent), var(--accent-2));
    color: #0f172a; font-weight: 600; font-size: 14px; cursor: pointer;
    border: none; transition: transform .2s, box-shadow .2s;
  }
  .btn:hover { transform: translateY(-1px); box-shadow: 0 10px 30px rgba(56,189,248,0.3); }
  .btn-ghost {
    background: transparent; color: var(--fg);
    border: 1px solid var(--border);
  }
  .hero { padding: 90px 0 60px; text-align: center; }
  .hero h1 { font-size: clamp(32px, 5vw, 56px); line-height: 1.1; font-weight: 800; letter-spacing: -0.02em; margin-bottom: 20px; }
  .hero h1 .grad { background: linear-gradient(135deg, var(--accent), var(--accent-2)); -webkit-background-clip: text; background-clip: text; color: transparent; }
  .hero p { color: var(--muted); font-size: 18px; max-width: 680px; margin: 0 auto 32px; }
  .hero .cta { display: flex; gap: 14px; justify-content: center; flex-wrap: wrap; }
  .badges { display: flex; gap: 28px; justify-content: center; margin-top: 56px; flex-wrap: wrap; }
  .badges div { text-align: center; }
  .badges .num { font-size: 32px; font-weight: 800; color: var(--accent); }
  .badges .lbl { color: var(--muted); font-size: 13px; }
  .features { padding: 80px 0; }
  .section-title { text-align: center; margin-bottom: 56px; }
  .section-title h2 { font-size: clamp(28px, 4vw, 40px); font-weight: 700; margin-bottom: 12px; }
  .section-title p { color: var(--muted); max-width: 620px; margin: 0 auto; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 24px; }
  .card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 16px; padding: 28px; transition: transform .2s, border-color .2s;
  }
  .card:hover { transform: translateY(-4px); border-color: rgba(56,189,248,0.4); }
  .card .ico { width: 44px; height: 44px; border-radius: 10px; background: rgba(56,189,248,0.12); color: var(--accent); display: grid; place-items: center; margin-bottom: 18px; font-size: 22px; }
  .card h3 { font-size: 18px; margin-bottom: 8px; }
  .card p { color: var(--muted); font-size: 14px; }
  .pricing { padding: 80px 0; }
  .price-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 24px; }
  .price { background: var(--card); border: 1px solid var(--border); border-radius: 16px; padding: 32px; position: relative; }
  .price.featured { border-color: var(--accent); }
  .price.featured::before { content: 'Популярный'; position: absolute; top: -12px; left: 50%; transform: translateX(-50%); background: var(--accent); color: #0f172a; padding: 4px 14px; border-radius: 20px; font-size: 12px; font-weight: 700; }
  .price .name { color: var(--muted); font-size: 14px; margin-bottom: 8px; }
  .price .amount { font-size: 36px; font-weight: 800; }
  .price .amount span { font-size: 14px; color: var(--muted); font-weight: 400; }
  .price ul { list-style: none; margin: 24px 0; }
  .price ul li { color: var(--muted); padding: 8px 0; border-bottom: 1px solid var(--border); font-size: 14px; }
  .price ul li::before { content: '✓'; color: var(--accent); margin-right: 10px; }
  footer { border-top: 1px solid var(--border); padding: 40px 0; color: var(--muted); font-size: 14px; }
  .foot-grid { display: flex; justify-content: space-between; flex-wrap: wrap; gap: 24px; }
  .foot-col h4 { color: var(--fg); margin-bottom: 14px; font-size: 14px; }
  .foot-col ul { list-style: none; }
  .foot-col ul li { padding: 4px 0; }
  @media (max-width: 640px) {
    .nav ul { display: none; }
    .hero { padding: 60px 0 40px; }
  }
</style>
</head>
<body>
<header>
  <div class="container nav">
    <div class="brand">
      <div class="logo">CE</div>
      <span>CloudEdge Solutions</span>
    </div>
    <ul>
      <li><a href="#features">Возможности</a></li>
      <li><a href="#pricing">Тарифы</a></li>
      <li><a href="#contacts">Контакты</a></li>
    </ul>
    <a href="#pricing" class="btn">Начать бесплатно</a>
  </div>
</header>

<main>
  <section class="hero">
    <div class="container">
      <h1>Облачная инфраструктура <span class="grad">для роста бизнеса</span></h1>
      <p>Надёжные виртуальные серверы, автоматическое резервное копирование и глобальный CDN. Развёртывание за 60 секунд, аптайм 99.95%, поддержка 24/7.</p>
      <div class="cta">
        <a href="#pricing" class="btn">Выбрать тариф</a>
        <a href="#features" class="btn btn-ghost">Узнать больше</a>
      </div>
      <div class="badges">
        <div><div class="num">99.95%</div><div class="lbl">Аптайм по SLA</div></div>
        <div><div class="num">12</div><div class="lbl">Дата-центров</div></div>
        <div><div class="num">8 500+</div><div class="lbl">Клиентов</div></div>
        <div><div class="num">24/7</div><div class="lbl">Поддержка</div></div>
      </div>
    </div>
  </section>

  <section class="features" id="features">
    <div class="container">
      <div class="section-title">
        <h2>Почему выбирают CloudEdge</h2>
        <p>Полный стек облачных сервисов с фокусом на производительность, безопасность и удобство для команд разработчиков.</p>
      </div>
      <div class="grid">
        <div class="card">
          <div class="ico">⚡</div>
          <h3>Высокая производительность</h3>
          <p>NVMe-хранилище, выделенные ядра CPU и сеть 10 Gbps. Запуск приложений быстрее в 3 раза по сравнению с обычными VPS.</p>
        </div>
        <div class="card">
          <div class="ico">🔒</div>
          <h3>Безопасность по умолчанию</h3>
          <p>Защита от DDoS-атак уровня L3-L7, изоляция трафика, DDoS-щит на 480 Gbps и шифрование данных в покое и в transit.</p>
        </div>
        <div class="card">
          <div class="ico">🌍</div>
          <h3>Глобальный CDN</h3>
          <p>Точки присутствия в 12 дата-центрах Европы, Азии и Северной Америки. Контент доставляется пользователю за &lt;30 мс.</p>
        </div>
        <div class="card">
          <div class="ico">💾</div>
          <h3>Автобэкап и снапшоты</h3>
          <p>Ежедневное резервное копирование с хранением 30 дней, мгновенные снапшоты по расписанию или вручную в один клик.</p>
        </div>
        <div class="card">
          <div class="ico">🛠️</div>
          <h3>API и Terraform</h3>
          <p>Полноценный REST API, провайдер для Terraform и Pulumi. Infrastructure-as-code без сложной настройки.</p>
        </div>
        <div class="card">
          <div class="ico">📈</div>
          <h3>Масштабирование в один клик</h3>
          <p>Вертикальное и горизонтальное масштабирование без перенастройки. Платите только за реально использованные ресурсы.</p>
        </div>
      </div>
    </div>
  </section>

  <section class="pricing" id="pricing">
    <div class="container">
      <div class="section-title">
        <h2>Прозрачные тарифы</h2>
        <p>Без скрытых платежей. Подключение и перенос данных — бесплатно.</p>
      </div>
      <div class="price-grid">
        <div class="price">
          <div class="name">Start</div>
          <div class="amount">490 ₽<span>/мес</span></div>
          <ul>
            <li>2 vCPU, 2 ГБ RAM</li>
            <li>40 ГБ NVMe</li>
            <li>1 ТБ трафика</li>
            <li>1 IPv4</li>
            <li>Базовая поддержка</li>
          </ul>
          <a href="#contacts" class="btn btn-ghost" style="width:100%;text-align:center;">Выбрать</a>
        </div>
        <div class="price featured">
          <div class="name">Business</div>
          <div class="amount">1 490 ₽<span>/мес</span></div>
          <ul>
            <li>4 vCPU, 8 ГБ RAM</li>
            <li>120 ГБ NVMe</li>
            <li>5 ТБ трафика</li>
            <li>DDoS-щит 480 Gbps</li>
            <li>Автобэкап 30 дней</li>
            <li>Приоритетная поддержка</li>
          </ul>
          <a href="#contacts" class="btn" style="width:100%;text-align:center;">Выбрать</a>
        </div>
        <div class="price">
          <div class="name">Enterprise</div>
          <div class="amount">от 4 900 ₽<span>/мес</span></div>
          <ul>
            <li>Выделенные ядра</li>
            <li>От 16 ГБ RAM</li>
            <li>Безлимитный трафик</li>
            <li>SLA 99.99%</li>
            <li>Персональный менеджер</li>
            <li>Частная сеть и VLAN</li>
          </ul>
          <a href="#contacts" class="btn btn-ghost" style="width:100%;text-align:center;">Связаться</a>
        </div>
      </div>
    </div>
  </section>
</main>

<footer id="contacts">
  <div class="container">
    <div class="foot-grid">
      <div class="foot-col">
        <div class="brand" style="margin-bottom:14px;">
          <div class="logo">CE</div>
          <span>CloudEdge Solutions</span>
        </div>
        <p>© 2024 CloudEdge Solutions. Все права защищены.<br>ИНН 7700000000 · ОГРН 1027700000000</p>
      </div>
      <div class="foot-col">
        <h4>Продукты</h4>
        <ul>
          <li>VPS и выделенные серверы</li>
          <li>Объектное хранилище S3</li>
          <li>CDN</li>
          <li>Managed Kubernetes</li>
        </ul>
      </div>
      <div class="foot-col">
        <h4>Компания</h4>
        <ul>
          <li>О нас</li>
          <li>Блог</li>
          <li>Вакансии</li>
          <li>Документация</li>
        </ul>
      </div>
      <div class="foot-col">
        <h4>Контакты</h4>
        <ul>
          <li>hello@cloudedge.example</li>
          <li>+7 495 000-00-00</li>
          <li>Telegram: @cloudedge</li>
        </ul>
      </div>
    </div>
  </div>
</footer>
</body>
</html>
HTMLEOF

# Дополнительные файлы для реалистичности сайта
cat > /var/www/landing/robots.txt <<'ROBOTEOF'
User-agent: *
Allow: /
Sitemap: /sitemap.xml
ROBOTEOF

cat > /var/www/landing/sitemap.xml <<'SITEMAPEOF'
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>/</loc><changefreq>weekly</changefreq><priority>1.0</priority></url>
  <url><loc>/#features</loc><changefreq>monthly</changefreq><priority>0.7</priority></url>
  <url><loc>/#pricing</loc><changefreq>monthly</changefreq><priority>0.8</priority></url>
</urlset>
SITEMAPEOF

cat > /var/www/landing/favicon.svg <<'FAVEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#38bdf8"/><text x="16" y="22" font-family="Arial" font-weight="900" font-size="16" fill="#0f172a" text-anchor="middle">CE</text></svg>
FAVEOF

chown -R www-data:www-data /var/www/landing
log "Лендинг создан: /var/www/landing/index.html"

# ---------------------------------------------------------------------------
# Конфигурация Nginx (HTTP-only для сертификации Let's Encrypt)
# ---------------------------------------------------------------------------
log "Настройка Nginx (этап 1: HTTP для сертификации)..."

NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
rm -f "$NGINX_CONF"

cat > "$NGINX_CONF" <<NGINXEOF1
# Конфигурация Nginx для 3x-ui + лендинг
# Сгенерировано install.sh

# --- HTTP: редирект на HTTPS + webroot для Let's Encrypt ---
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/landing;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINXEOF1

ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
rm -f /etc/nginx/sites-enabled/default

NGINX_TEST_OUT="$(nginx -t 2>&1)"
echo "$NGINX_TEST_OUT" | grep -q "successful" || { echo "$NGINX_TEST_OUT"; die "Конфиг nginx невалиден (этап 1)"; }
systemctl restart nginx
log "Nginx HTTP запущен"

# ---------------------------------------------------------------------------
# Получение SSL-сертификата Let's Encrypt
# ---------------------------------------------------------------------------
log "Получение SSL-сертификата Let's Encrypt..."

# Определяем, на какие домены заказывать сертификат.
# Апекс (DOMAIN) — всегда. www.${DOMAIN} — только если у него есть A/AAAA-запись,
# указывающая на THIS сервер. Иначе Let's Encrypt падает с
# "no valid A records found for www.${DOMAIN}" (см. https://letsencrypt.org/docs/).
SERVER_IPV4="$(curl -fsS4 https://ifconfig.me 2>/dev/null || echo '')"
SERVER_IPV6="$(curl -fsS6 https://ifconfig.me 2>/dev/null || true)"

CERT_DOMAINS=(-d "${DOMAIN}")
WWW_DOMAIN="www.${DOMAIN}"
WWW_IPS="$(getent hosts "$WWW_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"

if [[ -n "$WWW_IPS" ]]; then
    # www резолвится — проверим, что хотя бы один из адресов совпадает с IP сервера.
    if [[ "$WWW_IPS" == *"$SERVER_IPV4"* ]] || [[ -n "$SERVER_IPV6" && "$WWW_IPS" == *"$SERVER_IPV6"* ]]; then
        CERT_DOMAINS+=(-d "$WWW_DOMAIN")
        log "DNS: $WWW_DOMAIN → $WWW_IPS (совпадает с IP сервера), сертификат будет включать www."
        NGINX_SERVER_NAMES="${DOMAIN} ${WWW_DOMAIN}"
    else
        warn "DNS: $WWW_DOMAIN резолвится в [$WWW_IPS], но это НЕ IP этого сервера ($SERVER_IPV4). Сертификат заказываем только на ${DOMAIN}."
        NGINX_SERVER_NAMES="${DOMAIN}"
    fi
else
    log "DNS: A/AAAA-запись для $WWW_DOMAIN не найдена — сертификат заказываем только на ${DOMAIN}."
    NGINX_SERVER_NAMES="${DOMAIN}"
fi

CERTBOT_SUCCESS=0
for attempt in 1 2 3; do
    if certbot certonly --webroot -w /var/www/landing \
        "${CERT_DOMAINS[@]}" \
        --email "${EMAIL}" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        2>&1; then
        CERTBOT_SUCCESS=1
        break
    fi
    warn "Попытка $attempt завершилась неудачно, повтор через 10 сек..."
    sleep 10
done

[[ $CERTBOT_SUCCESS -eq 0 ]] && die "Не удалось получить SSL-сертификат. Проверьте: (1) A-запись ${DOMAIN} указывает на $SERVER_IPV4; (2) порт 80 открыт извне; (3) Nginx слушает :80 и отдаёт /. Подробности: /var/log/letsencrypt/letsencrypt.log"

CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
[[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] || die "Сертификаты не найдены в $CERT_PATH"
log "Сертификат получен: $CERT_PATH"

# Регистрация хука обновления для перезагрузки nginx
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOKEOF'
#!/bin/bash
systemctl reload nginx 2>/dev/null || true
/usr/local/x-ui/x-ui restart 2>/dev/null || true
HOOKEOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 2>/dev/null || true

# ---------------------------------------------------------------------------
# Финальная конфигурация Nginx (HTTP + HTTPS, лендинг + прокси)
# ---------------------------------------------------------------------------
log "Настройка Nginx (этап 2: HTTPS + reverse proxy)..."

cat > "$NGINX_CONF" <<NGINXEOF2
# Конфигурация Nginx для 3x-ui + лендинг (полная)
# Сгенерировано install.sh

# upstream-настройки для WebSocket-инбаундов
upstream trojan_ws_backend { server 127.0.0.1:${TROJAN_PORT}; }
upstream vless_ws_backend  { server 127.0.0.1:${VLESS_PORT}; }

# --- HTTP: редирект на HTTPS + webroot для Let's Encrypt ---
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/landing;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# --- HTTPS: лендинг + панель + инбаунды WS ---
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${NGINX_SERVER_NAMES};

    # SSL
    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    # Заглушка для несовпадающих путей (выглядим как обычный сайт)
    root /var/www/landing;
    index index.html;

    # Дополнительные заголовки безопасности (для реалистичности)
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # --- Лендинг (корень) ---
    location / {
        try_files \$uri \$uri/ =404;
    }

    # --- Панель 3x-ui ---
    # proxy_pass без URI сохраняет полный путь (/<panel_path>/...),
    # что и ожидает 3x-ui при webBasePath = ${PANEL_PATH}
    location ${PANEL_PATH} {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host  \$host;

        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout  300s;
        proxy_send_timeout  300s;
        proxy_buffering off;
    }

    # --- Subscription endpoint ---
    location ${SUB_PATH} {
        proxy_pass http://127.0.0.1:${SUB_PORT};
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # --- Trojan WS (маскируется под обычный веб-сокет на сайте) ---
    location ${WS_PATH_TROJAN} {
        proxy_pass http://trojan_ws_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       \$host;
        proxy_set_header X-Real-IP  \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
    }

    # --- VLESS WS ---
    location ${WS_PATH_VLESS} {
        proxy_pass http://vless_ws_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       \$host;
        proxy_set_header X-Real-IP  \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
    }

    # Кастомные ошибки, выглядят как реальный сайт
    error_page 404 /index.html;
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        default_type text/html;
        return 500 '<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head><body><h1>502 Bad Gateway</h1><p>CloudEdge Solutions — сервер временно недоступен.</p></body></html>';
    }
}

# Рекомендованные глобальные настройки nginx уже в /etc/nginx/nginx.conf
NGINXEOF2

NGINX_TEST_OUT="$(nginx -t 2>&1)"
echo "$NGINX_TEST_OUT" | grep -q "successful" || { echo "$NGINX_TEST_OUT"; die "Конфиг nginx невалиден (этап 2)"; }
systemctl reload nginx
log "Nginx HTTPS сконфигурирован"

# ---------------------------------------------------------------------------
# Создание инбаундов через API 3x-ui
# ---------------------------------------------------------------------------
log "Создание преднастроенных инбаундов через API 3x-ui..."

# Добавляем домен в /etc/hosts → 127.0.0.1, чтобы API-вызовы через HTTPS
# работали локально даже до полного распространения DNS (сервер обращается
# сам к себе через nginx). Запись идемпотентна.
if ! grep -qE "^[0-9.]+[[:space:]]+${DOMAIN//./\\.}\b" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 ${DOMAIN} www.${DOMAIN}  # added by 3x-ui installer" >> /etc/hosts
    log "Добавлена запись /etc/hosts: 127.0.0.1 ${DOMAIN}"
fi

# Пауза, чтобы панель точно поднялась после restart
PANEL_READY=0
for i in 1 2 3 4 5 6 7 8; do
    if curl -fsk "https://${DOMAIN}/${PANEL_PATH#/}login" -o /dev/null --max-time 5 2>/dev/null; then
        PANEL_READY=1
        break
    fi
    sleep 2
done
[[ $PANEL_READY -eq 1 ]] || warn "Панель не отвечает на https://${DOMAIN}${PANEL_PATH}login — продолжаем, но проверьте journalctl -u x-ui"

# Экспорт переменных для встроенного Python-агента
export DOMAIN EMAIL PANEL_USER PANEL_PASS PANEL_PATH PANEL_PORT
export SUB_PATH SUB_PORT WS_PATH_TROJAN WS_PATH_VLESS
export TROJAN_PORT TROJAN_PASS VLESS_UUID VLESS_PORT
export REALITY_PORT REALITY_ROTATE_PORT REALITY_UUID REALITY_PRIV REALITY_PUB
export REALITY_SHORT_ID REALITY_SHORT_ID_2
export HYSTERIA_PORT HY2_PASS
export REALITY_SNI_LIST_STR="${REALITY_SNI_LIST[*]}"

python3 <<'PYEOF'
import os, json, sys, time, urllib.request, urllib.error, http.cookiejar, ssl

domain       = os.environ['DOMAIN']
panel_path   = os.environ['PANEL_PATH']         # /abc/
panel_user   = os.environ['PANEL_USER']
panel_pass   = os.environ['PANEL_PASS']
panel_port   = os.environ['PANEL_PORT']

# Панель доступна через nginx (https://domain/panel_path/...)
base = f"https://{domain}{panel_path}".rstrip('/')

cj = http.cookiejar.CookieJar()
ctx = ssl.create_default_context()
opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(cj),
    urllib.request.HTTPSHandler(context=ctx)
)
opener.addheaders = [('User-Agent', 'install-script/1.0')]

def api_post(path, payload):
    url = f"{base}{path}"
    body = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=body, method='POST')
    req.add_header('Content-Type', 'application/json')
    try:
        resp = opener.open(req, timeout=30)
        return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8', 'ignore')
        print(f"  HTTP {e.code} на {path}: {body}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"  Ошибка на {path}: {e}", file=sys.stderr)
        return None

def api_get(path):
    url = f"{base}{path}"
    req = urllib.request.Request(url, method='GET')
    try:
        resp = opener.open(req, timeout=30)
        return json.loads(resp.read().decode('utf-8'))
    except Exception as e:
        print(f"  GET {path} ошибка: {e}", file=sys.stderr)
        return None

# --- Логин ---
print("  Логин в панель...")
# 3x-ui принимает JSON для /login
result = api_post('/login', {"username": panel_user, "password": panel_pass})
if not result or not result.get('success'):
    # fallback: попробуем form-data
    import urllib.parse
    data = urllib.parse.urlencode({"username": panel_user, "password": panel_pass}).encode()
    req = urllib.request.Request(f"{base}/login", data=data, method='POST')
    req.add_header('Content-Type', 'application/x-www-form-urlencoded')
    try:
        resp = opener.open(req, timeout=30)
        result = json.loads(resp.read().decode('utf-8'))
    except Exception as e:
        print(f"  Логин неудачен: {e}", file=sys.stderr)
        sys.exit(1)

if not result.get('success'):
    print(f"  Логин неудачен: {result}", file=sys.stderr)
    sys.exit(1)
print("  OK, авторизованы")

def add_inbound(inbound):
    res = api_post('/inbound/add', inbound)
    if res and res.get('success'):
        oid = (res.get('obj') or {}).get('id')
        print(f"  [+OK] {inbound['remark']:30s}  id={oid}  port={inbound['port']}")
        return oid
    else:
        msg = res.get('msg') if res else 'no response'
        # Если уже существует - не считаем ошибкой
        if 'already' in str(msg).lower() or 'exist' in str(msg).lower():
            print(f"  [SKIP] {inbound['remark']:30s} уже существует")
            return None
        print(f"  [FAIL] {inbound['remark']:30s} {msg}", file=sys.stderr)
        return None

def build_inbound(remark, protocol, listen, port, settings, stream, sniff=None, tag=None):
    if sniff is None:
        sniff = {"enabled": True, "destOverride": ["http", "tls", "quic"]}
    return {
        "up": 0, "down": 0, "total": 0,
        "remark": remark,
        "enable": True,
        "expiryTime": 0,
        "listen": listen,
        "port": int(port),
        "protocol": protocol,
        "settings": json.dumps(settings, ensure_ascii=False),
        "streamSettings": json.dumps(stream, ensure_ascii=False),
        "sniffing": json.dumps(sniff, ensure_ascii=False),
        "tag": tag or f"inbound-{port}",
    }

# ---------- 1. Trojan + WS + TLS via domain ----------
trojan_pass  = os.environ['TROJAN_PASS']
ws_path_tr   = os.environ['WS_PATH_TROJAN']
trojan_port  = int(os.environ['TROJAN_PORT'])
sub_path_id  = os.environ['SUB_PATH'].strip('/')

trojan_in = build_inbound(
    "trojan-ws-tls",
    "trojan",
    "127.0.0.1",
    trojan_port,
    settings={
        "clients": [{
            "password": trojan_pass,
            "flow": "",
            "email": f"trojan@{domain}",
            "limitIp": 2,
            "totalGB": 0,
            "expiryTime": 0,
            "enable": True,
            "tgId": "",
            "subId": sub_path_id[:16],
            "reset": 0
        }],
        "fallbacks": []
    },
    stream={
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": ws_path_tr, "headers": {}}
    },
)
add_inbound(trojan_in)

# ---------- 2. VLESS + WS + TLS via domain (CDN-ready) ----------
vless_uuid   = os.environ['VLESS_UUID']
ws_path_vl   = os.environ['WS_PATH_VLESS']
vless_port   = int(os.environ['VLESS_PORT'])

vless_ws_in = build_inbound(
    "vless-ws-tls",
    "vless",
    "127.0.0.1",
    vless_port,
    settings={
        "clients": [{
            "id": vless_uuid,
            "flow": "",
            "email": f"vless@{domain}",
            "limitIp": 2,
            "totalGB": 0,
            "expiryTime": 0,
            "enable": True,
            "tgId": "",
            "subId": sub_path_id[:16],
            "reset": 0
        }],
        "decryption": "none",
        "fallbacks": []
    },
    stream={
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": ws_path_vl, "headers": {}}
    },
)
add_inbound(vless_ws_in)

# ---------- 3. VLESS + Reality + Vision (фиксированный SNI: microsoft) ----------
reality_uuid = os.environ['REALITY_UUID']
reality_priv = os.environ['REALITY_PRIV']
reality_sid1 = os.environ['REALITY_SHORT_ID']
reality_port = int(os.environ['REALITY_PORT'])

reality_fixed_in = build_inbound(
    "vless-reality-microsoft",
    "vless",
    "0.0.0.0",
    reality_port,
    settings={
        "clients": [{
            "id": reality_uuid,
            "flow": "xtls-rprx-vision",
            "email": f"reality@{domain}",
            "limitIp": 2,
            "totalGB": 0,
            "expiryTime": 0,
            "enable": True,
            "tgId": "",
            "subId": sub_path_id[:16],
            "reset": 0
        }],
        "decryption": "none",
        "fallbacks": []
    },
    stream={
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": False,
            "dest": "www.microsoft.com:443",
            "serverNames": ["www.microsoft.com", "microsoft.com"],
            "privateKey": reality_priv,
            "shortIds": [reality_sid1],
            "spiderX": ""
        }
    },
)
reality_fixed_id = add_inbound(reality_fixed_in)

# ---------- 4. VLESS + Reality + Vision (авто-ротация SNI) ----------
reality_port_rot = int(os.environ['REALITY_ROTATE_PORT'])
reality_sid2     = os.environ['REALITY_SHORT_ID_2']

reality_rot_in = build_inbound(
    "vless-reality-auto",
    "vless",
    "0.0.0.0",
    reality_port_rot,
    settings={
        "clients": [{
            "id": reality_uuid,
            "flow": "xtls-rprx-vision",
            "email": f"reality-auto@{domain}",
            "limitIp": 2,
            "totalGB": 0,
            "expiryTime": 0,
            "enable": True,
            "tgId": "",
            "subId": sub_path_id[:16],
            "reset": 0
        }],
        "decryption": "none",
        "fallbacks": []
    },
    stream={
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": False,
            "dest": "www.microsoft.com:443",   # будет ротироваться rotate-sni.sh
            "serverNames": ["www.microsoft.com", "microsoft.com"],
            "privateKey": reality_priv,
            "shortIds": [reality_sid2],
            "spiderX": ""
        }
    },
)
reality_rot_id = add_inbound(reality_rot_in)

# Сохраняем ID авто-ротационного инбаунда для rotate-sni.sh
if reality_rot_id is not None:
    with open('/etc/x-ui/rotator.conf', 'w') as f:
        f.write(f"ROTATE_INBOUND_ID={reality_rot_id}\n")
        f.write(f"ROTATE_PORT={reality_port_rot}\n")
        f.write(f"REALITY_UUID={reality_uuid}\n")
        f.write(f"REALITY_PUB={os.environ['REALITY_PUB']}\n")
        f.write(f"REALITY_SHORT_ID_2={reality_sid2}\n")
        f.write(f"REALITY_PRIV={reality_priv}\n")
        f.write(f"DOMAIN={domain}\n")
        f.write(f"PANEL_USER={panel_user}\n")
        f.write(f"PANEL_PASS={panel_pass}\n")
        f.write(f"PANEL_PATH={panel_path}\n")
        f.write(f"SNI_LIST={os.environ.get('REALITY_SNI_LIST_STR','')}\n")
    os.chmod('/etc/x-ui/rotator.conf', 0o600)

# ---------- 5. Hysteria2 (UDP) ----------
hy2_pass  = os.environ['HY2_PASS']
hy2_port  = int(os.environ['HYSTERIA_PORT'])

hysteria_in = build_inbound(
    "hysteria2",
    "hysteria2",
    "0.0.0.0",
    hy2_port,
    settings={
        "clients": [{
            "password": hy2_pass,
            "email": f"hy2@{domain}",
            "limitIp": 2,
            "totalGB": 0,
            "expiryTime": 0,
            "enable": True,
            "tgId": "",
            "subId": sub_path_id[:16],
            "reset": 0
        }],
        "obfs": "salamander",
        "obfsSettings": {"password": hy2_pass},
        "ignoreClientBandwidth": False
    },
    stream={
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": domain,
            "certFile": f"/etc/letsencrypt/live/{domain}/fullchain.pem",
            "keyFile": f"/etc/letsencrypt/live/{domain}/privkey.pem",
            "minVersion": "1.3",
            "maxVersion": "1.3"
        }
    },
)
add_inbound(hysteria_in)

# Финальный рестарт Xray через панель (применение всех инбаундов)
print("  Применение конфигурации Xray...")
res = api_post('/xui_api/restart_xray', {})  # может отсутствовать в некоторых версиях
if not res or not res.get('success'):
    # fallback: рестарт сервиса
    pass  # выполним ниже через systemctl

print("  Готово: все инбаунды созданы")
PYEOF

# Рестарт 3x-ui для гарантированного применения всех инбаундов
log "Перезапуск 3x-ui и применение конфигурации Xray..."
systemctl restart x-ui
sleep 3

# ---------------------------------------------------------------------------
# Создание rotate-sni.sh (авто-подбор сайтов маскировки для Reality)
# ---------------------------------------------------------------------------
log "Установка авто-ротатора SNI (rotate-sni.sh)..."

cat > /usr/local/bin/rotate-sni.sh <<'ROTATEEOF'
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
req = urllib.request.Request(f"{base}/inbound/get/{inbound_id}")
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
req = urllib.request.Request(f"{base}/inbound/update/{inbound_id}", data=body, method='POST')
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
ROTATEEOF

chmod +x /usr/local/bin/rotate-sni.sh

# Создаём лог-файл
touch /var/log/rotate-sni.log
chmod 640 /var/log/rotate-sni.log

# Установка cron-задачи (каждые 6 часов)
CRON_LINE="0 */6 * * * /usr/local/bin/rotate-sni.sh >> /var/log/rotate-sni.log 2>&1"
if [[ -x /usr/local/bin/rotate-sni.sh ]]; then
    # Удаляем старую запись если есть, добавляем новую
    ( crontab -l 2>/dev/null | grep -v 'rotate-sni.sh' ; echo "$CRON_LINE" ) | crontab -
    log "Cron-задача ротации SNI установлена (каждые 6 часов)"
fi

# Первый запуск ротации
log "Первый запуск ротации SNI..."
/usr/local/bin/rotate-sni.sh || warn "Первый запуск ротации завершился с предупреждением (это нормально)"

# ---------------------------------------------------------------------------
# Настройка firewall (UFW)
# ---------------------------------------------------------------------------
log "Настройка UFW firewall..."

# Корректная обработка отказа SSH при включении UFW
SSH_PORT=$(ss -ltn 2>/dev/null | grep -oE ':([0-9]+)' | grep -E '^(22|2222)$' | head -1 | tr -d ':' || echo "22")
[[ -z "$SSH_PORT" ]] && SSH_PORT=22

ufw --force reset >/dev/null 2>&1
ufw allow ${SSH_PORT}/tcp comment 'SSH' >/dev/null
ufw allow 80/tcp   comment 'HTTP nginx'  >/dev/null
ufw allow 443/tcp  comment 'HTTPS nginx + WS' >/dev/null
ufw allow ${REALITY_PORT}/tcp        comment 'VLESS Reality fixed'   >/dev/null
ufw allow ${REALITY_ROTATE_PORT}/tcp comment 'VLESS Reality auto'    >/dev/null
ufw allow ${HYSTERIA_PORT}/udp       comment 'Hysteria2'             >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null 2>&1

log "UFW настроен. Открытые порты:"
ufw status numbered 2>/dev/null | sed 's/^/    /' || true

# ---------------------------------------------------------------------------
# Финальный рестарт всех сервисов
# ---------------------------------------------------------------------------
log "Финальный перезапуск сервисов..."
systemctl restart x-ui
systemctl reload nginx 2>/dev/null || systemctl restart nginx
systemctl enable --now nginx x-ui cron >/dev/null 2>&1 || true

# Пауза и проверка
sleep 4

# ---------------------------------------------------------------------------
# Проверка что всё слушает
# ---------------------------------------------------------------------------
log "Проверка слушающих портов..."
PORTS_OK=1
check_port() {
    local proto="$1" port="$2" name="$3"
    if ss -l${proto}n 2>/dev/null | grep -q ":${port}\b"; then
        echo -e "    ${GREEN}✓${NC} $name ($proto:$port)"
    else
        echo -e "    ${RED}✗${NC} $name ($proto:$port) — НЕ СЛУШАЕТ"
        PORTS_OK=0
    fi
}
check_port t 80    "Nginx HTTP"
check_port t 443   "Nginx HTTPS"
check_port t ${PANEL_PORT}     "3x-ui panel"
check_port t ${SUB_PORT}       "3x-ui subscription"
check_port t ${TROJAN_PORT}    "Trojan WS"
check_port t ${VLESS_PORT}     "VLESS WS"
check_port t ${REALITY_PORT}        "Reality fixed"
check_port t ${REALITY_ROTATE_PORT} "Reality auto"
check_port u ${HYSTERIA_PORT}  "Hysteria2"

if [[ $PORTS_OK -eq 0 ]]; then
    warn "Не все порты слушают. Проверьте: journalctl -u x-ui -u nginx --no-pager | tail -50"
fi

# ---------------------------------------------------------------------------
# Проверка что лендинг открывается
# ---------------------------------------------------------------------------
log "Проверка лендинга и панели..."
if curl -fsk "https://${DOMAIN}/" -o /dev/null --max-time 10 2>/dev/null; then
    echo -e "    ${GREEN}✓${NC} Лендинг доступен: https://${DOMAIN}/"
else
    warn "Лендинг не отвечает: https://${DOMAIN}/ (возможно, нужно подождать)"
fi

if curl -fsk "https://${DOMAIN}${PANEL_PATH}" -o /dev/null --max-time 10 2>/dev/null; then
    echo -e "    ${GREEN}✓${NC} Панель доступна: https://${DOMAIN}${PANEL_PATH}"
else
    warn "Панель не отвечает по https (возможно, DNS ещё не разошёлся)"
fi

# ---------------------------------------------------------------------------
# Финальная сводка
# ---------------------------------------------------------------------------
PUB_IP="${SERVER_IP:-$(curl -fsS4 https://api.ipify.org 2>/dev/null || echo 'не определён')}"

cat <<SUMMARY

$(echo -e ${GREEN}${BOLD}============================================================${NC})
$(echo -e ${GREEN}${BOLD}  УСТАНОВКА ЗАВЕРШЕНА${NC})
$(echo -e ${GREEN}${BOLD}============================================================${NC})

$(echo -e ${CYAN}Домен:${NC}            $DOMAIN
${CYAN}IP сервера:${NC}      $PUB_IP
${CYAN}Лендинг:${NC}         https://$DOMAIN/

$(echo -e ${YELLOW}${BOLD}Панель управления:${NC})
  URL:      https://$DOMAIN$PANEL_PATH
  Логин:    $PANEL_USER
  Пароль:   $PANEL_PASS
  $(warn 'ВНИМАНИЕ: сохраните пароль в надёжном месте!')

$(echo -e ${YELLOW}${BOLD}Subscription URL (для клиентов):${NC})
  https://$DOMAIN$SUB_PATH

$(echo -e ${YELLOW}${BOLD}Готовые инбаунды (только рабочие в РФ 2025-2026):${NC})

$(echo -e ${GREEN}1. Trojan + WS + TLS${NC}  $(echo -e ${YELLOW}[основной, стабильно работает в РФ]${NC})
   Address:  $DOMAIN
   Port:     443
   Password: $TROJAN_PASS
   Network:  ws
   Path:     $WS_PATH_TROJAN
   TLS:      tls, SNI=$DOMAIN, ALPN=http/1.1
   VLESS:    —

$(echo -e ${GREEN}2. VLESS + WS + TLS${NC}  $(echo -e ${YELLOW}[CDN-ready, можно за Cloudflare]${NC})
   Address:  $DOMAIN
   Port:     443
   UUID:     $VLESS_UUID
   Network:  ws
   Path:     $WS_PATH_VLESS
   TLS:      tls, SNI=$DOMAIN
   Flow:     (пусто для WS)

$(echo -e ${GREEN}3. VLESS + Reality + Vision${NC}  $(echo -e ${YELLOW}[фиксированный SNI: microsoft.com]${NC})
   Address:  $DOMAIN
   Port:     $REALITY_PORT
   UUID:     $REALITY_UUID
   Flow:     xtls-rprx-vision
   Security: reality
   SNI:      www.microsoft.com
   Fingerprint: chrome
   PublicKey: $REALITY_PUB
   ShortId:  $REALITY_SHORT_ID
   SpiderX:  (пусто)
   $(warn 'Клиент коннектится к $DOMAIN:$REALITY_PORT, SNI в TLS=microsoft.com')

$(echo -e ${GREEN}4. VLESS + Reality + Vision${NC}  $(echo -e ${YELLOW}[АВТО-РОТАЦИЯ SNI маскировки]${NC})
   Address:  $DOMAIN
   Port:     $REALITY_ROTATE_PORT
   UUID:     $REALITY_UUID
   Flow:     xtls-rprx-vision
   Security: reality
   PublicKey: $REALITY_PUB
   ShortId:  $REALITY_SHORT_ID_2
   SNI:      (авто-подбор каждые 6 часов из списка:
             ${REALITY_SNI_LIST[*]})
   $(warn 'Текущий SNI смотреть: /etc/x-ui/rotator.conf и /var/log/rotate-sni.log')
   $(warn 'Для подключения клиента используйте URL из панели 3x-ui (она обновляет SNI автоматически)')

$(echo -e ${GREEN}5. Hysteria2${NC}  $(echo -e ${YELLOW}[UDP, DPI-устойчивый]${NC})
   Address:  $DOMAIN
   Port:     $HYSTERIA_PORT (UDP)
   Password: $HY2_PASS
   Obfs:     salamander (password = $HY2_PASS)
   TLS SNI:  $DOMAIN, TLS 1.3

$(echo -e ${YELLOW}${BOLD}Файлы конфигурации:${NC})
  /etc/x-ui/install.conf       — все параметры и секреты (chmod 600)
  /etc/x-ui/rotator.conf       — параметры ротатора SNI
  /usr/local/bin/rotate-sni.sh — скрипт авто-подбора SNI
  /var/log/rotate-sni.log      — логи ротатора
  /etc/nginx/sites-available/${DOMAIN}.conf — конфиг nginx
  /var/www/landing/            — файлы лендинга-заглушки

$(echo -e ${YELLOW}${BOLD}Рекомендации по использованию в РФ:${NC})
  • Основной протокол: Trojan+WS+TLS (порт 443) — стабилен на всех ISP
  • Запасной:    VLESS+Reality+Vision (порт $REALITY_PORT, SNI=microsoft.com)
  • Если заблокируют домен: используйте инбаунд #2 (VLESS+WS+TLS) через Cloudflare CDN
    (переведите домен в CF, включите проксирование, порт 443 ws path останется)
  • Hysteria2: использовать при агрессивном DPI на TCP, но некоторые ISP режут UDP
  • Reality auto-rotate (#4): на случай если фиксированный SNI заблокируют

$(echo -e ${YELLOW}${BOLD}Полезные команды:${NC})
  x-ui status              — статус панели
  x-ui restart             — перезапуск панели и Xray
  /usr/local/bin/rotate-sni.sh  — ручной запуск ротации SNI
  tail -f /var/log/rotate-sni.log — мониторинг ротации
  ufw status               — статус firewall
  certbot renew --dry-run  — проверка авто-обновления сертификата

============================================================
SUMMARY

# Сохраняем сводку в файл для будущего использования
umask 077
{
    echo "# Сводка установки 3x-ui от $(date)"
    echo "# ВНИМАНИЕ: файл содержит секреты! chmod 600"
    echo ""
    echo "PANEL_URL=https://$DOMAIN$PANEL_PATH"
    echo "PANEL_USER=$PANEL_USER"
    echo "PANEL_PASS=$PANEL_PASS"
    echo "SUB_URL=https://$DOMAIN$SUB_PATH"
    echo ""
    echo "TROJAN_DOMAIN=$DOMAIN"
    echo "TROJAN_PORT=443"
    echo "TROJAN_PASS=$TROJAN_PASS"
    echo "TROJAN_PATH=$WS_PATH_TROJAN"
    echo ""
    echo "VLESS_WS_UUID=$VLESS_UUID"
    echo "VLESS_WS_PATH=$WS_PATH_VLESS"
    echo ""
    echo "REALITY_DOMAIN=$DOMAIN"
    echo "REALITY_PORT=$REALITY_PORT"
    echo "REALITY_UUID=$REALITY_UUID"
    echo "REALITY_PUB=$REALITY_PUB"
    echo "REALITY_SHORT_ID=$REALITY_SHORT_ID"
    echo ""
    echo "REALITY_AUTO_PORT=$REALITY_ROTATE_PORT"
    echo "REALITY_AUTO_SHORT_ID=$REALITY_SHORT_ID_2"
    echo ""
    echo "HY2_DOMAIN=$DOMAIN"
    echo "HY2_PORT=$HYSTERIA_PORT"
    echo "HY2_PASS=$HY2_PASS"
} > /etc/x-ui/credentials.txt
chmod 600 /etc/x-ui/credentials.txt

log "Учётные данные сохранены: /etc/x-ui/credentials.txt (chmod 600)"
log "Установка полностью завершена!"
warn "Не забудьте: 1) открыть порты в панели VPS-провайдера, 2) проверить A-запись DNS."
