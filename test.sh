#!/bin/bash

# Quick test script for CDC pipeline

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "🧪 CDC Pipeline Quick Test"
echo ""

# Test 1: Services running
echo "1️⃣  Services..."
docker ps --format "   {{.Names}}: {{.Status}}" | grep -E "(kafka|debezium|postgres|ops)" | head -4

# Test 2: Debezium connector
echo ""
echo "2️⃣  Debezium Connector..."
STATUS=$(curl -s http://localhost:8083/connectors/card-tables-source/status 2>/dev/null | jq -r '.connector.state' 2>/dev/null)
if [ "$STATUS" = "RUNNING" ]; then
    echo -e "   ${GREEN}✓${NC} Connector: $STATUS"
else
    echo -e "   ${RED}✗${NC} Connector: $STATUS"
fi

# Test 3: Data counts
echo ""
echo "3️⃣  Data Counts..."
for table in card authorize_transaction card_authorization; do
    pg_count=$(docker exec postgres_container psql -U postgres -d instance_template -t -c "SELECT COUNT(*) FROM $table;" 2>/dev/null | xargs)
    os_count=$(curl -s "http://localhost:9200/$table/_count" 2>/dev/null | jq -r '.count' 2>/dev/null)

    if [ "$pg_count" = "$os_count" ]; then
        echo -e "   ${GREEN}✓${NC} $table: PG=$pg_count OS=$os_count"
    else
        echo -e "   ${RED}✗${NC} $table: PG=$pg_count OS=$os_count (mismatch)"
    fi
done

echo ""
echo "✅ Test complete!"
echo ""
echo "Monitor:"
echo "  - Kafka UI: http://localhost:8080"
echo "  - OpenSearch: http://localhost:9200/_cat/indices?v"
echo ""
