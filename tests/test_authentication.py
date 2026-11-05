"""Run authentication branches with Tera Term, without SSH or password dialogs.

Usage: python tests/test_authentication.py --ttpmacro PATH/TO/ttpmacro.exe
Only Python's standard library and Tera Term 5.5.2+ are required.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import unittest
import uuid


def ttl_string(value):
    """Represent quotes and control characters using TTL character constants."""
    parts = []
    chunk = []
    for char in value:
        if char in "'\"" or ord(char) < 32 or ord(char) == 127:
            if chunk:
                parts.append("'" + "".join(chunk) + "'")
                chunk.clear()
            parts.append(f"#{ord(char)}")
        else:
            chunk.append(char)
    if chunk:
        parts.append("'" + "".join(chunk) + "'")
    return "".join(parts) or "''"


class AuthenticationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (Path(__file__).resolve().parents[1] / "GetPerf.ttl").read_text(
            encoding="utf-8"
        )
        # Exercise the real startup checks, stopping before local or SSH work.
        cls.startup = source[:source.index("getdir scriptDir\n")]
        cls.prepare = source[source.index(":prepareAuthentication\n"):
                             source.index(":missing\n")]
        start = source.index("sprintf2 conn ")
        cls.connection = source[start:source.index("; This second connect", start)]
        start = source.index("if result = 2 then\n", source.index("timeout = 120\n"))
        root = source[start:source.index("timeout = TIME_LIMIT\n", start)]
        # Replace only terminal I/O; keep authentication decisions and clearing.
        cls.root = root.replace(
            "passwordbox 'su で使用する root のパスワード' 'RHEL root'",
            "rootPrompted = 1\n        inputstr = 'prompted-root'",
        ).replace(
            "sendbinary rootSecret #10", "sentRoot = rootSecret"
        ).replace(
            "waitregex 'PF_ROOT;' failPattern '(?i)^[ \\t]*password[ \\t]*:'",
            "result = 1",
        )
        if any(command in cls.root for command in ("passwordbox", "sendbinary", "waitregex")):
            raise AssertionError("Update test I/O stubs for the changed root exchange")

    def run_case(self, mode, login="test-login", root="test-root", *, worker=False,
                 error=None):
        startup = self.startup
        settings = {
            "SSH_HOST": "test.example", "REMOTE_PARENT": "/test",
            "AUTH_MODE": mode, "SSH_PASSWORD": login, "ROOT_PASSWORD": root,
        }
        for name, value in settings.items():
            startup, count = re.subn(
                rf"(?m)^{name}[ \t]*=.*$",
                lambda match: f"{name} = {ttl_string(value)}",
                startup, count=1,
            )
            self.assertEqual(count, 1, f"Missing setting: {name}")

        checks = []
        failures = {}

        def check(condition, description):
            code = len(failures) + 10
            failures[code] = description
            checks.append(f"if {condition} then\n    setexitcode {code}\n    end\nendif\n")

        def equal(variable, expected):
            checks.append(f"strcompare {variable} {ttl_string(expected)}\n")
            check("result != 0", f"Unexpected {variable}")

        if error:
            # All invalid configurations must fail during startup, before SSH.
            checks.append("setexitcode 2\nend\n:failed\n")
            checks.append(f"strscan err {ttl_string(error)}\n")
            check("result = 0", "Unexpected validation error")
        else:
            equal("err", "")
            automatic = worker or mode == "inline"
            check(f"usePassword != {int(automatic)}", "Wrong authentication mode")
            expected_login = login.replace('"', '""') if automatic else ""
            expected_root = root if automatic else ""
            equal("loginSecret", expected_login)
            equal("rootSecret", expected_root)
            equal("SSH_PASSWORD", "")
            equal("ROOT_PASSWORD", "")
            if worker:
                for name in ("TT_PERF_LOGIN", "TT_PERF_ROOT"):
                    checks.append(f"getenv '{name}' inheritedSecret\n")
                    equal("inheritedSecret", "")
            if mode != "saved" or worker:
                checks.append(self.connection)
                suffix = f' /passwd="{expected_login}"' if automatic else " /ask4passwd"
                equal("conn", "test.example:22 /ssh /2 /auth=password /user=spfai001 /timeout=45" + suffix)
                checks.append("rootPrompted = 0\nsentRoot = ''\nresult = 2\n" + self.root)
                equal("sentRoot", expected_root if automatic else "prompted-root")
                equal("rootSecret", "")
                check(f"rootPrompted != {int(not automatic)}", "Wrong root prompt behavior")
            checks.append("setexitcode 0\nend\n:failed\nsetexitcode 3\nend\n")
        checks.append("setexitcode 0\nend\n:noCredential\nsetexitcode 4\nend\n")
        checks.append(":remoteFail\nsetexitcode 5\nend\n")
        script = startup + "".join(checks) + self.prepare
        env = os.environ.copy()
        env.update(TT_PERF_HOST="test.example", TT_PERF_PARENT="/test",
                   TT_PERF_LOGIN=login.replace('"', '""'), TT_PERF_ROOT=root)
        # Keep temporary macros within the workspace for restricted environments.
        path = Path(__file__).with_name(f".auth-{uuid.uuid4().hex}.ttl")
        try:
            path.write_text(script, encoding="utf-8", newline="\r\n")
            args = [str(TTPMACRO), "/V", str(path)]
            if worker:
                args.append("saved-worker")
            result = subprocess.run(args, env=env, timeout=10, check=False,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
        finally:
            path.unlink(missing_ok=True)
        self.assertEqual(result.returncode, 0,
                         failures.get(result.returncode, f"Macro exit {result.returncode}"))

    def test_existing_modes(self):
        for mode, worker in (("ask", False), ("saved", False), ("saved", True)):
            with self.subTest(mode=mode, worker=worker):
                self.run_case(mode, login='test "quoted" login', worker=worker)
        # Unused inline settings must not affect interactive or saved startup.
        for mode in ("ask", "saved"):
            with self.subTest(mode=mode, unused_settings=True):
                self.run_case(mode, login="", root="")

    def test_inline_passwords(self):
        for login, root in (
            ("test-login", "test-root"),
            (' test; /user=other "quoted" \\ $%#\' ', ' root "\' \\ ;$%# '),
            ('日本語"の引用符"', '日本語の root "パスワード"'),
            ("a" * 240, "b" * 240),
            ('"' * 120, "test-root"),
            ("あ" * 80, "い" * 80),
        ):
            with self.subTest(login_bytes=len(login.encode()), root_bytes=len(root.encode())):
                self.run_case("inline", login, root)

    def test_invalid_inline_passwords(self):
        cases = [
            ("", "test-root", "両方"),
            ("test-login", "", "両方"),
            ("a" * 241, "test-root", "240"),
            ("test-login", "b" * 241, "240"),
            ('"' * 121, "test-root", "エスケープ後"),
            ("あ" * 81, "test-root", "240"),
            ("test-login", "い" * 81, "240"),
        ]
        for char in ("\t", "\r", "\n", "\x1b", "\x7f"):
            cases.extend((("test" + char, "test-root", "SSH_PASSWORD"),
                          ("test-login", "test" + char, "ROOT_PASSWORD")))
        for index, (login, root, error) in enumerate(cases):
            with self.subTest(case=index):
                self.run_case("inline", login, root, error=error)

    def test_invalid_mode(self):
        self.run_case("unknown", error="AUTH_MODE")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ttpmacro", type=Path, required=True)
    options, unittest_args = parser.parse_known_args()
    TTPMACRO = options.ttpmacro.resolve(strict=True)
    unittest.main(argv=[__file__, *unittest_args])
