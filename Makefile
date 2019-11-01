REBAR_URL ?= https://s3.amazonaws.com/rebar3/rebar3

ifneq ($(shell which wget 2>/dev/null),)
REBAR_GET ?= wget -q $(REBAR_URL)
else
REBAR_GET ?= curl -s -f $(REBAR_URL) >rebar3
endif

.PHONY: all compile doc test clean clean-all

all: compile doc

rebar3:
	$(REBAR_GET)
	chmod +x rebar3

compile: rebar3
	./rebar3 compile

doc: rebar3
	./rebar3 edoc

test: rebar3
	./rebar3 eunit

clean: rebar3
	./rebar3 clean

clean-all:
	rm -rf rebar3 ebin doc/*{-info,.html,.css,.png}

