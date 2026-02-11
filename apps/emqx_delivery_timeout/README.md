# EMQX Delivery Timeout Event Tracking

## Overview

This module implements the `delivery.timeout` event for EMQX broker. It tracks messages that are queued for delivery but cannot be delivered within a specified timeout period (default: 30 seconds).

## Features

- **Zero-cost when disabled**: Single persistent_term lookup (~5ns overhead)
- **Minimal overhead when enabled**: Tracks only queued/pending messages
- **Cluster-aware**: Each node tracks its own message queues independently
- **Auto-activation**: Automatically enabled when rules are created for the event
- **Dashboard integration**: Events visible in EMQX dashboard for monitoring
- **Rule engine compatible**: Can trigger webhooks, alerts, and custom actions

## When Timeout Events Fire

The `delivery.timeout` event fires when:

1. A message is published to a topic
2. The message is queued for delivery to a subscriber (immediate delivery not possible)
3. The message remains in the queue for longer than the configured timeout (default: 30s)

**Common scenarios**:
- Subscriber is offline or slow to consume messages
- Network connectivity issues between broker and subscriber
- Subscriber's message queue is full (QoS > 0 messages)
- Back-pressure from subscriber not keeping up with message rate

## Configuration

```hocon
delivery_timeout {
    enabled = true
    timeout = "30s"
    max_tracked = 1000000
}
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable delivery timeout tracking |
| `timeout` | duration | `30s` | Timeout period for queued messages |
| `max_tracked` | integer | `1,000,000` | Max messages to track per node (circuit breaker) |

## Usage in Rule Engine

### Example 1: Send Alert on Timeout

```sql
SELECT
    clientid,
    topic,
    payload,
    queue_time_ms
FROM "$events/delivery/timeout"
WHERE queue_time_ms > 25000
```

Action: HTTP Request to webhook endpoint

### Example 2: Monitor Specific Topics

```sql
SELECT
    clientid,
    topic,
    queue_time_ms,
    reason
FROM "$events/delivery/timeout"
WHERE topic =~ 'critical/#'
```

Action: Send notification to admin

### Example 3: Retry Delivery

```sql
SELECT
    clientid,
    topic,
    payload,
    qos
FROM "$events/delivery/timeout"
```

Action: Republish message to retry topic

## Event Fields

| Field | Type | Description |
|-------|------|-------------|
| `event` | atom | Always `delivery.timeout` |
| `id` | string | Message ID (hex string) |
| `clientid` | string | Subscriber client ID |
| `from_clientid` | string | Publisher client ID |
| `from_username` | string | Publisher username |
| `topic` | string | Message topic |
| `qos` | integer | Quality of Service (0, 1, or 2) |
| `payload` | binary | Message payload |
| `reason` | string | Always `"queue_timeout"` |
| `queue_time_ms` | integer | Time message was queued (milliseconds) |
| `timeout_at` | integer | Unix timestamp when timeout fired |
| `pub_props` | map | MQTT v5 publish properties |
| `publish_received_at` | integer | When message was originally received |
| `timestamp` | integer | Event timestamp |
| `node` | atom | Broker node where event fired |

## Performance Characteristics

### Disabled (No Rules)
- **Overhead**: ~5 nanoseconds per message (single boolean check)
- **Memory**: 0 bytes
- **Impact**: Negligible

### Enabled (Rules Exist)
- **Overhead**: ~200 nanoseconds per *queued* message only
- **Memory**: ~40 bytes per tracked message
- **Impact**: Minimal (only messages that are actually queued)

### Immediate Delivery (Most Common)
- **Overhead**: Same as disabled (~5ns)
- Messages delivered immediately bypass tracking entirely

## Architecture

```
Message Flow:
┌─────────────┐
│   Publish   │
└──────┬──────┘
       │
┌──────▼────────┐
│  Can Deliver  │
│  Immediately? │
└──────┬────────┘
       │
    ┌──┴──┐
   YES   NO (Queue Message)
    │     │
    │     └──► Start Timeout Timer
    │          Store in ETS
    │               │
    │          ┌────┴────┐
    │         30s      Delivered
    │          │          │
    │     Fire Event  Cancel Timer
    │          │      Delete ETS
    │          │          │
    └──────────┴──────────┘
          No Tracking
```

## Cluster Behavior

Each node in the cluster independently tracks timeouts for its own subscriber sessions:

- **Session locality**: Subscriber sessions are sticky to specific nodes
- **Local tracking**: Timeouts tracked on the node where the session lives
- **Dashboard aggregation**: Dashboard queries all nodes and merges results
- **Zero cross-node overhead**: No cluster gossip or coordination needed

## API

### Enable/Disable Tracking

```erlang
%% Enable tracking
emqx_delivery_timeout:enable().

%% Disable tracking
emqx_delivery_timeout:disable().

%% Check if enabled
emqx_delivery_timeout:is_enabled().
%% => true | false
```

### Get Statistics

```erlang
emqx_delivery_timeout:get_stats().
%% => #{
%%     tracked_count => 1234,
%%     enabled => true,
%%     memory_words => 49360,
%%     timeout_ms => 30000,
%%     max_tracked => 1000000,
%%     node => 'emqx@127.0.0.1'
%% }
```

### Update Configuration

```erlang
emqx_delivery_timeout:update_config(#{
    timeout_ms => 60000,  % Change to 60 seconds
    max_tracked => 500000
}).
```

## Integration Points

The module integrates with EMQX session management:

1. **Message queued**: `emqx_delivery_timeout:track_queued_message/3`
2. **Message delivered**: `emqx_delivery_timeout:cancel_tracking/1`
3. **Message dropped**: `emqx_delivery_timeout:cancel_tracking/1`
4. **Timeout fires**: `emqx_hooks:run('delivery.timeout', [ClientId, Message, QueueTimeMs])`

## Safety Features

### Circuit Breaker
If tracked messages exceed `max_tracked`, warnings are logged at 50% and errors at 100%.

### Stale Entry Cleanup
Periodic cleanup (every 60 seconds) removes entries older than 2× timeout period.

### Async Timer Cancellation
Timers are cancelled asynchronously for better performance.

## Monitoring

Monitor the health of delivery timeout tracking:

```erlang
%% Get stats from all cluster nodes
[{Node, emqx_delivery_timeout:get_stats()} || 
 Node <- emqx:running_nodes()].
```

Watch for:
- High `tracked_count`: Subscribers not keeping up
- Frequent timeout events: Network or subscriber issues
- Memory growth: Adjust `max_tracked` if needed

## Troubleshooting

### High Number of Timeouts

**Possible causes**:
- Subscribers offline or connectivity issues
- Subscribers cannot process messages fast enough
- Network latency between broker and subscribers

**Solutions**:
- Check subscriber health and connectivity
- Scale subscribers horizontally
- Increase message processing capacity
- Consider increasing timeout duration

### Memory Usage

**If tracked_count is high**:
- Normal during subscriber outages or slow consumption
- Set appropriate `max_tracked` based on available memory
- Monitor and alert on circuit breaker warnings

## License

Apache License 2.0
