#!/bin/bash
set -e

# =====================================================
# PostgreSQL to OpenSearch CDC - Complete Setup
# =====================================================

# Configuration
POSTGRES_CONTAINER="postgres_container"
POSTGRES_USER="postgres"
POSTGRES_DB="instance_template"
OPENSEARCH_URL="http://localhost:9200"
DEBEZIUM_URL="http://localhost:8083"

# Tables to sync
TABLES=("card" "authorize_transaction" "card_authorization")
PUBLICATION_NAME="card_tables_publication"
SLOT_NAME="card_tables_slot"
CONNECTOR_NAME="card-tables-source"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC}  $1"; }
log_success() { echo -e "${GREEN}✓${NC}  $1"; }
log_error() { echo -e "${RED}✗${NC}  $1"; exit 1; }

echo "==================================================================="
echo "  PostgreSQL → OpenSearch CDC Setup"
echo "==================================================================="
echo ""

# =====================================================
# Step 1: Start CDC Services
# =====================================================
echo "Step 1: Starting CDC Services"
echo "-------------------------------------------------------------------"

if ! docker ps | grep -q "kafka.*healthy"; then
    log_info "Starting CDC services (Kafka, Zookeeper, Debezium)..."
    docker-compose -f docker-compose-cdc-only.yml up -d
    log_info "Waiting 30 seconds for services to initialize..."
    sleep 30
fi

log_success "CDC services running"
echo ""

# =====================================================
# Step 2: Configure PostgreSQL
# =====================================================
echo "Step 2: Configuring PostgreSQL Tables"
echo "-------------------------------------------------------------------"

log_info "Setting REPLICA IDENTITY FULL on tables..."

for table in "${TABLES[@]}"; do
    docker exec $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB \
        -c "ALTER TABLE public.$table REPLICA IDENTITY FULL;" 2>/dev/null || true
    log_success "Configured: $table"
done

log_info "Creating publication..."
docker exec $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB <<EOF
DROP PUBLICATION IF EXISTS $PUBLICATION_NAME;
CREATE PUBLICATION $PUBLICATION_NAME FOR TABLE public.${TABLES[0]}, public.${TABLES[1]}, public.${TABLES[2]};
EOF

log_success "Publication created: $PUBLICATION_NAME"
echo ""

# =====================================================
# Step 3: Register Debezium Connector
# =====================================================
echo "Step 3: Registering Debezium Connector"
echo "-------------------------------------------------------------------"

# Delete existing connector if exists
curl -s -X DELETE $DEBEZIUM_URL/connectors/$CONNECTOR_NAME 2>/dev/null || true
sleep 2

log_info "Creating Debezium connector..."

curl -s -X POST $DEBEZIUM_URL/connectors -H 'Content-Type: application/json' -d "{
  \"name\": \"$CONNECTOR_NAME\",
  \"config\": {
    \"connector.class\": \"io.debezium.connector.postgresql.PostgresConnector\",
    \"database.hostname\": \"host.docker.internal\",
    \"database.port\": \"5432\",
    \"database.user\": \"$POSTGRES_USER\",
    \"database.password\": \"root\",
    \"database.dbname\": \"$POSTGRES_DB\",
    \"database.server.name\": \"postgres\",
    \"topic.prefix\": \"postgres\",
    \"table.include.list\": \"public.card,public.authorize_transaction,public.card_authorization\",
    \"publication.name\": \"$PUBLICATION_NAME\",
    \"slot.name\": \"$SLOT_NAME\",
    \"plugin.name\": \"pgoutput\",
    \"snapshot.mode\": \"initial\",
    \"key.converter\": \"org.apache.kafka.connect.json.JsonConverter\",
    \"key.converter.schemas.enable\": \"false\",
    \"value.converter\": \"org.apache.kafka.connect.json.JsonConverter\",
    \"value.converter.schemas.enable\": \"false\"
  }
}" > /dev/null

sleep 5

STATUS=$(curl -s $DEBEZIUM_URL/connectors/$CONNECTOR_NAME/status | jq -r '.connector.state')
if [ "$STATUS" = "RUNNING" ]; then
    log_success "Debezium connector: $STATUS"
else
    log_error "Debezium connector failed: $STATUS"
fi

echo ""

# =====================================================
# Step 4: Create OpenSearch Indices
# =====================================================
echo "Step 4: Creating OpenSearch Indices"
echo "-------------------------------------------------------------------"

create_index() {
    local index_name=$1
    curl -s -X PUT "$OPENSEARCH_URL/$index_name" -H 'Content-Type: application/json' -d '{
      "settings": {"number_of_shards": 1, "number_of_replicas": 0},
      "mappings": {
        "properties": {
          "id": {"type": "long"},
          "created_at": {"type": "date"},
          "updated_at": {"type": "date"}
        }
      }
    }' > /dev/null
    log_success "Created index: $index_name"
}

for table in "${TABLES[@]}"; do
    create_index "$table"
done

echo ""

# =====================================================
# Step 5: Verification
# =====================================================
echo "Step 5: Verification"
echo "-------------------------------------------------------------------"

log_info "Kafka topics:"
docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list | grep postgres.public | sed 's/^/  - /'

echo ""
log_info "OpenSearch indices:"
curl -s "$OPENSEARCH_URL/_cat/indices?v" | grep -E "(card|authorize_transaction)" | awk '{print "  - " $3 " (" $7 " docs)"}'

echo ""
log_info "PostgreSQL record counts:"
for table in "${TABLES[@]}"; do
    count=$(docker exec $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "SELECT COUNT(*) FROM public.$table;" | xargs)
    echo "  - $table: $count"
done

echo ""
echo "==================================================================="
log_success "Setup Complete!"
echo "==================================================================="
echo ""
echo "Next steps:"
echo "  1. Start consumer:             python3 consumer.py"
echo "  2. Monitor Kafka UI:           http://localhost:8080"
echo "  3. View OpenSearch Dashboards: http://localhost:5601"
echo "  4. Test pipeline:              ./test.sh"
echo ""
