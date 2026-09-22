-module(demo_song).

-export([bpm/0, tracks/0]).

bpm() -> 120.

tracks() ->
    [{kick, lists:seq(0, 30, 2)},
     {snare, lists:seq(1, 31, 2)},
     {closed_hat, [B / 2 || B <- lists:seq(0, 63)]},
     {bass, notes([c2, c2, g2, c2, a1, a1, e2, a1,
                   f2, f2, c2, f2, g1, g1, d2, g1,
                   c2, e2, g2, e2, e2, g2, b2, g2,
                   f2, a2, c3, a2, g1, d2, g2, d2], 0.45)},
     {pad, [{0, 4, {c4, e4, g4}}, {4, 4, {a3, c4, e4}},
            {8, 4, {f3, a3, c4}}, {12, 4, {g3, b3, d4}},
            {16, 4, {c4, e4, g4}}, {20, 4, {e3, g3, b3}},
            {24, 4, {f3, a3, c4}}, {28, 4, {g3, b3, d4}}]},
     {lead, notes([e4, g4, a4, g4, e4, d4, c4, d4,
                   e4, a4, g4, e4, d4, g4, e4, c4,
                   g4, a4, c5, b4, a4, g4, e4, d4,
                   f4, a4, c5, a4, g4, e4, d4, c4], 0.7)}].

notes(Notes, Duration) ->
    lists:zipwith(fun(Beat, Note) -> {Beat, Duration, Note} end,
                  lists:seq(0, length(Notes) - 1), Notes).
