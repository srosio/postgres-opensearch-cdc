#!/bin/bash

# =====================================================
# Setup CDC for m_savings_account_transaction
# =====================================================

set -e

# Load configuration
source "$(dirname "$0")/config.sh"

echo "=== Setting up CDC for Savings Transaction Table ==="
echo ""

# Connect to PostgreSQL and configure table
log_info "Configuring PostgreSQL table for CDC..."

docker exec -it $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DATABASE <<EOF
-- Enable REPLICA IDENTITY FULL
ALTER TABLE public.${TABLE_SAVINGS_TRANSACTION} REPLICA IDENTITY FULL;

-- Create publication
DO \$\$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '${PUBLICATION_SAVINGS}') THEN
        RAISE NOTICE 'Publication ${PUBLICATION_SAVINGS} already exists';
    ELSE
        CREATE PUBLICATION ${PUBLICATION_SAVINGS}
        FOR TABLE public.${TABLE_SAVINGS_TRANSACTION};
        RAISE NOTICE 'Created publication: ${PUBLICATION_SAVINGS}';
    END IF;
END \$\$;

-- Verify
\echo ''
\echo '=== Verification ==='
SELECT 'Row count' AS info, COUNT(*) FROM public.${TABLE_SAVINGS_TRANSACTION};
SELECT 'Publication' AS info, COUNT(*) AS count FROM pg_publication WHERE pubname = '${PUBLICATION_SAVINGS}';
EOF

echo ""
log_success "CDC configuration complete!"
echo ""
log_info "Next steps:"
echo "  1. Register Debezium: ./register-debezium-savings.sh"
echo "  2. Create indices: ./create-opensearch-indices.sh"
echo "  3. Start consumer: python3 kafka-to-opensearch.py"
echo ""
