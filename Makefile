.PHONY: compile test shell release clean dialyzer

compile:
	rebar3 compile

test:
	rebar3 eunit

shell:
	rebar3 shell

release:
	rebar3 release

clean:
	rebar3 clean

dialyzer:
	rebar3 dialyzer
