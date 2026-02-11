%%--------------------------------------------------------------------
%% Copyright (c) 2020-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_delivery_timeout_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },

    ChildSpecs = [
        #{
            id => emqx_delivery_timeout,
            start => {emqx_delivery_timeout, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [emqx_delivery_timeout]
        }
    ],

    {ok, {SupFlags, ChildSpecs}}.
