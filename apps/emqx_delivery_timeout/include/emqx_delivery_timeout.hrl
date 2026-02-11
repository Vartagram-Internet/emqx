%%--------------------------------------------------------------------
%% Copyright (c) 2020-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-ifndef(EMQX_DELIVERY_TIMEOUT_HRL).
-define(EMQX_DELIVERY_TIMEOUT_HRL, true).

%% ETS table name for tracking timeouts
-define(TIMEOUT_TAB, emqx_delivery_timeout_tracker).

%% Persistent term keys
-define(FEATURE_ENABLED_KEY, {emqx_delivery_timeout, enabled}).
-define(TIMEOUT_CONFIG_KEY, {emqx_delivery_timeout, timeout_ms}).

%% Default timeout: 30 seconds
-define(DEFAULT_TIMEOUT_MS, 30000).

%% Cleanup interval: 60 seconds
-define(CLEANUP_INTERVAL, 60000).

%% Max tracked messages per node (circuit breaker)
-define(DEFAULT_MAX_TRACKED, 1000000).

-endif.
