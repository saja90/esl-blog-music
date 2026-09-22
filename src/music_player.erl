-module(music_player).

-export([play/1, play/2]).

play(Song) ->
    open(music_synth:prepare(Song)).

play(Song, Selection) ->
    case music_synth:prepare(Song, Selection) of
        {error, _} = Error -> Error;
        Synth -> open(Synth)
    end.

open(Synth) ->
    case bridge(priv_dir()) of
        {error, _} = Error -> Error;
        {ok, Executable, Arguments, Options} ->
            {ok, Listen} = gen_tcp:listen(0, [binary, {packet, 4}, {active, false},
                                              {ip, {127, 0, 0, 1}}]),
            {ok, {{127, 0, 0, 1}, Number}} = inet:sockname(Listen),
            Port = open_port({spawn_executable, Executable},
                             [{args, Arguments ++ [integer_to_list(Number)]}, exit_status]
                             ++ Options),
            Result = case gen_tcp:accept(Listen, 10000) of
                         {ok, Socket} ->
                             try stream(Socket, Synth, false)
                             after gen_tcp:close(Socket) end;
                         {error, Reason} -> {error, {bridge_connect, Reason}}
                     end,
            gen_tcp:close(Listen),
            catch port_close(Port),
            Result
    end.

bridge(Priv) ->
    case os:type() of
        {win32, _} ->
            case os:find_executable("powershell.exe") of
                false -> {error, powershell_not_found};
                PowerShell ->
                    Script = filename:join(Priv, "wave_out.ps1"),
                    {ok, PowerShell,
                     ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                      "-File", Script, "-Port"],
                     [hide]}
            end;
        {unix, darwin} ->
            Bridge = case os:getenv("MUSIC_AUDIO_BRIDGE") of
                         false -> filename:join(Priv, "audio_out");
                         Path -> Path
                     end,
            case filelib:is_regular(Bridge) of
                true -> {ok, Bridge, [], []};
                false -> {error, macos_bridge_not_found}
            end;
        OsType ->
            {error, {unsupported_platform, OsType}}
    end.

stream(Socket, Synth, EndSent) ->
    case gen_tcp:recv(Socket, 0, 15000) of
        {ok, <<$R>>} when EndSent ->
            stream(Socket, Synth, true);
        {ok, <<$R>>} ->
            case music_synth:render(Synth) of
                done ->
                    ok = gen_tcp:send(Socket, <<$E>>),
                    stream(Socket, Synth, true);
                {PCM, Next} ->
                    ok = gen_tcp:send(Socket, <<$A, PCM/binary>>),
                    stream(Socket, Next, false)
            end;
        {ok, <<$D>>} -> ok;
        {ok, <<$X, Message/binary>>} ->
            {error, {audio, binary_to_list(Message)}};
        {error, timeout} -> {error, bridge_timeout};
        {error, Reason} -> {error, {bridge_socket, Reason}}
    end.

priv_dir() ->
    case code:priv_dir(music) of
        {error, bad_name} ->
            filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
        Dir -> Dir
    end.
