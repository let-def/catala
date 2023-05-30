INPUTS=$(wildcard error-*.catala_en)
TARGETS=$(patsubst %.catala_en, %.output, $(INPUTS))

all:
	for i in $(INPUTS); do ../_build/install/default/bin/catala Typecheck $$i >& $${i/catala_en/output}; done; true

.PHONY: all $(TARGETS)
