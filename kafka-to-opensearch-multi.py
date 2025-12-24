#!/usr/bin/env python3
"""
Multi-table Kafka to OpenSearch consumer
Reads CDC messages from multiple Kafka topics and writes to OpenSearch
"""

import json
import sys
from kafka import KafkaConsumer
import requests
from typing import Dict, Any

# Configuration
KAFKA_BOOTSTRAP = 'localhost:29092'
OPENSEARCH_URL = 'http://localhost:9200'

# Topic to index mapping
# Debezium creates topics with pattern: {topic.prefix}.{schema}.{table}
TOPIC_INDEX_MAPPING = {
    # Original table
    'm_savings_account_transaction': 'm_savings_account_transaction',

    # New card-related tables
    'postgres.public.card': 'card',
    'postgres.public.authorize_transaction': 'authorize_transaction',
    'postgres.public.card_authorization': 'card_authorization',
}

# All topics to subscribe to
TOPICS = list(TOPIC_INDEX_MAPPING.keys())


def get_index_name(topic: str) -> str:
    """Get OpenSearch index name from Kafka topic name"""
    return TOPIC_INDEX_MAPPING.get(topic, topic.split('.')[-1])


def process_message(topic: str, value: Dict[str, Any]) -> None:
    """Process a single CDC message and write to OpenSearch"""
    index_name = get_index_name(topic)

    # Handle INSERT/UPDATE (after field contains the new data)
    if 'after' in value and value['after'] is not None:
        doc = value['after']
        doc_id = doc.get('id')

        if not doc_id:
            print(f"⚠️  No 'id' field in document from topic '{topic}', skipping")
            return

        # Index to OpenSearch
        response = requests.put(
            f"{OPENSEARCH_URL}/{index_name}/_doc/{doc_id}",
            json=doc,
            headers={'Content-Type': 'application/json'}
        )

        if response.status_code in [200, 201]:
            operation = value.get('op', '?')
            op_name = {
                'r': 'snapshot',
                'c': 'create',
                'u': 'update'
            }.get(operation, operation)

            return {
                'success': True,
                'operation': op_name,
                'index': index_name,
                'doc_id': doc_id
            }
        else:
            print(f"❌ Failed to index to '{index_name}': {response.text}")
            return {'success': False}

    # Handle DELETE
    elif value.get('op') == 'd':
        before = value.get('before', {})
        doc_id = before.get('id')

        if not doc_id:
            print(f"⚠️  No 'id' field in before state from topic '{topic}', skipping delete")
            return

        response = requests.delete(
            f"{OPENSEARCH_URL}/{index_name}/_doc/{doc_id}"
        )

        if response.status_code in [200, 404]:  # 404 is ok (already deleted)
            return {
                'success': True,
                'operation': 'delete',
                'index': index_name,
                'doc_id': doc_id
            }
        else:
            print(f"❌ Failed to delete from '{index_name}': {response.text}")
            return {'success': False}

    return None


def main():
    print(f"🚀 Starting Multi-table Kafka→OpenSearch Consumer")
    print(f"   Kafka: {KAFKA_BOOTSTRAP}")
    print(f"   OpenSearch: {OPENSEARCH_URL}")
    print(f"   Topics: {len(TOPICS)}")
    for topic in TOPICS:
        print(f"      - {topic} → {get_index_name(topic)}")
    print()

    # Create Kafka consumer
    try:
        consumer = KafkaConsumer(
            *TOPICS,  # Subscribe to all topics
            bootstrap_servers=KAFKA_BOOTSTRAP,
            auto_offset_reset='earliest',
            enable_auto_commit=True,
            group_id='opensearch-multi-consumer-group',
            value_deserializer=lambda x: json.loads(x.decode('utf-8'))
        )
        print("✅ Connected to Kafka")
    except Exception as e:
        print(f"❌ Failed to connect to Kafka: {e}")
        sys.exit(1)

    # Track statistics
    stats = {
        'total': 0,
        'by_index': {},
        'by_operation': {}
    }

    # Process messages
    try:
        print("\n📡 Listening for CDC events... (Press Ctrl+C to stop)\n")

        for message in consumer:
            try:
                topic = message.topic
                value = message.value

                result = process_message(topic, value)

                if result and result.get('success'):
                    stats['total'] += 1

                    index = result['index']
                    operation = result['operation']

                    # Update stats
                    stats['by_index'][index] = stats['by_index'].get(index, 0) + 1
                    stats['by_operation'][operation] = stats['by_operation'].get(operation, 0) + 1

                    # Print progress
                    emoji = {
                        'snapshot': '📸',
                        'create': '➕',
                        'update': '✏️',
                        'delete': '🗑️'
                    }.get(operation, '📝')

                    print(f"{emoji} [{stats['total']}] {index}:{result['doc_id']} ({operation})")

            except Exception as e:
                print(f"❌ Error processing message from {message.topic}: {e}")

    except KeyboardInterrupt:
        print(f"\n\n⏹️  Stopped by user")
    finally:
        # Print final statistics
        print("\n" + "="*60)
        print("📊 Final Statistics")
        print("="*60)
        print(f"Total messages processed: {stats['total']}")
        print()

        if stats['by_index']:
            print("By Index:")
            for index, count in sorted(stats['by_index'].items()):
                print(f"  {index}: {count}")
            print()

        if stats['by_operation']:
            print("By Operation:")
            for operation, count in sorted(stats['by_operation'].items()):
                print(f"  {operation}: {count}")
            print()

        consumer.close()
        print("✅ Consumer closed")


if __name__ == '__main__':
    main()
