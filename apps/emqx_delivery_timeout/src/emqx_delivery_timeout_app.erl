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
    %% Check for existing rules and enable if needed
    ok = maybe_enable_from_existing_rules(),
    emqx_delivery_timeout_sup:start_link().

stop(_State) ->
    %% Unregister hooks on application stop
    ok = emqx_delivery_timeout:unregister_hooks(),
    %% Unregister delivery.timeout specific hook handler
    catch emqx_hooks:del('delivery.timeout', {emqx_rule_events, on_delivery_timeout}),
    ok.

%% @doc Check if any existing rules use delivery.timeout event and enable if so
maybe_enable_from_existing_rules() ->
    try
        case erlang:module_loaded(emqx_rule_engine) of
            true ->
                %% Use internal API to get all rules for all namespaces
                Tags = emqx_rule_engine:get_rules_with_same_event(
                    undefined, <<"$events/delivery/timeout">>
                ),
                case Tags of
                    [] ->
                        ok;
                    [_ | _] ->
                        %% Enable feature
                        emqx_delivery_timeout:enable(),
                        %% Register hook handler so events fire
                        catch emqx_hooks:add(
                            'delivery.timeout', {emqx_rule_events, on_delivery_timeout, []}
                        )
                end;
            false ->
                %% Rule engine not loaded yet
                ok
        end
    catch
        _:_ -> ok
    end.

load_config() ->
    %% Feature starts disabled, auto-enabled when rules are created
    persistent_term:put({emqx_delivery_timeout, enabled}, false),

    %% Load timeout config (30s default)
    Timeout = application:get_env(emqx_delivery_timeout, timeout_ms, 30000),
    persistent_term:put({emqx_delivery_timeout, timeout_ms}, Timeout),

    ok.
