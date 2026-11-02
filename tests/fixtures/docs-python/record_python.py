# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Stand-in documentation build that records the Python it ran on.

The fixtures under this directory call it from their tox environments
in place of sphinx-build. It prints the interpreter and fails unless
that interpreter is the major.minor version named on the command line,
so a passing build proves which Python tox chose for the environment.
"""

import sys

expected = sys.argv[1]
actual = f"{sys.version_info.major}.{sys.version_info.minor}"
_ = sys.stdout.write(f"Documentation Python: {sys.version} ({sys.executable})\n")
if actual != expected:
    sys.exit(f"Expected Python {expected}, ran on {actual}")
_ = sys.stdout.write(f"Ran on the declared Python {expected}\n")
