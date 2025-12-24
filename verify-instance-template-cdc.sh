#!/bin/bash

# =====================================================
# Verify CDC Pipeline for instance_template
# =====================================================

set -e

POSTGRES_CONTAINER="postgres_container"
POSTGRES_USER="postgres"
DATABASE_NAME="instance_template"
KAFKA_CONTAINER="kafka"
OPENSEARCH_HOST="localhost:9200"
DEBEZIUM_HOST="localhost:8083"
KAFKA_CONNECT_HOST="localhost:8084"

echo "=== Verifying CDC Pipeline for instance_template ==="
echo ""

# Check Debezium connector
echo "1. Checking Debezium Source Connector..."
DEBEZIUM_STATUS=$(curl -s http://$DEBEZIUM_HOST/connectors/instance-template-source/status | jq -r '.connector.state')
echo "   Status: $DEBEZIUM_STATUS"

if [ "$DEBEZIUM_STATUS" != "RUNNING" ]; then
    echo "   ❌ Debezium connector is not running!"
    curl -s http://$DEBEZIUM_HOST/connectors/instance-template-source/status | jq .
    exit 1
fi
echo "   ✓ Debezium connector is running"
echo ""

# Check OpenSearch sink connector
echo "2. Checking OpenSearch Sink Connector..."
SINK_STATUS=$(curl -s http://$KAFKA_CONNECT_HOST/connectors/instance-template-opensearch-sink/status | jq -r '.connector.state')
echo "   Status: $SINK_STATUS"

if [ "$SINK_STATUS" != "RUNNING" ]; then
    echo "   ❌ OpenSearch sink connector is not running!"
    curl -s http://$KAFKA_CONNECT_HOST/connectors/instance-template-opensearch-sink/status | jq .
    exit 1
fi
echo "   ✓ OpenSearch sink connector is running"
echo ""

# Check Kafka topics
echo "3. Checking Kafka Topics..."
if docker exec $KAFKA_CONTAINER kafka-topics --bootstrap-server localhost:9092 --list | grep -q "m_savings_account_transaction"; then
    echo "   ✓ Topic 'm_savings_account_transaction' exists"
else
    echo "   ❌ Topic 'm_savings_account_transaction' not found!"
    exit 1
fi
echo ""

# Check PostgreSQL database
echo "4. Checking PostgreSQL Database..."
PG_COUNT=$(docker exec $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $DATABASE_NAME -t -c "SELECT COUNT(*) FROM public.m_savings_account_transaction;")
echo "   Records in PostgreSQL: $(echo $PG_COUNT | xargs)"
echo ""

# Check OpenSearch index
echo "5. Checking OpenSearch Index..."
if curl -s "http://$OPENSEARCH_HOST/m_savings_account_transaction/_count" | grep -q "count"; then
    OS_COUNT=$(curl -s "http://$OPENSEARCH_HOST/m_savings_account_transaction/_count" | jq -r '.count')
    echo "   Records in OpenSearch: $OS_COUNT"

    if [ "$OS_COUNT" -gt 0 ]; then
        echo "   ✓ Data has been synced to OpenSearch!"
    else
        echo "   ⚠️  OpenSearch index exists but has no data yet (snapshot may still be in progress)"
    fi
else
    echo "   ❌ OpenSearch index not found or not accessible!"
    exit 1
fi
echo ""

# Show sample Kafka message
echo "6. Sample Kafka Message (if available)..."
docker exec $KAFKA_CONTAINER kafka-console-consumer \
    --bootstrap-server localhost:9092 \
    --topic m_savings_account_transaction \
    --from-beginning \
    --max-messages 1 \
    --timeout-ms 5000 2>/dev/null || echo "   (No messages available yet or timeout reached)"

echo ""
echo "=== Verification Complete ==="
echo ""
echo "Pipeline Status:"
echo "  ✓ Debezium Connector: $DEBEZIUM_STATUS"
echo "  ✓ OpenSearch Sink: $SINK_STATUS"
echo "  ✓ PostgreSQL Records: $(echo $PG_COUNT | xargs)"
echo "  ✓ OpenSearch Records: ${OS_COUNT:-0}"
echo ""
echo "Web UIs:"
echo "  - Kafka UI: http://localhost:8080"
echo "  - OpenSearch Dashboards: http://localhost:5601"
echo ""
echo "To test CDC, insert/update data in PostgreSQL:"
echo "  docker exec -it $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $DATABASE_NAME"
echo ""
