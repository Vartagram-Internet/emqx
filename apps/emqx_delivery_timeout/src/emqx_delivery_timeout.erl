%%--------------------------------------------------------------------
%% Copyright (c) 2020-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% @doc EMQX Delivery Timeout Tracker
%%
%% This module tracks messages that are queued for delivery but not delivered
%% within a specified timeout period (default: 30 seconds).
%%
%% Design:
%% - Gen_server manages lifecycle and handles timeout events
%% - ETS table for high-throughput tracking (concurrent read/write)
%% - Erlang timers for efficient timeout handling
%% - Zero overhead when feature is disabled
%% - Minimal overhead when enabled (tracks only queued messages)
%%
%% @end
%%--------------------------------------------------------------------

-module(emqx_delivery_timeout).

-behaviour(gen_server).

-include("emqx_delivery_timeout.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx.hrl").

%% API
-export([
    start_link/0,
    track_queued_message/3,
    cancel_tracking/1,
    enable/0,
    disable/0,
    is_enabled/0,
    get_stats/0,
    update_config/1
]).

%% Gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Inline for zero overhead
-compile({inline, [is_enabled/0, get_timeout/0]}).

-record(state, {
    tid :: ets:tid(),
    cleanup_timer :: reference(),
    max_tracked :: pos_integer()
}).

%%--------------------------------------------------------------------
%% API - High-throughput operations using ETS directly
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Track a queued message for timeout monitoring
%% Called when message enters the inflight queue (cannot be delivered immediately)
-spec track_queued_message(binary(), binary(), emqx_types:message()) -> ok.
track_queued_message(MsgId, ClientId, Message) ->
    %% Fast path: Check if feature is enabled (persistent_term lookup ~5ns)
    case is_enabled() of
        false ->
            %% Feature disabled - return immediately (zero overhead)
            ok;
        true ->
            %% Feature enabled - start tracking this queued message
            do_track_queued_message(MsgId, ClientId, Message)
    end.

%% @doc Cancel timeout tracking for a message
%% Called when message is delivered or dropped from queue
-spec cancel_tracking(binary()) -> ok.
cancel_tracking(MsgId) ->
    %% Fast path: Check if feature is enabled
    case is_enabled() of
        false ->
            ok;
        true ->
            do_cancel_tracking(MsgId)
    end.

%% @doc Enable timeout tracking (called when rules are created)
-spec enable() -> ok.
enable() ->
    persistent_term:put(?FEATURE_ENABLED_KEY, true),
    ?SLOG(info, #{msg => "delivery_timeout_tracking_enabled"}),
    ok.

%% @doc Disable timeout tracking (called when no rules exist)
-spec disable() -> ok.
disable() ->
    persistent_term:put(?FEATURE_ENABLED_KEY, false),
    ?SLOG(info, #{msg => "delivery_timeout_tracking_disabled"}),
    ok.

%% @doc Check if tracking is enabled (inline for performance)
-spec is_enabled() -> boolean().
is_enabled() ->
    persistent_term:get(?FEATURE_ENABLED_KEY, false).

%% @doc Get current tracking statistics
-spec get_stats() -> map().
get_stats() ->
    case whereis(?MODULE) of
        undefined ->
            #{tracked_count => 0, enabled => false};
        _Pid ->
            gen_server:call(?MODULE, get_stats, 5000)
    end.

%% @doc Update configuration
-spec update_config(map()) -> ok.
update_config(Config) ->
    gen_server:call(?MODULE, {update_config, Config}, 5000).

%%--------------------------------------------------------------------
%% Internal functions - Direct ETS operations
%%--------------------------------------------------------------------

do_track_queued_message(MsgId, ClientId, Message) ->
    try
        Timeout = get_timeout(),
        QueuedAt = erlang:monotonic_time(millisecond),

        %% Send timeout message to gen_server after configured timeout
        TimerRef = erlang:send_after(Timeout, whereis(?MODULE), {delivery_timeout, MsgId}),

        %% Store in ETS for fast lookup (concurrent write)
        Entry = {MsgId, ClientId, Message, TimerRef, QueuedAt},
        ets:insert(?TIMEOUT_TAB, Entry),

        ok
    catch
        Class:Reason:Stacktrace ->
            ?SLOG(error, #{
                msg => "failed_to_track_delivery",
                message_id => MsgId,
                client_id => ClientId,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

do_cancel_tracking(MsgId) ->
    try
        case ets:lookup(?TIMEOUT_TAB, MsgId) of
            [{_, _, _, TimerRef, _}] ->
                %% Cancel timer asynchronously for better performance
                erlang:cancel_timer(TimerRef, [{async, true}, {info, false}]),

                %% Remove from ETS
                ets:delete(?TIMEOUT_TAB, MsgId),
                ok;
            [] ->
                %% Not found - already timed out or never tracked
                ok
        end
    catch
        Class:Reason:Stacktrace ->
            ?SLOG(error, #{
                msg => "failed_to_cancel_tracking",
                message_id => MsgId,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

get_timeout() ->
    persistent_term:get(?TIMEOUT_CONFIG_KEY, ?DEFAULT_TIMEOUT_MS).

%%--------------------------------------------------------------------
%% Gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),

    %% Create ETS table for tracking (owned by this gen_server)
    Tid = ets:new(?TIMEOUT_TAB, [
        named_table,
        % Allow other processes to read/write directly
        public,
        % MsgId is the key
        {keypos, 1},
        {write_concurrency, true},
        {read_concurrency, true}
    ]),

    %% Start periodic cleanup timer
    CleanupTimer = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup_stale_entries),

    MaxTracked = application:get_env(emqx_delivery_timeout, max_tracked, ?DEFAULT_MAX_TRACKED),

    ?SLOG(info, #{
        msg => "delivery_timeout_tracker_started",
        max_tracked => MaxTracked,
        timeout_ms => get_timeout()
    }),

    {ok, #state{
        tid = Tid,
        cleanup_timer = CleanupTimer,
        max_tracked = MaxTracked
    }}.

handle_call(get_stats, _From, State) ->
    TrackedCount = ets:info(?TIMEOUT_TAB, size),
    Memory = ets:info(?TIMEOUT_TAB, memory),

    Stats = #{
        tracked_count => TrackedCount,
        enabled => is_enabled(),
        memory_words => Memory,
        timeout_ms => get_timeout(),
        max_tracked => State#state.max_tracked,
        node => node()
    },

    {reply, Stats, State};
handle_call({update_config, Config}, _From, State) ->
    %% Update timeout configuration
    case maps:get(timeout_ms, Config, undefined) of
        undefined ->
            ok;
        TimeoutMs when is_integer(TimeoutMs), TimeoutMs > 0 ->
            persistent_term:put(?TIMEOUT_CONFIG_KEY, TimeoutMs),
            ?SLOG(info, #{msg => "timeout_config_updated", timeout_ms => TimeoutMs})
    end,

    %% Update max tracked
    NewState =
        case maps:get(max_tracked, Config, undefined) of
            undefined ->
                State;
            MaxTracked when is_integer(MaxTracked), MaxTracked > 0 ->
                State#state{max_tracked = MaxTracked}
        end,

    {reply, ok, NewState};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% @doc Handle delivery timeout event
handle_info({delivery_timeout, MsgId}, State) ->
    case ets:lookup(?TIMEOUT_TAB, MsgId) of
        [{_, ClientId, Message, _, QueuedAt}] ->
            %% Message still in queue after timeout period!
            Now = erlang:monotonic_time(millisecond),
            QueueTimeMs = Now - QueuedAt,

            %% Fire the timeout event (triggers rule engine, webhooks, etc.)
            fire_timeout_event(ClientId, Message, QueueTimeMs),

            %% Clean up tracking entry
            ets:delete(?TIMEOUT_TAB, MsgId),

            ?SLOG(warning, #{
                msg => "delivery_timeout_fired",
                message_id => MsgId,
                client_id => ClientId,
                topic => emqx_message:topic(Message),
                queue_time_ms => QueueTimeMs
            });
        [] ->
            %% Message was delivered before timeout - ignore
            ok
    end,
    {noreply, State};
%% @doc Periodic cleanup of stale entries (safety mechanism)
handle_info(cleanup_stale_entries, State) ->
    try
        cleanup_stale_entries(State),
        check_circuit_breaker(State)
    catch
        Class:Reason:Stacktrace ->
            ?SLOG(error, #{
                msg => "cleanup_failed",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end,

    %% Schedule next cleanup
    CleanupTimer = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup_stale_entries),
    {noreply, State#state{cleanup_timer = CleanupTimer}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% Clean up ETS table
    catch ets:delete(State#state.tid),

    %% Cancel cleanup timer
    catch erlang:cancel_timer(State#state.cleanup_timer),

    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

fire_timeout_event(ClientId, Message, QueueTimeMs) ->
    try
        %% Trigger rule engine event (will be handled by emqx_rule_events)
        %% The hook handler will convert raw params to an event message
        %% This will trigger webhooks, actions, alerts, etc.
        emqx_hooks:run('delivery.timeout', [ClientId, Message, QueueTimeMs]),

        ok
    catch
        Class:Reason:Stacktrace ->
            ?SLOG(error, #{
                msg => "failed_to_fire_timeout_event",
                client_id => ClientId,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end.

%% @doc Clean up entries older than 2x timeout period (safety net)
cleanup_stale_entries(_State) ->
    Now = erlang:monotonic_time(millisecond),
    % 2x timeout period
    MaxAge = get_timeout() * 2,
    Threshold = Now - MaxAge,

    %% Delete entries older than threshold
    DeletedCount = ets:select_delete(?TIMEOUT_TAB, [
        {{'_', '_', '_', '_', '$1'}, [{'<', '$1', Threshold}], [true]}
    ]),

    case DeletedCount > 0 of
        true ->
            ?SLOG(warning, #{
                msg => "cleaned_stale_timeout_entries",
                deleted_count => DeletedCount,
                threshold_age_ms => MaxAge
            });
        false ->
            ok
    end,

    ok.

%% @doc Circuit breaker: warn if too many messages are tracked
check_circuit_breaker(State) ->
    TrackedCount = ets:info(?TIMEOUT_TAB, size),

    case TrackedCount > State#state.max_tracked of
        true ->
            ?SLOG(error, #{
                msg => "delivery_timeout_circuit_breaker_triggered",
                tracked_count => TrackedCount,
                max_tracked => State#state.max_tracked,
                recommendation =>
                    "System under heavy load or subscribers not keeping up. "
                    "Consider scaling or checking subscriber health."
            });
        false when TrackedCount > (State#state.max_tracked div 2) ->
            %% Warn at 50% threshold
            ?SLOG(warning, #{
                msg => "high_number_of_tracked_timeouts",
                tracked_count => TrackedCount,
                max_tracked => State#state.max_tracked
            });
        false ->
            ok
    end,

    ok.
