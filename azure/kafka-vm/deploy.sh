#!/usr/bin/env bash
# Install Docker on the Kafka VM, copy the broker's compose file and the topic definitions,
# and start the broker.
#
#   ./azure/kafka-vm/deploy.sh <vm-fqdn> [ssh-user]
#
# On the first run it generates the SASL password and writes the VM's .env; on later runs the
# existing credentials are kept, so this is safe to re-run after changing topics.env.
set -euo pipefail
cd "$(dirname "$0")/../.."      # repository root

FQDN="${1:?usage: $0 <vm-fqdn> [ssh-user]}"
SSH_USER="${2:-azureuser}"
REMOTE="$SSH_USER@$FQDN"

echo "== installing Docker on $FQDN (skipped if already present)"
ssh "$REMOTE" 'command -v docker >/dev/null || (curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER)'

echo "== copying broker files"
ssh "$REMOTE" 'mkdir -p ~/kafka/kafka'
scp azure/kafka-vm/docker-compose.yml "$REMOTE:~/kafka/docker-compose.yml"
scp kafka/topics.env kafka/create-topics.sh "$REMOTE:~/kafka/kafka/"

echo "== writing .env (kept if it already exists)"
ssh "$REMOTE" "FQDN='$FQDN' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
cd ~/kafka
if [ ! -f .env ]; then
  PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  cat > .env <<EOF
KAFKA_PUBLIC_HOST=$FQDN
KAFKA_USERNAME=wonrich
KAFKA_PASSWORD=$PASSWORD
EOF
  chmod 600 .env
  echo "-- generated new credentials"
else
  echo "-- existing .env kept"
fi
REMOTE_SCRIPT

echo "== starting the broker"
ssh "$REMOTE" 'cd ~/kafka && sg docker -c "docker compose up -d" && sleep 40 && sg docker -c "docker compose ps" && sg docker -c "docker compose logs kafka-init"'

echo
echo "== credentials (share privately; they are not stored in this repository)"
ssh "$REMOTE" 'cd ~/kafka && grep -E "KAFKA_USERNAME|KAFKA_PASSWORD" .env'

cat <<DONE

== done. App Service settings for every service:

   Kafka__BootstrapServers = $FQDN:9094
   Kafka__SecurityProtocol = SaslPlaintext
   Kafka__SaslMechanism    = Plain
   Kafka__SaslUsername     = wonrich
   Kafka__SaslPassword     = <the password above>
DONE
