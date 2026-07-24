#!/bin/bash
#
# Setup script for testing Lightweight Cloud Connector
# Installs: RDP, VNC, and Database servers
#
# Usage: sudo ./setup_vm_test_services.sh [options]
# Options:
#   --all       Install all services (default)
#   --rdp       Install only RDP (xrdp)
#   --vnc       Install only VNC (TigerVNC)
#   --mysql     Install only MySQL
#   --postgres  Install only PostgreSQL
#   --redis     Install only Redis
#   --mongodb   Install only MongoDB
#   --desktop   Install desktop environment (XFCE)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default: install all
INSTALL_RDP=false
INSTALL_VNC=false
INSTALL_MYSQL=false
INSTALL_POSTGRES=false
INSTALL_REDIS=false
INSTALL_MONGODB=false
INSTALL_DESKTOP=false
INSTALL_ALL=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --rdp)      INSTALL_RDP=true; INSTALL_ALL=false ;;
        --vnc)      INSTALL_VNC=true; INSTALL_ALL=false ;;
        --mysql)    INSTALL_MYSQL=true; INSTALL_ALL=false ;;
        --postgres) INSTALL_POSTGRES=true; INSTALL_ALL=false ;;
        --redis)    INSTALL_REDIS=true; INSTALL_ALL=false ;;
        --mongodb)  INSTALL_MONGODB=true; INSTALL_ALL=false ;;
        --desktop)  INSTALL_DESKTOP=true; INSTALL_ALL=false ;;
        --all)      INSTALL_ALL=true ;;
        -h|--help)
            echo "Usage: sudo $0 [options]"
            echo "Options:"
            echo "  --all       Install all services (default)"
            echo "  --rdp       Install RDP server (xrdp)"
            echo "  --vnc       Install VNC server (TigerVNC)"
            echo "  --mysql     Install MySQL server"
            echo "  --postgres  Install PostgreSQL server"
            echo "  --redis     Install Redis server"
            echo "  --mongodb   Install MongoDB server"
            echo "  --desktop   Install XFCE desktop environment"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# If --all, enable everything
if [ "$INSTALL_ALL" = true ]; then
    INSTALL_RDP=true
    INSTALL_VNC=true
    INSTALL_MYSQL=true
    INSTALL_POSTGRES=true
    INSTALL_REDIS=true
    INSTALL_MONGODB=true
    INSTALL_DESKTOP=true
fi

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (sudo)${NC}"
    exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    echo -e "${RED}Cannot detect OS${NC}"
    exit 1
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Lightweight Cloud Connector - VM Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Detected OS: ${GREEN}$OS $VERSION${NC}"
echo ""

# Update system
echo -e "${YELLOW}[1/8] Updating system...${NC}"
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get update -qq
    apt-get upgrade -y -qq
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    yum update -y -q
elif [[ "$OS" == "fedora" ]]; then
    dnf update -y -q
fi

# ==========================================
# DESKTOP ENVIRONMENT
# ==========================================
if [ "$INSTALL_DESKTOP" = true ]; then
    echo -e "${YELLOW}[2/8] Installing XFCE Desktop Environment...${NC}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            xfce4 xfce4-goodies dbus-x11 x11-xserver-utils
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum groupinstall -y -q "Xfce"
        yum install -y -q dbus-x11
    elif [[ "$OS" == "fedora" ]]; then
        dnf groupinstall -y -q "Xfce Desktop"
        dnf install -y -q dbus-x11
    fi
    echo -e "${GREEN}  ✓ XFCE installed${NC}"
fi

# ==========================================
# RDP SERVER (xrdp)
# ==========================================
if [ "$INSTALL_RDP" = true ]; then
    echo -e "${YELLOW}[3/8] Installing RDP Server (xrdp)...${NC}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get install -y -qq xrdp
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y -q epel-release
        yum install -y -q xrdp
    elif [[ "$OS" == "fedora" ]]; then
        dnf install -y -q xrdp
    fi

    # Configure xrdp to use XFCE
    if [ "$INSTALL_DESKTOP" = true ]; then
        echo "xfce4-session" > /etc/skel/.xsession
        # For current user too
        REAL_USER=${SUDO_USER:-$USER}
        if [ "$REAL_USER" != "root" ]; then
            echo "xfce4-session" > /home/$REAL_USER/.xsession
            chown $REAL_USER:$REAL_USER /home/$REAL_USER/.xsession
        fi
    fi

    # Enable and start xrdp
    systemctl enable xrdp
    systemctl start xrdp

    echo -e "${GREEN}  ✓ xrdp installed and running on port 3389${NC}"
fi

# ==========================================
# VNC SERVER (TigerVNC)
# ==========================================
if [ "$INSTALL_VNC" = true ]; then
    echo -e "${YELLOW}[4/8] Installing VNC Server (TigerVNC)...${NC}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get install -y -qq tigervnc-standalone-server tigervnc-common
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y -q tigervnc-server
    elif [[ "$OS" == "fedora" ]]; then
        dnf install -y -q tigervnc-server
    fi

    # Create VNC startup script
    REAL_USER=${SUDO_USER:-$USER}
    if [ "$REAL_USER" != "root" ]; then
        USER_HOME="/home/$REAL_USER"
    else
        USER_HOME="/root"
    fi

    mkdir -p $USER_HOME/.vnc

    # Create xstartup for XFCE
    cat > $USER_HOME/.vnc/xstartup << 'EOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
    chmod +x $USER_HOME/.vnc/xstartup

    # Set VNC password (default: test1234)
    echo -e "${BLUE}Setting VNC password to: test1234${NC}"
    echo "test1234" | vncpasswd -f > $USER_HOME/.vnc/passwd
    chmod 600 $USER_HOME/.vnc/passwd

    if [ "$REAL_USER" != "root" ]; then
        chown -R $REAL_USER:$REAL_USER $USER_HOME/.vnc
    fi

    # Create systemd service for VNC
    cat > /etc/systemd/system/vncserver@.service << EOF
[Unit]
Description=TigerVNC server on display %i
After=syslog.target network.target

[Service]
Type=simple
User=$REAL_USER
PAMName=login
PIDFile=/home/$REAL_USER/.vnc/%H%i.pid
ExecStartPre=/bin/sh -c '/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || :'
ExecStart=/usr/bin/vncserver :%i -geometry 1920x1080 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vncserver@1
    systemctl start vncserver@1 || true

    echo -e "${GREEN}  ✓ TigerVNC installed on port 5901${NC}"
    echo -e "${GREEN}    VNC Password: test1234${NC}"
fi

# ==========================================
# MYSQL/MARIADB SERVER
# ==========================================
if [ "$INSTALL_MYSQL" = true ]; then
    echo -e "${YELLOW}[5/8] Installing MySQL/MariaDB Server...${NC}"

    MYSQL_INSTALLED=false

    if [[ "$OS" == "ubuntu" ]]; then
        # Ubuntu has mysql-server
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-server && MYSQL_INSTALLED=true
    elif [[ "$OS" == "debian" ]]; then
        # Debian uses MariaDB (MySQL compatible)
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server && MYSQL_INSTALLED=true
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y -q mariadb-server && MYSQL_INSTALLED=true
    elif [[ "$OS" == "fedora" ]]; then
        dnf install -y -q mariadb-server && MYSQL_INSTALLED=true
    fi

    if [ "$MYSQL_INSTALLED" = true ]; then
        # Enable and start service (try different service names)
        systemctl enable mysql 2>/dev/null || systemctl enable mysqld 2>/dev/null || systemctl enable mariadb 2>/dev/null
        systemctl start mysql 2>/dev/null || systemctl start mysqld 2>/dev/null || systemctl start mariadb 2>/dev/null

        # Wait for service to be ready
        sleep 2

        # Create test user and database
        mysql -e "CREATE DATABASE IF NOT EXISTS testdb;" 2>/dev/null || true
        mysql -e "CREATE USER IF NOT EXISTS 'testuser'@'localhost' IDENTIFIED BY 'Test1234!';" 2>/dev/null || true
        mysql -e "CREATE USER IF NOT EXISTS 'testuser'@'%' IDENTIFIED BY 'Test1234!';" 2>/dev/null || true
        mysql -e "GRANT ALL PRIVILEGES ON testdb.* TO 'testuser'@'localhost';" 2>/dev/null || true
        mysql -e "GRANT ALL PRIVILEGES ON testdb.* TO 'testuser'@'%';" 2>/dev/null || true
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true

        # Allow remote connections (check multiple config locations)
        if [ -f /etc/mysql/mysql.conf.d/mysqld.cnf ]; then
            sed -i 's/bind-address.*=.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
        fi
        if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
            sed -i 's/bind-address.*=.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
        fi
        if [ -f /etc/my.cnf ]; then
            grep -q "bind-address" /etc/my.cnf || echo "bind-address = 0.0.0.0" >> /etc/my.cnf
        fi
        if [ -f /etc/my.cnf.d/mariadb-server.cnf ]; then
            sed -i 's/bind-address.*=.*/bind-address = 0.0.0.0/' /etc/my.cnf.d/mariadb-server.cnf
        fi

        # Restart service
        systemctl restart mysql 2>/dev/null || systemctl restart mysqld 2>/dev/null || systemctl restart mariadb 2>/dev/null

        echo -e "${GREEN}  ✓ MySQL/MariaDB installed on port 3306${NC}"
        echo -e "${GREEN}    Database: testdb${NC}"
        echo -e "${GREEN}    User: testuser / Test1234!${NC}"
    else
        echo -e "${RED}  ✗ Failed to install MySQL/MariaDB${NC}"
    fi
fi

# ==========================================
# POSTGRESQL SERVER
# ==========================================
if [ "$INSTALL_POSTGRES" = true ]; then
    echo -e "${YELLOW}[6/8] Installing PostgreSQL Server...${NC}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get install -y -qq postgresql postgresql-contrib
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y -q postgresql-server postgresql-contrib
        postgresql-setup --initdb 2>/dev/null || true
    elif [[ "$OS" == "fedora" ]]; then
        dnf install -y -q postgresql-server postgresql-contrib
        postgresql-setup --initdb 2>/dev/null || true
    fi

    systemctl enable postgresql
    systemctl start postgresql

    # Create test user and database
    sudo -u postgres psql -c "CREATE USER testuser WITH PASSWORD 'Test1234!';" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE DATABASE testdb OWNER testuser;" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE testdb TO testuser;" 2>/dev/null || true

    # Allow remote connections
    PG_HBA=$(sudo -u postgres psql -t -c "SHOW hba_file;" | tr -d ' ')
    PG_CONF=$(sudo -u postgres psql -t -c "SHOW config_file;" | tr -d ' ')

    # Add remote access rule
    grep -q "host.*all.*all.*0.0.0.0/0" $PG_HBA || echo "host    all    all    0.0.0.0/0    md5" >> $PG_HBA

    # Listen on all interfaces
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" $PG_CONF

    systemctl restart postgresql

    echo -e "${GREEN}  ✓ PostgreSQL installed on port 5432${NC}"
    echo -e "${GREEN}    Database: testdb${NC}"
    echo -e "${GREEN}    User: testuser / Test1234!${NC}"
fi

# ==========================================
# REDIS SERVER
# ==========================================
if [ "$INSTALL_REDIS" = true ]; then
    echo -e "${YELLOW}[7/8] Installing Redis Server...${NC}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get install -y -qq redis-server
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y -q redis
    elif [[ "$OS" == "fedora" ]]; then
        dnf install -y -q redis
    fi

    # Allow remote connections
    if [ -f /etc/redis/redis.conf ]; then
        sed -i 's/bind 127.0.0.1/bind 0.0.0.0/' /etc/redis/redis.conf
        sed -i 's/protected-mode yes/protected-mode no/' /etc/redis/redis.conf
    elif [ -f /etc/redis.conf ]; then
        sed -i 's/bind 127.0.0.1/bind 0.0.0.0/' /etc/redis.conf
        sed -i 's/protected-mode yes/protected-mode no/' /etc/redis.conf
    fi

    systemctl enable redis-server 2>/dev/null || systemctl enable redis 2>/dev/null
    systemctl restart redis-server 2>/dev/null || systemctl restart redis 2>/dev/null

    echo -e "${GREEN}  ✓ Redis installed on port 6379${NC}"
fi

# ==========================================
# MONGODB SERVER
# ==========================================
if [ "$INSTALL_MONGODB" = true ]; then
    echo -e "${YELLOW}[8/8] Installing MongoDB Server...${NC}"

    if [[ "$OS" == "ubuntu" ]]; then
        # Import MongoDB GPG key and add repo
        apt-get install -y -qq gnupg curl
        curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg 2>/dev/null || true
        echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-7.0.list
        apt-get update -qq
        apt-get install -y -qq mongodb-org || apt-get install -y -qq mongodb
    elif [[ "$OS" == "debian" ]]; then
        apt-get install -y -qq gnupg curl
        curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg 2>/dev/null || true
        echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" > /etc/apt/sources.list.d/mongodb-org-7.0.list
        apt-get update -qq
        apt-get install -y -qq mongodb-org || apt-get install -y -qq mongodb
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" || "$OS" == "fedora" ]]; then
        cat > /etc/yum.repos.d/mongodb-org-7.0.repo << 'EOF'
[mongodb-org-7.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/7.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-7.0.asc
EOF
        yum install -y -q mongodb-org || dnf install -y -q mongodb-org
    fi

    # Allow remote connections
    if [ -f /etc/mongod.conf ]; then
        sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
    fi

    systemctl enable mongod 2>/dev/null || true
    systemctl start mongod 2>/dev/null || true

    # Create test user
    sleep 2
    mongosh --quiet --eval '
        use testdb;
        db.createUser({
            user: "testuser",
            pwd: "Test1234!",
            roles: [{ role: "readWrite", db: "testdb" }]
        });
    ' 2>/dev/null || true

    echo -e "${GREEN}  ✓ MongoDB installed on port 27017${NC}"
    echo -e "${GREEN}    Database: testdb${NC}"
    echo -e "${GREEN}    User: testuser / Test1234!${NC}"
fi

# ==========================================
# FIREWALL CONFIGURATION
# ==========================================
echo -e "${YELLOW}Configuring firewall...${NC}"

# Check if firewalld is active
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=3389/tcp 2>/dev/null || true  # RDP
    firewall-cmd --permanent --add-port=5901/tcp 2>/dev/null || true  # VNC
    firewall-cmd --permanent --add-port=3306/tcp 2>/dev/null || true  # MySQL
    firewall-cmd --permanent --add-port=5432/tcp 2>/dev/null || true  # PostgreSQL
    firewall-cmd --permanent --add-port=6379/tcp 2>/dev/null || true  # Redis
    firewall-cmd --permanent --add-port=27017/tcp 2>/dev/null || true # MongoDB
    firewall-cmd --reload 2>/dev/null || true
    echo -e "${GREEN}  ✓ firewalld configured${NC}"
elif command -v ufw &> /dev/null; then
    ufw allow 3389/tcp 2>/dev/null || true   # RDP
    ufw allow 5901/tcp 2>/dev/null || true   # VNC
    ufw allow 3306/tcp 2>/dev/null || true   # MySQL
    ufw allow 5432/tcp 2>/dev/null || true   # PostgreSQL
    ufw allow 6379/tcp 2>/dev/null || true   # Redis
    ufw allow 27017/tcp 2>/dev/null || true  # MongoDB
    echo -e "${GREEN}  ✓ ufw configured${NC}"
else
    echo -e "${YELLOW}  ! No firewall detected (firewalld/ufw)${NC}"
fi

# ==========================================
# SUMMARY
# ==========================================
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Installation Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Services installed and running:${NC}"
echo ""

if [ "$INSTALL_RDP" = true ]; then
    echo -e "  ${GREEN}✓ RDP (xrdp)${NC}"
    echo -e "    Port: 3389"
    echo -e "    User: Your Linux user credentials"
    echo ""
fi

if [ "$INSTALL_VNC" = true ]; then
    echo -e "  ${GREEN}✓ VNC (TigerVNC)${NC}"
    echo -e "    Port: 5901"
    echo -e "    Password: test1234"
    echo ""
fi

if [ "$INSTALL_MYSQL" = true ]; then
    echo -e "  ${GREEN}✓ MySQL${NC}"
    echo -e "    Port: 3306"
    echo -e "    Database: testdb"
    echo -e "    User: testuser"
    echo -e "    Password: Test1234!"
    echo ""
fi

if [ "$INSTALL_POSTGRES" = true ]; then
    echo -e "  ${GREEN}✓ PostgreSQL${NC}"
    echo -e "    Port: 5432"
    echo -e "    Database: testdb"
    echo -e "    User: testuser"
    echo -e "    Password: Test1234!"
    echo ""
fi

if [ "$INSTALL_REDIS" = true ]; then
    echo -e "  ${GREEN}✓ Redis${NC}"
    echo -e "    Port: 6379"
    echo -e "    No authentication (test mode)"
    echo ""
fi

if [ "$INSTALL_MONGODB" = true ]; then
    echo -e "  ${GREEN}✓ MongoDB${NC}"
    echo -e "    Port: 27017"
    echo -e "    Database: testdb"
    echo -e "    User: testuser"
    echo -e "    Password: Test1234!"
    echo ""
fi

echo -e "${YELLOW}Note: Connect via IAP tunnel using Lightweight Cloud Connector${NC}"
echo -e "${YELLOW}      Make sure to allow IAP traffic in GCP firewall rules${NC}"
echo ""
echo -e "${BLUE}Test connection examples:${NC}"
echo "  mysql -h 127.0.0.1 -P <local_port> -u testuser -p testdb"
echo "  psql -h 127.0.0.1 -p <local_port> -U testuser -d testdb"
echo "  redis-cli -h 127.0.0.1 -p <local_port>"
echo "  mongosh mongodb://testuser:Test1234!@127.0.0.1:<local_port>/testdb"
echo ""
