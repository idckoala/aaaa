#!/bin/bash
set +e

if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

PORT=8080
XRAY_DIR="/usr/local/etc/xray"
CONFIG="$XRAY_DIR/config.json"
DB="$XRAY_DIR/users.db"
DOMAIN_FILE="$XRAY_DIR/domain"
WEB_DIR="/var/www/html/sub"
TEMPLATE_FILE="/root/template.html"

export TZ=Asia/Bangkok

C='\033[1;36m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; P='\033[1;35m'; N='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${R}❌ กรุณารันด้วยสิทธิ์ root (sudo -i)${N}" && exit

pause(){ 
    echo ""
    read -n 1 -s -r -p "👉 กดปุ่มใดก็ได้ เพื่อกลับสู่เมนูหลัก... " 
}

# ===== 1. INSTALL & API SETUP =====
install_all(){
clear
echo -e "${C}╔═════════════════════════════════════════╗${N}"
echo -e "${C}║            ${P}⚙️ ติดตั้งระบบใหม่${C}             ║${N}"
echo -e "${C}╚═════════════════════════════════════════╝${N}"

# เช็คก่อนว่าเอาไฟล์ Template มาวางหรือยัง
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${R}❌ ไม่พบไฟล์ template.html${N}"
    echo -e "${Y}กรุณาสร้างไฟล์ template.html ใน /root ก่อนติดตั้งครับ!${N}"
    pause
    return
fi

PUBLIC_IP=$(curl -sS ipv4.icanhazip.com || curl -sS ifconfig.me)
read -p " 👉 ใส่โดเมน (ถ้าไม่มีให้กด Enter เพื่อใช้ IP แทน): " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr -d ' ')
[ -z "$DOMAIN" ] && DOMAIN="$PUBLIC_IP"

echo -e "\n${Y}กำลังติดตั้งแพ็กเกจและเปิดระบบ Real-time Stats API...${N}"
systemctl stop apache2 >/dev/null 2>&1
apt remove apache2 -y >/dev/null 2>&1
apt install psmisc jq cron -y >/dev/null 2>&1
fuser -k 80/tcp >/dev/null 2>&1
fuser -k $PORT/tcp >/dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
apt update -y >/dev/null
apt install nginx curl ufw iptables iptables-persistent iproute2 uuid-runtime dos2unix -y >/dev/null

bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) >/dev/null 2>&1

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

cat > /etc/nginx/conf.d/vless.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    root /var/www/html;
    index index.html index.htm;
    server_name _;

    location ~* \.json$ {
        add_header Access-Control-Allow-Origin *;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /vless {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

mkdir -p "$XRAY_DIR" "$WEB_DIR"
chown -R www-data:www-data /var/www/html 2>/dev/null || true
chmod -R 755 /var/www/html 2>/dev/null
echo "$DOMAIN" > "$DOMAIN_FILE"
touch "$DB"

cat > /usr/local/bin/xray-stats-sync.sh <<'EOF'
#!/bin/bash
XRAY_BIN="/usr/local/bin/xray"
STATS=$($XRAY_BIN api statsquery --server=127.0.0.1:10085 2>/dev/null)
if [ -n "$STATS" ]; then
    echo "$STATS" > /var/www/html/sub/real_stats.json
    chmod 644 /var/www/html/sub/real_stats.json
fi
EOF
chmod +x /usr/local/bin/xray-stats-sync.sh

echo "* * * * * root /usr/local/bin/xray-stats-sync.sh" > /etc/cron.d/xray-stats
chmod 644 /etc/cron.d/xray-stats
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null

iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT 2>/dev/null
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport $PORT -j ACCEPT 2>/dev/null
netfilter-persistent save >/dev/null 2>&1 || true
ufw allow 80/tcp >/dev/null 2>&1
ufw allow $PORT/tcp >/dev/null 2>&1

systemctl enable nginx >/dev/null 2>&1
systemctl enable xray >/dev/null 2>&1
systemctl restart nginx >/dev/null 2>&1

build_config
/usr/local/bin/xray-stats-sync.sh >/dev/null 2>&1

echo ""
echo -e "${G}╔═════════════════════════════════════════╗${N}"
echo -e "${G}║  ✔️ ตั้งค่า Nginx และ Stats API สำเร็จ  ║${N}"
echo -e "${G}╚═════════════════════════════════════════╝${N}"
pause
}

# ===== 2. CONFIG XRAY WITH API =====
build_config(){
CLIENTS=""
NOW=$(date +%s)

DUMMY_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "11111111-2222-3333-4444-555555555555")
CLIENTS="{\"id\":\"$DUMMY_UUID\",\"email\":\"dummy\"},"

mkdir -p "$XRAY_DIR"
touch "$DB"
dos2unix "$DB" >/dev/null 2>&1 || sed -i 's/\r//g' "$DB" 2>/dev/null 

while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    u=$(echo "$line" | cut -d'|' -f1)
    id=$(echo "$line" | cut -d'|' -f2)
    exp=$(echo "$line" | cut -d'|' -f3)
    gb=$(echo "$line" | cut -d'|' -f4)
    EXP_EPOCH=$(date -d "$exp" +%s 2>/dev/null)
    if [[ -n "$EXP_EPOCH" && "$EXP_EPOCH" -gt "$NOW" ]]; then
        CLIENTS+="{\"id\":\"$id\",\"email\":\"$u\"},"
    fi
done < "$DB"

CLIENTS=${CLIENTS%,}

cat > "$CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "stats": {},
  "api": {
    "tag": "api",
    "services": [ "StatsService" ]
  },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ $CLIENTS ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" },
      "tag": "api"
    }
  ],
  "routing": {
    "rules": [
      { "inboundTag": [ "api" ], "outboundTag": "api", "type": "field" }
    ]
  },
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

systemctl restart xray >/dev/null 2>&1
/usr/local/bin/xray-stats-sync.sh >/dev/null 2>&1
}

# ===== 3. GAMING MODE =====
optimize_ping(){
clear
echo -e "${C}╔════════════════════════════════════════════════════╗${N}"
echo -e "${C}║       ${P}🎮 เปิดโหมดเกมมิ่ง (ลดปิง & ลดความหน่วง)${C}       ║${N}"
echo -e "${C}╠════════════════════════════════════════════════════╣${N}"
echo -e " ${Y}กำลังปรับแต่งระบบ Network (Sysctl) และเปิดใช้ BBR...${N}"

sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_mtu_probing/d' /etc/sysctl.conf

cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
EOF

sysctl -p >/dev/null 2>&1

echo -e " ${G}✔️ เปิดใช้งาน Google BBR ทะลวงความเร็วสำเร็จ!${N}"
echo -e "${C}╚════════════════════════════════════════════════════╝${N}"
pause
}

# ===== 4. ดึงไฟล์ HTML มาประกอบร่าง =====
create_web(){
USER=$1
UUID=$2
EXP=$3
GB=$4
PUBLIC_IP=$(curl -sS ipv4.icanhazip.com || curl -sS ifconfig.me)
DOMAIN=$(cat "$DOMAIN_FILE" 2>/dev/null || echo "$PUBLIC_IP")

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${R}❌ ไม่พบไฟล์ template.html${N}"
    return
fi

# ก๊อปปี้เทมเพลตแล้วเปลี่ยนตัวแปรให้เป็นของแต่ละ User
sed -e "s/{{USER}}/$USER/g" \
    -e "s/{{UUID}}/$UUID/g" \
    -e "s/{{EXP}}/$EXP/g" \
    -e "s/{{GB}}/$GB/g" \
    -e "s/{{DOMAIN}}/$DOMAIN/g" \
    -e "s/{{PORT}}/$PORT/g" \
    "$TEMPLATE_FILE" > "$WEB_DIR/$USER.html"

chmod -R 755 "$WEB_DIR" 2>/dev/null
chown -R www-data:www-data "$WEB_DIR" 2>/dev/null || true
}

# ===== 5. USER MANAGEMENT =====
add_user(){
clear
echo -e "${C}╔═════════════════════════════════════════╗${N}"
echo -e "${C}║          ${P}🌸 สร้างผู้ใช้งานใหม่ 🌸${C}         ║${N}"
echo -e "${C}╚═════════════════════════════════════════╝${N}"

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${R}❌ คุณยังไม่ได้สร้างไฟล์ template.html${N}"
    pause
    return
fi

mkdir -p "$XRAY_DIR" "$WEB_DIR"
touch "$DB" "$DOMAIN_FILE"

PUBLIC_IP=$(curl -sS ipv4.icanhazip.com || curl -sS ifconfig.me)
CURRENT_DOMAIN=$(cat "$DOMAIN_FILE" 2>/dev/null)
[ -z "$CURRENT_DOMAIN" ] && CURRENT_DOMAIN="$PUBLIC_IP"

read -p " 👤 ชื่อผู้ใช้งาน (USER): " USER_IN
USER=$(echo "$USER_IN" | tr -d ' ')
[ -z "$USER" ] && USER="user$(date +%s)"

read -p " 📅 จำนวนวัน (DAYS): " DAYS_IN
DAYS=$(echo "$DAYS_IN" | tr -dc '0-9')
[ -z "$DAYS" ] && DAYS=30

read -p " 📦 ปริมาณเน็ต (GB): " GB_IN
GB=$(echo "$GB_IN" | tr -dc '0-9')
[ -z "$GB" ] && GB=100

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "11111111-2222-3333-4444-555555555555")
EXP=$(date -d "+$DAYS days" +"%Y-%m-%d" 2>/dev/null || echo "2099-12-31")

echo "$USER|$UUID|$EXP|$GB" >> "$DB"

build_config
create_web "$USER" "$UUID" "$EXP" "$GB"

WEB_URL="http://$CURRENT_DOMAIN/sub/$USER.html"

clear
echo -e "${G}╔════════════════════════════════════════════════════════╗${N}"
echo -e "${G}║               ${Y}✔️ สร้างผู้ใช้งานเสร็จสมบูรณ์${G}              ║${N}"
echo -e "${G}╠════════════════════════════════════════════════════════╣${N}"
echo -e "${G}║${N} 👤 ชื่อผู้ใช้  : ${C}$USER${N}"
echo -e "${G}║${N} 🔑 UUID      : ${C}$UUID${N}"
echo -e "${G}║${N} 📅 วันหมดอายุ : ${C}$EXP${N}"
echo -e "${G}║${N} 📦 ปริมาณเน็ต : ${C}$GB GB${N}"
echo -e "${G}╠════════════════════════════════════════════════════════╣${N}"
echo -e "${G}║${N} 🌐 ${Y}ลิงก์หน้าเว็บสำหรับลูกค้า:${N}"
echo -e "${G}║${N} ${P}$WEB_URL${N}"
echo -e "${G}╚════════════════════════════════════════════════════════╝${N}"
pause
}

list_user(){
clear
echo -e "${C}╔═════════════════════════════════════════════════════════════════╗${N}"
echo -e "${C}║                      ${P}🌸 รายชื่อผู้ใช้งาน 🌸${C}                     ║${N}"
echo -e "${C}╠═════════════╦══════════════╦══════╦═════════════════════════════╣${N}"
echo -e "${C}║${N} ${Y}USER${N}        ${C}║${N} ${Y}EXP${N}          ${C}║${N} ${Y}GB${N}   ${C}║${N} ${Y}UUID${N}                        ${C}║${N}"
echo -e "${C}╠═════════════╬══════════════╬══════╬═════════════════════════════╣${N}"

if [ ! -s "$DB" ]; then
    echo -e "${C}║${Y}                     ยังไม่มีผู้ใช้งานในระบบ                     ${C}║${N}"
else
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        u=$(echo "$line" | cut -d'|' -f1)
        id=$(echo "$line" | cut -d'|' -f2)
        exp=$(echo "$line" | cut -d'|' -f3)
        gb=$(echo "$line" | cut -d'|' -f4)
        printf "${C}║${N} %-11s ${C}║${N} %-12s ${C}║${N} %-4s ${C}║${N} %-27s ${C}║\n${N}" "$u" "$exp" "$gb" "$id"
    done < "$DB"
fi

echo -e "${C}╚═════════════════════════════════════════════════════════════════╝${N}"
pause
}

del_user(){
clear
echo -e "${R}╔═════════════════════════════════════════╗${N}"
echo -e "${R}║           ${Y}🗑️ ลบผู้ใช้งานระบบ${R}             ║${N}"
echo -e "${R}╚═════════════════════════════════════════╝${N}"

if [ ! -s "$DB" ]; then
    echo -e "\n  ${Y}🤷‍♂️ ยังไม่มีผู้ใช้งานในระบบ ให้คุณลบครับ${N}"
    pause
    return
fi

USERS_ARRAY=()
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && USERS_ARRAY+=("$line")
done < "$DB"

echo -e " ${C}กรุณาพิมพ์หมายเลขของผู้ใช้ที่ต้องการลบ:${N}"
echo -e "${P}-----------------------------------------${N}"
for i in "${!USERS_ARRAY[@]}"; do
    u_name=$(echo "${USERS_ARRAY[$i]}" | cut -d'|' -f1)
    u_exp=$(echo "${USERS_ARRAY[$i]}" | cut -d'|' -f3)
    printf "  ${G}[%d]${N} %-15s (หมดอายุ: %s)\n" "$((i+1))" "$u_name" "$u_exp"
done
echo -e "${P}-----------------------------------------${N}"
echo -e "  ${R}[0] ยกเลิกและกลับเมนูหลัก${N}"
echo ""
read -p " 👉 เลือกลำดับหมายเลข: " NUM_IN
NUM=$(echo "$NUM_IN" | tr -dc '0-9')

if [ -z "$NUM" ] || [ "$NUM" -eq 0 ]; then
    return
fi

if [ "$NUM" -ge 1 ] && [ "$NUM" -le "${#USERS_ARRAY[@]}" ]; then
    TARGET_LINE="${USERS_ARRAY[$((NUM-1))]}"
    TARGET_NAME=$(echo "$TARGET_LINE" | cut -d'|' -f1)
    
    grep -v "^$TARGET_NAME|" "$DB" > "$DB.tmp"
    mv "$DB.tmp" "$DB"
    rm -f "$WEB_DIR/$TARGET_NAME.html"
    build_config
    
    echo ""
    echo -e "${G}╔═════════════════════════════════════════╗${N}"
    echo -e "${G}║      ✔️ ลบผู้ใช้ ${Y}$TARGET_NAME${G} สำเร็จแล้ว     ║${N}"
    echo -e "${G}╚═════════════════════════════════════════╝${N}"
else
    echo -e "\n${R}❌ หมายเลขไม่ถูกต้อง กรุณาลองใหม่!${N}"
fi
pause
}

change_domain(){
clear
echo -e "${Y}╔═════════════════════════════════════════╗${N}"
echo -e "${Y}║         ${C}🌐 เปลี่ยนโดเมนระบบใหม่${Y}         ║${N}"
echo -e "${Y}╚═════════════════════════════════════════╝${N}"
read -p " 👉 ใส่โดเมนใหม่: " NEW_IN
NEW=$(echo "$NEW_IN" | tr -d ' ')
echo "$NEW" > "$DOMAIN_FILE"

while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    u=$(echo "$line" | cut -d'|' -f1)
    id=$(echo "$line" | cut -d'|' -f2)
    exp=$(echo "$line" | cut -d'|' -f3)
    gb=$(echo "$line" | cut -d'|' -f4)
    create_web "$u" "$id" "$exp" "$gb" > /dev/null
done < "$DB"

echo ""
echo -e "${G}╔═════════════════════════════════════════╗${N}"
echo -e "${G}║        ✔️ อัปเดตโดเมนใหม่เรียบร้อย      ║${N}"
echo -e "${G}╚═════════════════════════════════════════╝${N}"
pause
}

check_online(){
clear
echo -e "${C}╔════════════════════════════════════════════════════╗${N}"
echo -e "${C}║       ${P}📡 สแกนสถานะผู้ใช้งานออนไลน์ (Real-Time)${C}     ║${N}"
echo -e "${C}╠════════════════════════════════════════════════════╣${N}"

CONNECTIONS=$(ss -tnp 2>/dev/null | grep "ESTAB" | grep ":$PORT ")
TOTAL_CONN=$(echo "$CONNECTIONS" | grep -c "ESTAB")

if [ "$TOTAL_CONN" -eq 0 ]; then
    echo -e "${C}║${Y}         😴 ยังไม่มีผู้ใช้งานเชื่อมต่อเข้ามา          ${C}║${N}"
else
    echo -e "${C}║${G} 🟢 กำลังเชื่อมต่อทั้งหมด: ${Y}${TOTAL_CONN}${G} เซสชั่น (Sessions)    ${C}║${N}"
    echo -e "${C}╠════════════════╦═══════════════════════════════════╣${N}"
    echo -e "${C}║${N} ${Y}จำนวน (Conn)${N}   ${C}║${N} ${Y}IP Address ลูกค้าที่กำลังใช้งาน${N}     ${C}║${N}"
    echo -e "${C}╠════════════════╬═══════════════════════════════════╣${N}"
    
    echo "$CONNECTIONS" | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr | while read count ip; do
        printf "${C}║${N} %-14s ${C}║${N} ${G}%-33s${N} ${C}║\n${N}" "${Y}${count}${N}" "$ip"
    done
fi

echo -e "${C}╚════════════════════════════════════════════════════╝${N}"
pause
}

# ===== MENU LOOP =====
menu(){
while true; do
clear
DOMAIN=$(cat "$DOMAIN_FILE" 2>/dev/null)
TOTAL=$(grep -c "|" "$DB" 2>/dev/null)

XRAY_STAT=$(systemctl is-active xray 2>/dev/null)
NGINX_STAT=$(systemctl is-active nginx 2>/dev/null)
[ "$XRAY_STAT" == "active" ] && X_ST="${G}🟢 ทำงานปกติ${N}" || X_ST="${R}🔴 หยุดทำงาน${N}"
[ "$NGINX_STAT" == "active" ] && N_ST="${G}🟢 ทำงานปกติ${N}" || N_ST="${R}🔴 หยุดทำงาน${N}"

echo -e "${C}╔═════════════════════════════════════════╗${N}"
echo -e "${C}║          ${P}🌸 VLESS PANEL PRO 🌸${C}          ║${N}"
echo -e "${C}╠═════════════════════════════════════════╣${N}"
echo -e "${C}║${N} 🌐 โดเมน: ${P}$DOMAIN${N}"
echo -e "${C}║${N} 👥 ผู้ใช้ทั้งหมด: ${Y}$TOTAL${N} users"
echo -e "${C}║${N} ⚡ สถานะ Xray : $X_ST"
echo -e "${C}║${N} 🌐 สถานะ Web  : $N_ST"
echo -e "${C}╠═════════════════════════════════════════╣${N}"
echo -e "${C}║${N} ${Y}1)${N} ติดตั้งระบบใหม่ (แก้ไฟล์พัง / เปิดพอร์ต)"
echo -e "${C}║${N} ${G}2)${N} สร้างผู้ใช้งาน + ลิงก์เว็บ"
echo -e "${C}║${N} ${Y}3)${N} ดูรายชื่อผู้ใช้"
echo -e "${C}║${N} ${R}4)${N} ลบผู้ใช้งาน"
echo -e "${C}║${N} ${Y}5)${N} รีโหลดระบบ"
echo -e "${C}║${N} ${Y}6)${N} เปลี่ยนโดเมน"
echo -e "${C}║${N} ${G}7)${N} เช็คคนออนไลน์ (Real-time)"
echo -e "${C}║${N} ${P}8)${N} เปิดโหมดเกมมิ่ง (ลดปิง BBR)"
echo -e "${C}║${N} ${R}0)${N} ออกจากระบบ"
echo -e "${C}╚═════════════════════════════════════════╝${N}"
echo -e ""
read -p " เลือกระบบที่ต้องการ: " m

case $m in
1) install_all ;;
2) add_user ;;
3) list_user ;;
4) del_user ;;
5) 
    build_config
    echo ""
    echo -e "${G}╔═════════════════════════════════════════╗${N}"
    echo -e "${G}║         ✔️ รีโหลดระบบเรียบร้อยแล้ว      ║${N}"
    echo -e "${G}╚═════════════════════════════════════════╝${N}"
    pause 
    ;;
6) change_domain ;;
7) check_online ;;
8) optimize_ping ;;
0) clear; exit ;;
*) 
    echo -e "${R}❌ เลือกผิดเมนู กรุณาลองใหม่${N}"
    sleep 1 
    ;;
esac

done
}

menu
