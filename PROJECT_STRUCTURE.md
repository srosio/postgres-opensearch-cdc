# Project Structure

## Overview

This project has been organized with centralized configuration and consolidated documentation for easy maintenance.

## Configuration

**`config.sh`** - Single source of truth for all configuration
- PostgreSQL settings
- OpenSearch settings
- Kafka settings
- Table names and publications
- Reusable helper functions

All scripts source this file automatically.

## Documentation

**`README.md`** - Complete project documentation (18KB)
- Architecture overview
- Quick start guide
- Detailed setup instructions
- Usage examples
- Monitoring guide
- Troubleshooting
- Advanced topics

**`CLAUDE.md`** - Claude Code guidance (9.5KB)
- Project overview
- Common commands
- Architecture notes
- Key file descriptions
- Development notes

## Setup Scripts

All scripts use centralized config from `config.sh`

**Database Setup:**
- `setup-savings-table.sh` - Configure m_savings_account_transaction
- `setup-card-tables.sh` - Configure card, authorize_transaction, card_authorization

**Debezium Connectors:**
- `register-debezium-savings.sh` - Register savings transaction connector
- `register-debezium-cards.sh` - Register card tables connector

**OpenSearch:**
- `create-opensearch-indices.sh` - Create all indices with mappings

**Testing:**
- `quick-test.sh` - Automated health check
- `verify-instance-template-cdc.sh` - Detailed verification

## Python Consumers

**`kafka-to-opensearch.py`** - Single-table consumer
- For m_savings_account_transaction only
- Simpler, focused implementation

**`kafka-to-opensearch-multi.py`** - Multi-table consumer (recommended)
- Handles all tables simultaneously
- Topic-to-index mapping
- Progress tracking with emojis
- Statistics reporting

## Infrastructure

**`docker-compose-cdc-only.yml`** - CDC services
- Kafka
- Zookeeper
- Debezium Connect
- Kafka UI
- Kafka Connect OpenSearch

## Workflow

### For Savings Transactions Only

```bash
./setup-savings-table.sh
./register-debezium-savings.sh
./create-opensearch-indices.sh
python3 kafka-to-opensearch.py
```

### For Card Tables (includes existing data)

```bash
./setup-card-tables.sh
./register-debezium-cards.sh
./create-opensearch-indices.sh
python3 kafka-to-opensearch-multi.py
```

### For All Tables

```bash
# Setup both
./setup-savings-table.sh
./setup-card-tables.sh

# Register both connectors
./register-debezium-savings.sh
./register-debezium-cards.sh

# Create all indices
./create-opensearch-indices.sh

# Use multi-table consumer
python3 kafka-to-opensearch-multi.py
```

## File Summary

| File | Size | Purpose |
|------|------|---------|
| config.sh | 3.5K | Centralized configuration |
| README.md | 18K | Complete documentation |
| CLAUDE.md | 9.5K | Claude Code guidance |
| setup-savings-table.sh | 1.5K | Setup savings table |
| setup-card-tables.sh | 2.0K | Setup card tables |
| register-debezium-savings.sh | 2.3K | Register savings connector |
| register-debezium-cards.sh | 2.6K | Register cards connector |
| create-opensearch-indices.sh | 6.2K | Create all indices |
| kafka-to-opensearch.py | 2.6K | Single-table consumer |
| kafka-to-opensearch-multi.py | 5.8K | Multi-table consumer |
| quick-test.sh | 4.8K | Health check |
| docker-compose-cdc-only.yml | 4.9K | CDC services |

**Total:** 13 files, ~68KB

## Key Benefits of This Structure

1. **Single Configuration Source** - Edit `config.sh` once, all scripts update
2. **Consolidated Documentation** - One README with everything
3. **Modular Scripts** - Each script does one thing well
4. **Reusable Functions** - Helper functions in config.sh
5. **Clear Workflow** - Obvious progression from setup to running
6. **Easy Maintenance** - Update one place, not scattered files
