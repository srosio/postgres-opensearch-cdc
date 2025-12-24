#!/bin/bash

# =====================================================
# Setup CDC for Card-related Tables
# =====================================================

set -e

# Load configuration
source "$(dirname "$0")/config.sh"

echo "=== Setting up CDC for Card-related Tables ==="
echo ""

log_info "Tables: ${TABLE_CARD}, ${TABLE_AUTHORIZE_TX}, ${TABLE_CARD_AUTH}"
echo ""

# Connect to PostgreSQL and configure tables
log_info "Configuring PostgreSQL tables for CDC..."

docker exec -it $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DATABASE <<EOF
-- Enable REPLICA IDENTITY FULL for all tables
ALTER TABLE public.${TABLE_CARD} REPLICA IDENTITY FULL;
ALTER TABLE public.${TABLE_AUTHORIZE_TX} REPLICA IDENTITY FULL;
ALTER TABLE public.${TABLE_CARD_AUTH} REPLICA IDENTITY FULL;

-- Create publication
DO \$\$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '${PUBLICATION_CARDS}') THEN
        RAISE NOTICE 'Publication ${PUBLICATION_CARDS} already exists';
    ELSE
        CREATE PUBLICATION ${PUBLICATION_CARDS} FOR TABLE
            public.${TABLE_CARD},
            public.${TABLE_AUTHORIZE_TX},
            public.${TABLE_CARD_AUTH};
        RAISE NOTICE 'Created publication: ${PUBLICATION_CARDS}';
    END IF;
END \$\$;

-- Verify
\echo ''
\echo '=== Verification ==='
\echo ''
\echo 'Row Counts:'
SELECT '${TABLE_CARD}' AS table_name, COUNT(*) AS rows FROM public.${TABLE_CARD}
UNION ALL
SELECT '${TABLE_AUTHORIZE_TX}', COUNT(*) FROM public.${TABLE_AUTHORIZE_TX}
UNION ALL
SELECT '${TABLE_CARD_AUTH}', COUNT(*) FROM public.${TABLE_CARD_AUTH};

\echo ''
\echo 'Published Tables:'
SELECT tablename FROM pg_publication_tables
WHERE pubname = '${PUBLICATION_CARDS}'
ORDER BY tablename;
EOF

echo ""
log_success "CDC configuration complete!"
echo ""
log_info "Next steps:"
echo "  1. Register Debezium: ./register-debezium-cards.sh"
echo "  2. Create indices: ./create-opensearch-indices.sh"
echo "  3. Start consumer: python3 kafka-to-opensearch-multi.py"
echo ""
