import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from gaomenhu import VERSION_LABEL
from gaomenhu.native import EXTENSION_ORIGIN, browser_from_ancestors, run_native_host
from gaomenhu.store import default_data_dir


def main(arguments):
    if arguments and arguments[0] == EXTENSION_ORIGIN:
        return run_native_host(default_data_dir(), browser_from_ancestors())
    directory = Path(sys.executable if getattr(sys, "frozen", False) else __file__).resolve().parent
    if arguments == ["--capabilities"]:
        descriptor = directory / ("GaoCapabilities.json" if getattr(sys, "frozen", False) else "GaoCapabilities.Windows.json")
        try:
            sys.stdout.buffer.write(descriptor.read_bytes())
        except OSError:
            return 1
        return 0
    if arguments == ["--version"]:
        print(VERSION_LABEL)
        return 0
    if len(arguments) == 2 and arguments[0] == "--gaoaction":
        try:
            subprocess.Popen([directory / "GaoMenHu.exe", *arguments], cwd=directory)
        except OSError:
            return 1
        return 0
    if "--serve" in arguments or "--no-browser" in arguments:
        try:
            return subprocess.call([directory / "GaoMenHu.exe", *arguments], cwd=directory)
        except OSError:
            return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
