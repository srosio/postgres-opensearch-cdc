# PostgreSQL to OpenSearch CDC

Real-time Change Data Capture pipeline: PostgreSQL → Debezium → Kafka → OpenSearch

## Quick Start

```bash
# 1. Setup everything (one command)
./setup.sh

# 2. Start syncing data
python3 consumer.py

# 3. Test it works
./test.sh
```

## What It Does

- Captures **existing data** from PostgreSQL tables (snapshot)
- Streams **real-time changes** (INSERT/UPDATE/DELETE)
- Syncs everything to OpenSearch for search/analytics

## Tables Synced

- `card`
- `authorize_transaction`
- `card_authorization`

## How It Works

```
PostgreSQL (wal_level=logical)
    ↓
Debezium (captures changes)
    ↓
Kafka (message queue)
    ↓
Python Consumer
    ↓
OpenSearch (indexed data)
```

## Prerequisites

- Docker & Docker Compose
- PostgreSQL container: `postgres_container`
- OpenSearch container: `ops`
- Python 3 with: `pip3 install kafka-python requests`

## Configuration

Edit variables in `setup.sh`:
```bash
POSTGRES_CONTAINER="postgres_container"
POSTGRES_DB="instance_template"
OPENSEARCH_URL="http://localhost:9200"
```

## Services

| Service | Port | URL |
|---------|------|-----|
| Kafka | 29092 | - |
| Kafka UI | 8080 | http://localhost:8080 |
| Debezium | 8083 | http://localhost:8083 |
| OpenSearch | 9200 | http://localhost:9200 |
| OpenSearch Dashboards | 5601 | http://localhost:5601 |

## Testing Changes

```bash
# Insert test record
docker exec -it postgres_container psql -U postgres -d instance_template
INSERT INTO card (version, product_id, primary_account_number, status,
    fulfillment_status, card_type, card_network, physical_card_activated,
    pos_payment_enabled, sub_status)
VALUES (1, 1, 'TEST123', 'ACTIVE', 'PRODUCED', 'DEBIT', 'VISA', false, true, 'NONE');

# Consumer will show:
# ➕ [1] card:123 (create)

# Verify in OpenSearch
curl 'http://localhost:9200/card/_doc/123'

# Or view in OpenSearch Dashboards
# http://localhost:5601 → Dev Tools → Run queries
```

## Using OpenSearch Dashboards

**Access:** http://localhost:5601

**Features:**
- **Discover:** Search and filter your data
- **Dashboard:** Create visualizations and dashboards
- **Dev Tools:** Run queries and manage indices

**Quick Start:**
1. Open http://localhost:5601
2. Go to "Management" → "Index Patterns"
3. Create index pattern: `card*` or `*` for all indices
4. Go to "Discover" to explore your data
5. Create visualizations in "Dashboard"

## Troubleshooting

**Check connector status:**
```bash
curl http://localhost:8083/connectors/card-tables-source/status | jq
```

**View Kafka messages:**
```bash
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.card \
  --from-beginning --max-messages 5
```

**Check counts:**
```bash
# PostgreSQL
docker exec postgres_container psql -U postgres -d instance_template \
  -c "SELECT COUNT(*) FROM card;"

# OpenSearch
curl 'http://localhost:9200/card/_count'
```

**Restart everything:**
```bash
docker-compose -f docker-compose-cdc-only.yml restart
./setup.sh
```

## Cleanup

```bash
# Stop services
docker-compose -f docker-compose-cdc-only.yml down

# Remove connector & data
curl -X DELETE http://localhost:8083/connectors/card-tables-source
docker exec postgres_container psql -U postgres -d instance_template \
  -c "DROP PUBLICATION IF EXISTS card_tables_publication;"
curl -X DELETE 'http://localhost:9200/card'
```

## Files

- `setup.sh` - Complete setup (one command)
- `consumer.py` - Kafka to OpenSearch sync
- `test.sh` - Quick health check
- `docker-compose-cdc-only.yml` - CDC services

That's it! 🎉
