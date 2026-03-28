"""Tests for fix-json.py JSON repair utility.

Covers all 8 regex repair passes (0-7), CLI integration, multi-pass interactions,
edge cases, and documents known limitations via xfail markers.
"""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

# Path to the script under test
SCRIPT_PATH = str(Path(__file__).parent.parent / "fix-json.py")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def fix_json_func():
    """Import fix_json() from the hyphenated fix-json.py."""
    spec = importlib.util.spec_from_file_location("fix_json_mod", SCRIPT_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.fix_json


@pytest.fixture
def run_cli(tmp_path):
    """Run fix-json.py as a subprocess, returning CompletedProcess."""
    def _run(input_content: str, *, extra_args=None):
        input_file = tmp_path / "input.json"
        output_file = tmp_path / "output.json"
        input_file.write_text(input_content, encoding="utf-8")
        args = [sys.executable, SCRIPT_PATH]
        if extra_args is not None:
            args.extend(extra_args)
        else:
            args.extend([str(input_file), str(output_file)])
        result = subprocess.run(args, capture_output=True, text=True)
        result.output_file = output_file  # attach for inspection
        return result
    return _run


# ===========================================================================
# Pass 0: Trailing comma removal
# ===========================================================================

@pytest.mark.parametrize("broken,expected", [
    # Object with trailing comma
    ('{"a": 1, "b": 2,}', {"a": 1, "b": 2}),
    # Array with trailing comma
    ('[1, 2, 3,]', [1, 2, 3]),
    # Nested trailing commas
    ('{"a": [1, 2,], "b": {"c": 3,},}', {"a": [1, 2], "b": {"c": 3}}),
    # Trailing comma with whitespace/newline before closing brace
    ('{"a": 1,\n}', {"a": 1}),
    # Trailing comma with spaces before closing bracket
    ('[1, 2,   ]', [1, 2]),
], ids=[
    "object-trailing", "array-trailing", "nested-trailing",
    "trailing-with-newline", "trailing-with-spaces",
])
def test_pass0_trailing_commas(fix_json_func, broken, expected):
    result = fix_json_func(broken)
    assert json.loads(result) == expected


def test_pass0_no_trailing_comma_unchanged(fix_json_func):
    """Valid JSON without trailing commas is returned unchanged."""
    original = '{"a": 1, "b": 2}'
    result = fix_json_func(original)
    assert json.loads(result) == {"a": 1, "b": 2}


def test_pass0_comma_inside_string_not_stripped(fix_json_func):
    """A comma inside a string value is never removed."""
    original = '{"msg": "a, b,"}'
    result = fix_json_func(original)
    assert json.loads(result) == {"msg": "a, b,"}


# ===========================================================================
# Pass 1: Unescaped backslash repair
# ===========================================================================

@pytest.mark.parametrize("broken,key,expected_value", [
    # Basic Windows path (avoiding \t which is a valid JSON escape)
    (r'{"path": "C:\Users\docs"}', "path", r"C:\Users\docs"),
    # Namespace with single backslash
    ('{"ns": "Spatie\\Permission"}', "ns", "Spatie\\Permission"),
    # Preserve already-escaped backslashes
    ('{"path": "C:\\\\Users\\\\docs"}', "path", "C:\\Users\\docs"),
    # Preserve valid escape sequences (newline, tab)
    ('{"text": "line1\\nline2\\ttab"}', "text", "line1\nline2\ttab"),
    # Preserve unicode escape sequences
    ('{"char": "\\u00e9"}', "char", "\u00e9"),
], ids=["windows-path", "namespace", "already-escaped", "valid-escapes", "unicode-escape"])
def test_pass1_unescaped_backslashes(fix_json_func, broken, key, expected_value):
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed[key] == expected_value


# ===========================================================================
# Pass 2: Missing comma between strings
# ===========================================================================

@pytest.mark.parametrize("broken,expected_list", [
    # Two strings in array
    ('["a"\n"b"]', ["a", "b"]),
    # Indented strings
    ('[\n    "a"\n    "b"\n]', ["a", "b"]),
    # Already has comma (no-op)
    ('["a",\n"b"]', ["a", "b"]),
], ids=["basic-pair", "indented", "already-correct"])
def test_pass2_missing_comma_str_str(fix_json_func, broken, expected_list):
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed == expected_list


# ===========================================================================
# Pass 3: Missing comma between strings and numbers
# ===========================================================================

@pytest.mark.parametrize("broken,expected", [
    # String then number
    ('["hello"\n42]', ["hello", 42]),
    # Number then string
    ('[42\n"hello"]', [42, "hello"]),
    # Indented
    ('[\n    "status"\n    200\n]', ["status", 200]),
    # Number then string with indentation
    ('[\n    100\n    "ok"\n]', [100, "ok"]),
], ids=["str-then-num", "num-then-str", "indented-str-num", "indented-num-str"])
def test_pass3_missing_comma_str_num(fix_json_func, broken, expected):
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed == expected


# ===========================================================================
# Pass 4: Missing comma between closing brackets and strings/numbers
# ===========================================================================

@pytest.mark.parametrize("broken,expected", [
    # } then string key
    ('{"a": {}\n"b": 2}', {"a": {}, "b": 2}),
    # ] then string
    ('[[1]\n"extra"]', [[1], "extra"]),
    # } then string in array context
    ('[{"x": 1}\n"y"]', [{"x": 1}, "y"]),
], ids=["obj-then-key", "arr-then-str", "obj-in-arr-then-str"])
def test_pass4_missing_comma_bracket_str(fix_json_func, broken, expected):
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed == expected


# ===========================================================================
# Pass 5: Missing comma between strings and opening brackets
# ===========================================================================

@pytest.mark.parametrize("broken,expected", [
    # String then object
    ('["a"\n{"b": 1}]', ["a", {"b": 1}]),
    # String then array
    ('["a"\n[1, 2]]', ["a", [1, 2]]),
    # Nested key-value then object
    ('{"a": "v"\n"b": {}}', {"a": "v", "b": {}}),
], ids=["str-then-obj", "str-then-arr", "val-then-obj-key"])
def test_pass5_missing_comma_str_bracket(fix_json_func, broken, expected):
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed == expected


# ===========================================================================
# Pass 6: Missing comma between closing and opening brackets
# ===========================================================================

@pytest.mark.parametrize("broken,expected", [
    # } then {
    ('[{"a": 1}\n{"b": 2}]', [{"a": 1}, {"b": 2}]),
    # ] then [
    ('[[1]\n[2]]', [[1], [2]]),
    # ] then {
    ('[[1]\n{"a": 2}]', [[1], {"a": 2}]),
    # } then [
    ('[{"a": 1}\n[2]]', [{"a": 1}, [2]]),
], ids=["obj-obj", "arr-arr", "arr-obj", "obj-arr"])
def test_pass6_missing_comma_bracket_bracket(fix_json_func, broken, expected):
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed == expected


# ===========================================================================
# Pass 7: Missing comma between booleans/null and strings
# ===========================================================================

@pytest.mark.parametrize("broken,expected", [
    # true then string
    ('[true\n"x"]', [True, "x"]),
    # false then string
    ('[false\n"y"]', [False, "y"]),
    # null then string
    ('[null\n"z"]', [None, "z"]),
    # string then true
    ('["x"\ntrue]', ["x", True]),
    # string then false
    ('["x"\nfalse]', ["x", False]),
    # string then null
    ('["x"\nnull]', ["x", None]),
], ids=["true-str", "false-str", "null-str", "str-true", "str-false", "str-null"])
def test_pass7_missing_comma_bool_str(fix_json_func, broken, expected):
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed == expected


# ===========================================================================
# CLI Integration Tests
# ===========================================================================

class TestCLI:
    """Test fix-json.py invoked as a subprocess."""

    def test_cli_valid_json(self, run_cli):
        """Valid JSON passes through unchanged, exit 0."""
        content = '{"key": "value", "num": 42}'
        result = run_cli(content)
        assert result.returncode == 0
        output = result.output_file.read_text(encoding="utf-8")
        assert json.loads(output) == json.loads(content)

    def test_cli_repairable_json(self, run_cli):
        """Broken but repairable JSON exits 0 with valid output."""
        content = '["a"\n"b"\n"c"]'
        result = run_cli(content)
        assert result.returncode == 0
        output = result.output_file.read_text(encoding="utf-8")
        assert json.loads(output) == ["a", "b", "c"]

    def test_cli_irreparable_json(self, run_cli):
        """Irreparable JSON exits 2 with error message."""
        result = run_cli("{{{")
        assert result.returncode == 2
        assert "Repair failed" in result.stderr or "invalid" in result.stderr.lower()

    def test_cli_empty_file(self, run_cli):
        """Empty file exits 2 (not valid JSON)."""
        result = run_cli("")
        assert result.returncode == 2

    def test_cli_wrong_args_no_args(self):
        """No arguments exits 1 with usage message."""
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH],
            capture_output=True, text=True
        )
        assert result.returncode == 1
        assert "Usage" in result.stderr

    def test_cli_wrong_args_one_arg(self):
        """One argument exits 1 with usage message."""
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, "only_one"],
            capture_output=True, text=True
        )
        assert result.returncode == 1
        assert "Usage" in result.stderr

    def test_cli_missing_input_file(self, tmp_path):
        """Nonexistent input file exits 1."""
        output_file = tmp_path / "output.json"
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, "/nonexistent/path.json", str(output_file)],
            capture_output=True, text=True
        )
        assert result.returncode == 1
        assert "Error" in result.stderr


# ===========================================================================
# Multi-Pass Tests
# ===========================================================================

class TestMultiPass:
    """Inputs requiring multiple fix_json() iterations."""

    def test_cascading_string_commas(self, run_cli):
        """Three strings missing commas -- needs multiple iterations.

        Pass 2 regex only fixes one adjacent pair per call because the
        matched group consumes the second string. The CLI's 3-iteration
        loop resolves this.
        """
        content = '[\n    "alpha"\n    "beta"\n    "gamma"\n]'
        result = run_cli(content)
        assert result.returncode == 0
        output = result.output_file.read_text(encoding="utf-8")
        assert json.loads(output) == ["alpha", "beta", "gamma"]

    def test_backslash_plus_missing_comma(self, run_cli):
        """Backslash repair + missing comma repair across iterations."""
        content = r'["C:\Users\test"' + '\n"other"]'
        result = run_cli(content)
        assert result.returncode == 0
        output = result.output_file.read_text(encoding="utf-8")
        parsed = json.loads(output)
        assert len(parsed) == 2
        assert parsed[1] == "other"

    def test_mixed_types_missing_commas(self, run_cli):
        """Multiple types with missing commas (string, number, string)."""
        content = '[\n    "name"\n    42\n    "end"\n]'
        result = run_cli(content)
        assert result.returncode == 0
        output = result.output_file.read_text(encoding="utf-8")
        assert json.loads(output) == ["name", 42, "end"]

    def test_trailing_comma_combined_with_missing_comma(self, run_cli):
        """Input with both trailing commas and missing commas between elements."""
        content = '{"a": [1, 2,]\n"b": 3}'
        result = run_cli(content)
        assert result.returncode == 0
        output = result.output_file.read_text(encoding="utf-8")
        assert json.loads(output) == {"a": [1, 2], "b": 3}


# ===========================================================================
# Edge Case Tests
# ===========================================================================

class TestEdgeCases:
    """Edge cases: valid JSON, nesting, encoding, formatting."""

    def test_already_valid_json(self, fix_json_func):
        """Valid JSON is returned unmodified."""
        valid = '{"key": "value", "num": 42, "arr": [1, 2, 3]}'
        result = fix_json_func(valid)
        assert result == valid
        assert json.loads(result) == json.loads(valid)

    def test_nested_objects_missing_commas(self, fix_json_func):
        """Deep nesting with missing commas at multiple levels."""
        broken = '{"a": {"b": {"c": 1}\n"d": 2}\n"e": 3}'
        result = fix_json_func(broken)
        parsed = json.loads(result)
        assert parsed["a"]["b"] == {"c": 1}
        assert parsed["a"]["d"] == 2
        assert parsed["e"] == 3

    def test_escaped_quotes_in_strings(self, fix_json_func):
        """Strings containing escaped quotes are preserved."""
        broken = '["say \\"hello\\""\n"world"]'
        result = fix_json_func(broken)
        parsed = json.loads(result)
        assert parsed[0] == 'say "hello"'
        assert parsed[1] == "world"

    def test_utf8_content(self, fix_json_func):
        """Multi-byte UTF-8 characters are preserved through repair."""
        broken = '["\\u4f60\\u597d"\n"caf\\u00e9"]'
        result = fix_json_func(broken)
        parsed = json.loads(result)
        assert len(parsed) == 2
        assert parsed[0] == "\u4f60\u597d"
        assert parsed[1] == "caf\u00e9"

    def test_large_array(self, fix_json_func):
        """Array with many elements missing commas."""
        elements = [f'"item{i}"' for i in range(50)]
        broken = "[\n" + "\n".join(f"    {e}" for e in elements) + "\n]"
        result = fix_json_func(broken)
        # May need multiple calls (the CLI does 3 iterations)
        for _ in range(3):
            result = fix_json_func(result)
        parsed = json.loads(result)
        assert len(parsed) == 50
        assert parsed[0] == "item0"
        assert parsed[49] == "item49"

    def test_preserves_indentation(self, fix_json_func):
        """Whitespace/indentation is preserved after comma insertion."""
        broken = '{\n    "a": "1"\n    "b": "2"\n}'
        result = fix_json_func(broken)
        assert '    "b"' in result
        parsed = json.loads(result)
        assert parsed == {"a": "1", "b": "2"}


# ===========================================================================
# Known Limitations (xfail)
# ===========================================================================

@pytest.mark.xfail(reason="Pass 7 does not handle bool/null -> number transitions")
def test_pass7_bool_to_number(fix_json_func):
    broken = '[true\n42]'
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed == [True, 42]


@pytest.mark.xfail(reason="Pass 7 does not handle number -> bool/null transitions")
def test_pass7_number_to_bool(fix_json_func):
    broken = '[42\ntrue]'
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed == [42, True]


@pytest.mark.xfail(reason="Pass 7 does not handle bool/null -> bool/null transitions")
def test_pass7_bool_to_bool(fix_json_func):
    broken = '[true\nfalse]'
    result = fix_json_func(broken)
    parsed = json.loads(result)
    assert parsed == [True, False]


def test_root_level_still_invalid(fix_json_func):
    """Two root-level objects remain invalid JSON even after comma insertion.

    Pass 6 inserts a comma between } and {, but the result is still not
    valid JSON (no enclosing array). This confirms the script doesn't
    accidentally "fix" structurally invalid input into something parseable.
    """
    broken = '{"a": 1}\n{"b": 2}'
    result = fix_json_func(broken)
    with pytest.raises(json.JSONDecodeError):
        json.loads(result)
