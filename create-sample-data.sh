#!/bin/bash

echo "Creating sample data..."

docker exec postgres_container psql -U postgres -d instance_template <<'EOF'

-- Create card product
INSERT INTO card_product (id, version, name, active, bin, card_type, card_network, currency_code, currency_digits)
VALUES (1, 1, 'Standard Debit Card', true, '411111', 'DEBIT', 'VISA', 'USD', 2)
ON CONFLICT (id) DO NOTHING;

-- Create sample cards
INSERT INTO card (version, product_id, primary_account_number, status, fulfillment_status, card_type, card_network, physical_card_activated, pos_payment_enabled, sub_status)
VALUES
(1, 1, '4111111111111111', 'ACTIVE', 'PRODUCED', 'DEBIT', 'VISA', true, true, 'NONE'),
(1, 1, '4111111111111112', 'ACTIVE', 'PRODUCED', 'DEBIT', 'VISA', true, true, 'NONE'),
(1, 1, '4111111111111113', 'BLOCKED', 'PRODUCED', 'DEBIT', 'MASTERCARD', true, false, 'NONE'),
(1, 1, '4111111111111114', 'ACTIVE', 'PRODUCED', 'CREDIT', 'VISA', true, true, 'NONE'),
(1, 1, '4111111111111115', 'ACTIVE', 'PRODUCED', 'DEBIT', 'MASTERCARD', true, true, 'NONE'),
(1, 1, '4111111111111116', 'INACTIVE', 'SHIPPED', 'DEBIT', 'VISA', false, false, 'NONE'),
(1, 1, '4111111111111117', 'ACTIVE', 'PRODUCED', 'CREDIT', 'MASTERCARD', true, true, 'NONE'),
(1, 1, '4111111111111118', 'ACTIVE', 'PRODUCED', 'DEBIT', 'VISA', true, true, 'NONE');

-- Create savings account transactions
INSERT INTO m_savings_account_transaction
(amount, transaction_date, is_reversed, transaction_type_enum, savings_account_id, office_id, booking_date, created_date, status_enum, running_balance_derived)
VALUES
(1000.00, CURRENT_DATE - 30, false, 1, 1, 1, CURRENT_DATE - 30, NOW() - INTERVAL '30 days', 0, 1000.00),
(500.00, CURRENT_DATE - 25, false, 1, 1, 1, CURRENT_DATE - 25, NOW() - INTERVAL '25 days', 0, 1500.00),
(-200.00, CURRENT_DATE - 20, false, 2, 1, 1, CURRENT_DATE - 20, NOW() - INTERVAL '20 days', 0, 1300.00),
(750.00, CURRENT_DATE - 15, false, 1, 1, 1, CURRENT_DATE - 15, NOW() - INTERVAL '15 days', 0, 2050.00),
(-100.00, CURRENT_DATE - 10, false, 2, 1, 1, CURRENT_DATE - 10, NOW() - INTERVAL '10 days', 0, 1950.00),
(2000.00, CURRENT_DATE - 5, false, 1, 1, 1, CURRENT_DATE - 5, NOW() - INTERVAL '5 days', 0, 3950.00),
(-300.00, CURRENT_DATE - 3, false, 2, 1, 1, CURRENT_DATE - 3, NOW() - INTERVAL '3 days', 0, 3650.00),
(1500.00, CURRENT_DATE - 1, false, 1, 1, 1, CURRENT_DATE - 1, NOW() - INTERVAL '1 day', 0, 5150.00),
(800.00, CURRENT_DATE, false, 1, 1, 1, CURRENT_DATE, NOW(), 0, 5950.00);

-- Create authorization transactions
INSERT INTO authorize_transaction
(version, savings_account_id, office_id, transaction_date, amount, created_at, is_manual, is_active, pending_amount, transaction_type, reference)
VALUES
(1, 1, 1, CURRENT_DATE - 15, 50.00, NOW() - INTERVAL '15 days', false, false, 0, 'PURCHASE', 'REF001'),
(1, 1, 1, CURRENT_DATE - 12, 75.00, NOW() - INTERVAL '12 days', false, false, 0, 'PURCHASE', 'REF002'),
(1, 1, 1, CURRENT_DATE - 10, 30.00, NOW() - INTERVAL '10 days', false, true, 30.00, 'PURCHASE', 'REF003'),
(1, 1, 1, CURRENT_DATE - 8, 100.00, NOW() - INTERVAL '8 days', false, false, 0, 'PURCHASE', 'REF004'),
(1, 1, 1, CURRENT_DATE - 5, 45.00, NOW() - INTERVAL '5 days', false, true, 45.00, 'PURCHASE', 'REF005'),
(1, 1, 1, CURRENT_DATE - 3, 200.00, NOW() - INTERVAL '3 days', false, true, 200.00, 'PURCHASE', 'REF006'),
(1, 1, 1, CURRENT_DATE - 1, 60.00, NOW() - INTERVAL '1 day', false, true, 60.00, 'ATM_WITHDRAWAL', 'REF007'),
(1, 1, 1, CURRENT_DATE, 150.00, NOW(), false, true, 150.00, 'PURCHASE', 'REF008');

-- Create card authorizations
DO $$
DECLARE
    card_rec RECORD;
    auth_count INTEGER := 0;
BEGIN
    FOR card_rec IN SELECT id FROM card WHERE status = 'ACTIVE' LIMIT 5 LOOP
        INSERT INTO card_authorization
        (version, card_id, auth_type, amount, currency, status, created_at, local_currency, transaction_type)
        VALUES
        (1, card_rec.id, 'PURCHASE', 50.00 + (auth_count * 25), 'USD', 'APPROVED', NOW() - INTERVAL '1 hour' * auth_count, 'USD', 'PURCHASE');
        auth_count := auth_count + 1;
    END LOOP;
END $$;

SELECT '✅ Sample Data Created!' as status;
SELECT 'Cards: ' || COUNT(*) as summary FROM card;
SELECT 'Savings TX: ' || COUNT(*) FROM m_savings_account_transaction;
SELECT 'Auth TX: ' || COUNT(*) FROM authorize_transaction;
SELECT 'Card Auth: ' || COUNT(*) FROM card_authorization;

EOF

echo ""
echo "✅ Sample data ready for CDC pipeline!"
echo ""
echo "Run: ./setup.sh && python3 consumer.py"
