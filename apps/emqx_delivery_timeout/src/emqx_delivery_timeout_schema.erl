%%--------------------------------------------------------------------
%% Copyright (c) 2020-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_delivery_timeout_schema).

-include_lib("hocon/include/hoconsc.hrl").

-export([
    namespace/0,
    roots/0,
    fields/1,
    desc/1
]).

namespace() -> "delivery_timeout".

roots() ->
    [{delivery_timeout, hoconsc:mk(hoconsc:ref(?MODULE, delivery_timeout), #{})}].

fields(delivery_timeout) ->
    [
        {enabled,
            hoconsc:mk(boolean(), #{
                default => true,
                desc => ?DESC(enabled)
            })},
        {timeout,
            hoconsc:mk(emqx_schema:duration_ms(), #{
                default => <<"30s">>,
                desc => ?DESC(timeout)
            })},
        {max_tracked,
            hoconsc:mk(pos_integer(), #{
                default => 1000000,
                desc => ?DESC(max_tracked)
            })}
    ].

desc(delivery_timeout) ->
    "Configuration for delivery timeout event tracking. "
    "Monitors messages that remain queued for longer than the specified timeout period.";
desc(enabled) ->
    "Enable delivery timeout tracking. When enabled, messages that remain in the "
    "delivery queue longer than the configured timeout will trigger a delivery.timeout event. "
    "This event can be used in rules to trigger webhooks, alerts, or other actions.";
desc(timeout) ->
    "Maximum time a message can remain in the delivery queue before a timeout event is triggered. "
    "Default is 30 seconds. This applies only to messages that are queued for delivery "
    "(subscriber cannot keep up or is temporarily unavailable).";
desc(max_tracked) ->
    "Maximum number of messages to track for timeout simultaneously per node. "
    "Acts as a circuit breaker to prevent resource exhaustion. "
    "Default is 1,000,000 messages per node.";
desc(_) ->
    undefined.
