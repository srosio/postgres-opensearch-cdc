#!/bin/bash

# =====================================================
# Register Debezium Connector for Savings Transactions
# =====================================================

set -e

# Load configuration
source "$(dirname "$0")/config.sh"

echo "=== Registering Debezium Connector: ${CONNECTOR_SAVINGS} ==="
echo ""

# Check if connector exists
if curl -s ${DEBEZIUM_URL}/connectors | grep -q "\"${CONNECTOR_SAVINGS}\""; then
    log_warning "Connector '${CONNECTOR_SAVINGS}' already exists"
    echo ""
    curl -s ${DEBEZIUM_URL}/connectors/${CONNECTOR_SAVINGS}/status | jq
    echo ""
    read -p "Delete and recreate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deleting existing connector..."
        curl -X DELETE ${DEBEZIUM_URL}/connectors/${CONNECTOR_SAVINGS}
        sleep 3
    else
        exit 0
    fi
fi

log_info "Creating Debezium connector..."

curl -X POST ${DEBEZIUM_URL}/connectors \
  -H 'Content-Type: application/json' \
  -d "{
    \"name\": \"${CONNECTOR_SAVINGS}\",
    \"config\": {
      \"connector.class\": \"io.debezium.connector.postgresql.PostgresConnector\",
      \"database.hostname\": \"${POSTGRES_HOST}\",
      \"database.port\": \"${POSTGRES_PORT}\",
      \"database.user\": \"${POSTGRES_USER}\",
      \"database.password\": \"${POSTGRES_PASSWORD}\",
      \"database.dbname\": \"${POSTGRES_DATABASE}\",
      \"database.server.name\": \"${TOPIC_PREFIX}\",
      \"table.include.list\": \"public.${TABLE_SAVINGS_TRANSACTION}\",
      \"publication.name\": \"${PUBLICATION_SAVINGS}\",
      \"slot.name\": \"${SLOT_SAVINGS}\",
      \"plugin.name\": \"pgoutput\",
      \"snapshot.mode\": \"initial\",
      \"key.converter\": \"org.apache.kafka.connect.json.JsonConverter\",
      \"key.converter.schemas.enable\": \"false\",
      \"value.converter\": \"org.apache.kafka.connect.json.JsonConverter\",
      \"value.converter.schemas.enable\": \"false\"
    }
  }"

echo ""
echo ""

wait_for_service "Debezium connector" \
  "curl -s ${DEBEZIUM_URL}/connectors/${CONNECTOR_SAVINGS}/status | jq -e '.connector.state == \"RUNNING\"'" \
  15

echo ""
log_info "Connector Status:"
curl -s ${DEBEZIUM_URL}/connectors/${CONNECTOR_SAVINGS}/status | jq

echo ""
log_success "Debezium connector registered!"
echo ""
log_info "Expected Kafka topic: ${TABLE_SAVINGS_TRANSACTION}"
log_info "Monitor at: ${KAFKA_UI_URL}"
echo ""
