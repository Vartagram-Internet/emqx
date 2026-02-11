%%--------------------------------------------------------------------
%% Copyright (c) 2020-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_delivery_timeout_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Initialize configuration in persistent_term for fast access
    ok = load_config(),
    %% Register hooks to listen for message lifecycle events
    %% This integrates with EMQX without modifying core logic
    ok = emqx_delivery_timeout:register_hooks(),
    emqx_delivery_timeout_sup:start_link().

stop(_State) ->
    %% Unregister hooks on application stop
    ok = emqx_delivery_timeout:unregister_hooks(),
    ok.

load_config() ->
    %% Feature starts disabled, auto-enabled when rules are created
    persistent_term:put({emqx_delivery_timeout, enabled}, false),

    %% Load timeout config (30s default)
    Timeout = application:get_env(emqx_delivery_timeout, timeout_ms, 30000),
    persistent_term:put({emqx_delivery_timeout, timeout_ms}, Timeout),

    ok.
