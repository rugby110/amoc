-module(random2).

-export([normal/2,
         gamma/2]).

%% Box-Muller transform
normal(0, 1) ->
    maybe_seed(),
    U1 = uniform_exclusive(),
    U2 = uniform_exclusive(),
    math:sqrt(-2 * math:log(U1)) * math:cos(2*math:pi()*U2).

uniform_exclusive() ->
    case random:uniform() of
        0.0 -> uniform_exclusive();
        1.0 -> uniform_exclusive();
        Other -> Other
    end.

%% Marsaglia and Tsang's Method
gamma(Alfa, 1) when Alfa >= 1 ->
    maybe_seed(),
    Z = normal(0, 1),
    U = random:uniform(),
    D = Alfa-(1/3),
    C = 1 / math:sqrt(9*D),
    V = math:pow(1 + C*Z, 3),
    case Z > -1/C andalso math:log(U) < (0.5*Z*Z + D - D*V + D*math:log(V)) of
        true -> D*V;
        false -> gamma(Alfa, 1)
    end;
gamma(Alfa, Beta) ->
    gamma(Alfa, 1) / Beta.

maybe_seed() ->
    case erlang:get(random_seed) of
        undefined -> random:seed(os:timestamp());
        _ -> ok
    end.
