#!/bin/bash

# -----------------------------
# install_patroni_node.sh
# Usage: ./install_patroni_node.sh <NODE_IP> <ROLE>
# ROLE = leader | replica | replica-lb
# -----------------------------

set -e

# Arguments
NODE_IP="$1"
ROLE="$2"
NODE_NAME=$(hostname)
PG_VERSION=16
PG_DATA_DIR="/var/lib/postgresql/$PG_VERSION/main"

# Configuration du cluster
ETCD_CLUSTER="pg-node1=http://192.168.1.10:2380,pg-node2=http://192.168.1.11:2380,pg-node3=http://192.168.1.12:2380"
ETCD_ENDPOINTS="192.168.1.10:2379,192.168.1.11:2379,192.168.1.12:2379"
PG_NODES=("192.168.1.10" "192.168.1.11" "192.168.1.12")

# Vérification
if [[ -z "$NODE_IP" || -z "$ROLE" ]]; then
  echo "Usage: $0 <NODE_IP> <leader|replica|replica-lb>"
  exit 1
fi

echo "🔧 Initialisation de $NODE_NAME [$ROLE] avec IP $NODE_IP..."

# 1. Installation des paquets
sudo apt update
sudo apt install -y postgresql-$PG_VERSION postgresql-contrib-$PG_VERSION \
  python3-pip python3-psycopg2 \
  etcd patroni haproxy vim net-tools

# 2. Configuration etcd
sudo tee /etc/default/etcd > /dev/null <<EOF
ETCD_NAME=$NODE_NAME
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_PEER_URLS="http://$NODE_IP:2380"
ETCD_LISTEN_CLIENT_URLS="http://$NODE_IP:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://$NODE_IP:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://$NODE_IP:2379"
ETCD_INITIAL_CLUSTER="$ETCD_CLUSTER"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="patroni-cluster"
EOF

sudo systemctl enable etcd
sudo systemctl restart etcd

# 3. Configuration PostgreSQL
echo "🔧 Configuration PostgreSQL..."
sudo systemctl stop postgresql || true

sudo -u postgres psql -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicatorpass';" || true

sudo tee /etc/postgresql/$PG_VERSION/main/pg_hba.conf > /dev/null <<EOF
host    replication     replicator      192.168.1.0/24     md5
host    all             all             0.0.0.0/0          md5
EOF

sudo tee -a /etc/postgresql/$PG_VERSION/main/postgresql.conf > /dev/null <<EOF
listen_addresses = '*'
wal_level = replica
hot_standby = on
EOF

# 4. Configuration Patroni
echo "🛠️ Génération de /etc/patroni.yml..."
sudo tee /etc/patroni.yml > /dev/null <<EOF
scope: pgcluster
namespace: /db/
name: $NODE_NAME

restapi:
  listen: $NODE_IP:8008
  connect_address: $NODE_IP:8008

etcd:
  host: $ETCD_ENDPOINTS

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
  initdb:
    - encoding: UTF8
    - data-checksums
  users:
    postgres:
      password: postgres
      options:
        - superuser
        - createrole

postgresql:
  listen: $NODE_IP:5432
  connect_address: $NODE_IP:5432
  data_dir: $PG_DATA_DIR
  bin_dir: /usr/lib/postgresql/$PG_VERSION/bin
  authentication:
    replication:
      username: replicator
      password: replicatorpass
    superuser:
      username: postgres
      password: postgres
  parameters:
    max_connections: 100
    wal_level: replica
    hot_standby: "on"
EOF

# 5. Lancement Patroni
echo "🚀 Lancement Patroni..."
sudo pkill patroni || true
nohup sudo patroni /etc/patroni.yml > /var/log/patroni.log 2>&1 &

# 6. Si nœud avec rôle 'replica-lb', configurer HAProxy
if [[ "$ROLE" == "replica-lb" ]]; then
  echo "🧩 Configuration HAProxy en cours..."

  sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<EOF
global
    daemon
    maxconn 256

defaults
    mode tcp
    timeout connect 10s
    timeout client  30s
    timeout server  30s

frontend postgresql_front
    bind *:5000
    default_backend postgresql_back

backend postgresql_back
    option httpchk GET /master
EOF

  for IP in "${PG_NODES[@]}"; do
    echo "    server node-$IP $IP:5432 check port 8008" | sudo tee -a /etc/haproxy/haproxy.cfg > /dev/null
  done

  echo "🔄 Redémarrage de HAProxy..."
  sudo systemctl enable haproxy
  sudo systemctl restart haproxy
  echo "✅ HAProxy écoute sur le port 5000"
fi

echo "✅ Installation complète pour $NODE_NAME ($ROLE) à l'adresse $NODE_IP"
