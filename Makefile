.PHONY: check shellcheck

check:
	bash tests/run.sh

shellcheck:
	shellcheck -S error \
	  tools/*.sh \
	  templates/cmd/main \
	  templates/cmd/uninstall_init \
	  templates/cmd/uninstall_callback \
	  templates/tests/accept.sh \
	  tests/run.sh
