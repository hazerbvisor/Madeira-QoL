#!/usr/bin/env python3
"""Relink a finished xtool release as a runtime dylib; build its small launcher.

Run after `xtool dev build --configuration release --ipa` has finished. This
does not rebuild or alter the native dependencies, or invoke GitHub Actions.
"""
import argparse
import json
from pathlib import Path
import subprocess


def link_command(build_yaml):
    lines = build_yaml.read_text().splitlines()
    for index, line in enumerate(lines):
        if line.strip() == '"C.Madeira-App-arm64-apple-ios-release.exe":':
            for command in lines[index + 1:]:
                if command.startswith('  "'):
                    break
                if command.strip().startswith('args: '):
                    return json.loads(command.strip()[6:])
    raise ValueError("Could not find the xtool release app link command")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-yaml", required=True, type=Path)
    parser.add_argument("--clang", default="clang")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    command = link_command(args.build_yaml)
    if "-emit-executable" not in command or "-sdk" not in command:
        parser.error("Expected a finished iOS SwiftPM executable link command")
    sdk = command[command.index("-sdk") + 1]
    command[command.index("-emit-executable")] = "-emit-library"
    command[command.index("-o") + 1] = str(args.output_dir / "MadeiraQoL.dylib")
    command.extend(["-Xlinker", "-install_name", "-Xlinker", "@rpath/MadeiraQoL.dylib"])
    subprocess.run(command, check=True)
    sources = Path(__file__).resolve().parents[1] / "app/RuntimeLauncher"
    subprocess.run([
        args.clang, "-target", "arm64-apple-ios17.0", "-isysroot", sdk,
        "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror",
        "-Wno-unused-parameter", str(sources / "main.m"), str(sources / "RuntimeLoader.c"),
        "-framework", "UIKit", "-framework", "Foundation",
        "-Wl,-rpath,@executable_path", "-Wl,-rpath,@executable_path/Frameworks",
        "-o", str(args.output_dir / "MadeiraRuntimeLauncher"),
    ], check=True)
    print("Built launcher and QoL runtime; original runtime must come from the pinned release IPA.")


if __name__ == "__main__":
    main()
