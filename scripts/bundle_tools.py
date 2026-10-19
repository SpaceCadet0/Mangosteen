#!/usr/bin/env python3
"""Copy the command-line tools Mangosteen uses (from Homebrew) into an app bundle.

Every non-system dynamic library the tools need is copied next to them and their references are
rewritten to @loader_path, so the app no longer depends on Homebrew. Everything is re-signed ad hoc,
which Apple silicon requires after install_name_tool edits.

Usage: bundle_tools.py <path to Mangosteen.app>
"""
import os
import shutil
import subprocess
import sys

TOOLS = ["ffmpeg", "ffprobe", "cwebp", "gif2webp"]
SEARCH = ["/opt/homebrew/bin", "/usr/local/bin"]
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def dependencies(path):
    """Library references of a Mach-O file, excluding its own install name."""
    lines = run("otool", "-L", path).splitlines()[1:]
    own = run("otool", "-D", path).splitlines()[1:]
    refs = [line.strip().split(" (")[0] for line in lines]
    return [ref for ref in refs if ref not in own]


def rpaths(path):
    """LC_RPATH entries, with @loader_path resolved against the file's directory."""
    result = []
    lines = run("otool", "-l", path).splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            entry = lines[index + 2].strip().split(" ")[1]
            result.append(entry.replace("@loader_path", os.path.dirname(path)))
    return result


def resolve(reference, referrer):
    """Absolute path of a library reference made by `referrer` (an original, not a copy)."""
    if reference.startswith("@rpath/"):
        name = reference[len("@rpath/"):]
        for base in rpaths(referrer) + [os.path.dirname(referrer)]:
            candidate = os.path.join(base, name)
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        raise SystemExit(f"cannot resolve {reference} for {referrer}")
    if reference.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(os.path.dirname(referrer), reference[len("@loader_path/"):]))
    return os.path.realpath(reference)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    app = sys.argv[1]
    tools_dir = os.path.join(app, "Contents", "Resources", "Tools")
    lib_dir = os.path.join(tools_dir, "lib")
    shutil.rmtree(tools_dir, ignore_errors=True)
    os.makedirs(lib_dir)

    copied = {}  # original real path -> bundled path
    pending = []

    def bundle(original, destination):
        copied[original] = destination
        shutil.copy2(original, destination)
        os.chmod(destination, 0o755)
        pending.append(original)

    for tool in TOOLS:
        source = next((os.path.join(d, tool) for d in SEARCH if os.path.exists(os.path.join(d, tool))), None)
        if source is None:
            raise SystemExit(f"{tool} not found; install it with Homebrew first")
        bundle(os.path.realpath(source), os.path.join(tools_dir, tool))

    while pending:
        original = pending.pop()
        bundled = copied[original]
        in_lib = os.path.dirname(bundled) == lib_dir
        for reference in dependencies(original):
            if reference.startswith(SYSTEM_PREFIXES):
                continue
            library = resolve(reference, original)
            name = os.path.basename(reference)
            if library not in copied:
                bundle(library, os.path.join(lib_dir, name))
            target = f"@loader_path/{name}" if in_lib else f"@loader_path/lib/{name}"
            run("install_name_tool", "-change", reference, target, bundled)
        if in_lib:
            run("install_name_tool", "-id", f"@loader_path/{os.path.basename(bundled)}", bundled)

    for path in copied.values():
        run("codesign", "--force", "--sign", "-", path)

    # Nothing may still point into Homebrew.
    leftovers = [f"{path}: {ref}" for path in copied.values() for ref in dependencies(path)
                 if ref.startswith(("/opt/homebrew", "/usr/local", "@rpath"))]
    if leftovers:
        raise SystemExit("unbundled references:\n" + "\n".join(leftovers))
    libraries = len([p for p in copied.values() if os.path.dirname(p) == lib_dir])
    print(f"bundled {len(TOOLS)} tools and {libraries} libraries into {tools_dir}")


if __name__ == "__main__":
    main()
