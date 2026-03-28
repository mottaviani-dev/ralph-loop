.PHONY: test test-python test-bash lint

test: test-python test-bash

test-python:
	python3 -m pytest tests/test_fix_json.py -v

test-bash:
	bash tests/test_validate_env.sh
	bash tests/test_commit_scoping.sh
	bash tests/test_pid_deregistration.sh
	bash tests/test_check_stalemate.sh
	bash tests/test_work_loop.sh
	bash tests/test_discovery_loop.sh
	bash tests/test_arg_parsing.sh
	bash tests/test_summary.sh
	bash tests/test_validation_safety.sh
	bash tests/test_ensure_learnings_file.sh
	bash tests/test_locking.sh
	bash tests/test_cleanup_guard.sh
	bash tests/test_validation_exit_codes.sh
	bash tests/test_cleanup_body.sh
	bash tests/test_cleanup_escalation.sh
	bash tests/test_notify.sh
	bash tests/test_get_cumulative_cost.sh
	bash tests/test_invoke_claude_agent.sh
	bash tests/test_migration.sh
	bash tests/test_prompt_vars.sh

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found. Install with: brew install shellcheck"; exit 1; }
	shellcheck run.sh lib/*.sh tests/*.sh
