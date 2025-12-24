#!/bin/bash

# =======================================================
# Quick CDC Pipeline Test
# =======================================================

set -e

echo "🧪 CDC Pipeline Quick Test"
echo "=========================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test 1: Check services
echo "1️⃣  Checking CDC services..."
if docker ps | grep -q "debezium.*healthy"; then
    echo -e "   ${GREEN}✓${NC} Debezium is running"
else
    echo -e "   ${RED}✗${NC} Debezium is not healthy"
    exit 1
fi

if docker ps | grep -q "kafka.*healthy"; then
    echo -e "   ${GREEN}✓${NC} Kafka is running"
else
    echo -e "   ${RED}✗${NC} Kafka is not healthy"
    exit 1
fi

if curl -s http://localhost:8084/connectors > /dev/null 2>&1; then
    echo -e "   ${GREEN}✓${NC} Kafka Connect is running"
else
    echo -e "   ${YELLOW}⏳${NC} Kafka Connect is still starting..."
fi

echo ""

# Test 2: Check PostgreSQL configuration
echo "2️⃣  Checking PostgreSQL configuration..."
WAL_LEVEL=$(docker exec postgres_container psql -U postgres -d instance_template -t -c "SHOW wal_level;" | xargs)
if [ "$WAL_LEVEL" = "logical" ]; then
    echo -e "   ${GREEN}✓${NC} wal_level is set to logical"
else
    echo -e "   ${RED}✗${NC} wal_level is '$WAL_LEVEL' but needs to be 'logical'"
    echo "   Please configure PostgreSQL for CDC first (see SETUP_STATUS.md)"
    exit 1
fi

# Check publication exists
PUB_COUNT=$(docker exec postgres_container psql -U postgres -d instance_template -t -c \
  "SELECT COUNT(*) FROM pg_publication WHERE pubname = 'instance_template_publication';" | xargs)
if [ "$PUB_COUNT" = "1" ]; then
    echo -e "   ${GREEN}✓${NC} PostgreSQL publication exists"
else
    echo -e "   ${YELLOW}⚠${NC}  Publication not found. Run: ./setup-instance-template-cdc.sh"
fi

echo ""

# Test 3: Check connectors
echo "3️⃣  Checking Debezium connector..."
if curl -s http://localhost:8083/connectors | grep -q "instance-template-source"; then
    STATUS=$(curl -s http://localhost:8083/connectors/instance-template-source/status | jq -r '.connector.state')
    if [ "$STATUS" = "RUNNING" ]; then
        echo -e "   ${GREEN}✓${NC} Debezium connector is RUNNING"
    else
        echo -e "   ${RED}✗${NC} Debezium connector status: $STATUS"
    fi
else
    echo -e "   ${YELLOW}⚠${NC}  Debezium connector not registered. Run: ./register-instance-template-debezium.sh"
fi

echo ""

echo "4️⃣  Checking OpenSearch sink connector..."
if curl -s http://localhost:8084/connectors 2>/dev/null | grep -q "instance-template-opensearch-sink"; then
    STATUS=$(curl -s http://localhost:8084/connectors/instance-template-opensearch-sink/status | jq -r '.connector.state')
    if [ "$STATUS" = "RUNNING" ]; then
        echo -e "   ${GREEN}✓${NC} OpenSearch sink connector is RUNNING"
    else
        echo -e "   ${RED}✗${NC} OpenSearch sink connector status: $STATUS"
    fi
else
    echo -e "   ${YELLOW}⚠${NC}  OpenSearch sink connector not registered. Run: ./register-instance-template-opensearch.sh"
fi

echo ""

# Test 4: Check Kafka topic
echo "5️⃣  Checking Kafka topic..."
if docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null | grep -q "m_savings_account_transaction"; then
    echo -e "   ${GREEN}✓${NC} Kafka topic 'm_savings_account_transaction' exists"
else
    echo -e "   ${RED}✗${NC} Kafka topic not found"
fi

echo ""

# Test 5: Check OpenSearch index
echo "6️⃣  Checking OpenSearch index..."
if curl -s 'http://localhost:9200/_cat/indices' | grep -q "m_savings_account_transaction"; then
    echo -e "   ${GREEN}✓${NC} OpenSearch index 'm_savings_account_transaction' exists"

    # Get counts
    PG_COUNT=$(docker exec postgres_container psql -U postgres -d instance_template -t -c \
      "SELECT COUNT(*) FROM public.m_savings_account_transaction;" | xargs)
    OS_COUNT=$(curl -s 'http://localhost:9200/m_savings_account_transaction/_count' | jq -r '.count')

    echo "   📊 PostgreSQL records: $PG_COUNT"
    echo "   📊 OpenSearch documents: $OS_COUNT"

    if [ "$PG_COUNT" = "$OS_COUNT" ]; then
        echo -e "   ${GREEN}✓${NC} Counts match!"
    else
        DIFF=$((PG_COUNT - OS_COUNT))
        echo -e "   ${YELLOW}⚠${NC}  Difference: $DIFF (may be syncing...)"
    fi
else
    echo -e "   ${YELLOW}⚠${NC}  OpenSearch index not found yet"
fi

echo ""
echo "=========================="
echo "🎯 Quick Test Summary"
echo "=========================="
echo ""
echo "For detailed testing, see: TESTING_GUIDE.md"
echo ""
echo "Next steps:"
echo "  1. Insert test data: docker exec -it postgres_container psql -U postgres -d instance_template"
echo "  2. Monitor Kafka UI: http://localhost:8080"
echo "  3. Query OpenSearch: curl 'http://localhost:9200/m_savings_account_transaction/_search?pretty'"
echo ""
