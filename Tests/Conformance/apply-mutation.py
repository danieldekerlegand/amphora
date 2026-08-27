#!/usr/bin/env python3
"""Replace exact text in a file, or fail loudly. Used only by drift-control.sh.

The anchor is required to exist. A mutation that quietly matched nothing would leave the source
unchanged, the suite green, and the negative control reporting that the vectors caught a
divergence that was never introduced — a false pass in the one script whose entire job is to
rule false passes out.
"""
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: apply-mutation.py <file> <old-text> <new-text>", file=sys.stderr)
        return 2
    path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    count = text.count(old)
    if count == 0:
        print(
            "drift-control: mutation anchor not found in {}.\n"
            "The control is only as good as its anchor. Fix the anchor, do not delete the "
            "check:\n{}".format(path, old),
            file=sys.stderr,
        )
        return 1
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text.replace(old, new))
    print("drift-control: mutated {} occurrence(s) of the anchor in {}".format(count, path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
