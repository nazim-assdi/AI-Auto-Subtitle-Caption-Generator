from __future__ import annotations

import sys

import argostranslate.package


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: python install_translation_model.py <source-code> <target-code>")
        print("Example: python install_translation_model.py en bn")
        return 2

    source = sys.argv[1].strip().lower()
    target = sys.argv[2].strip().lower()
    if not source or not target or source == target:
        print("Source and target must be different language codes.")
        return 2

    print("Updating the Argos offline translation model index...")
    argostranslate.package.update_package_index()
    packages = argostranslate.package.get_available_packages()

    direct = [p for p in packages if p.from_code == source and p.to_code == target]
    chosen = direct
    if not chosen:
        # Prefer a two-hop offline route through English if no direct package exists.
        first = [p for p in packages if p.from_code == source and p.to_code == "en"]
        second = [p for p in packages if p.from_code == "en" and p.to_code == target]
        if first and second:
            chosen = [first[0], second[0]]

    if not chosen:
        print(f"No published Argos package route found for {source} -> {target}.")
        print("Check the available package index or choose another target language.")
        return 1

    for package in chosen:
        print(f"Downloading and installing {package.from_code} -> {package.to_code} ...")
        package.install()

    print("Offline translation model installation complete.")
    print("Restart start_backend.bat, then check http://127.0.0.1:8000/translation/status")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
