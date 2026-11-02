#!/usr/bin/env python3
"""Regenerates the Windows .resx files from the macOS string catalogues.

windows/tools/StringsToResx is the real generator, and windows-ci fails if its
output is stale. It needs dotnet, which the Mac this is built on doesn't have,
so this reproduces its output byte for byte. Run it after changing any
Localizable.strings. `--check` reports stale files without writing them.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGUAGES = [("en", ""), ("de", ".de"), ("zh-Hans", ".zh-Hans"), ("zh-Hant", ".zh-Hant")]
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
SPECIFIER = r"%(?:\d+\$)?(?:[-+ #0]*\d*(?:\.\d+)?)?(?:@|ll[du]|l[du]|[dfsu@])"
LITERAL_OR_SPECIFIER = re.compile("%%|" + SPECIFIER)
PLATFORM_TERMS = ["macOS", "Mac ", "the Mac", "menu bar", "Menu bar", "Menu Bar",
                  "Keychain", "Finder", "Dock", "System Settings", "AirDrop"]
OVERRIDES = [("macOS", "Windows"), ("System Settings", "Settings"), ("Keychain", "Credential Manager")]
OUTPUT = os.path.join(ROOT, "windows", "src", "NetFluss.Core", "Resources")


def parse(path):
    entries = {}
    in_comment = False
    with open(path, encoding="utf-8-sig") as handle:
        text = handle.read().replace("\r\n", "\n")
    for number, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if in_comment:
            in_comment = "*/" not in line
            continue
        if line.startswith("/*"):
            in_comment = "*/" not in line
            continue
        if not line or line.startswith("//"):
            continue
        match = ENTRY.match(line)
        if not match:
            sys.exit(f"{path}:{number}: cannot parse: {raw!r}")
        key, value = unescape(match.group(1)), unescape(match.group(2))
        if key in entries:
            sys.exit(f"{path}:{number}: duplicate key {key!r}")
        entries[key] = value
    return entries


def unescape(text):
    return text.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\")


def convert(text):
    text = text.replace("{", "{{").replace("}", "}}")
    index = [0]

    def replace(match):
        if match.group(0) == "%%":
            return "%"
        index[0] += 1
        return "{%d}" % (index[0] - 1)

    return LITERAL_OR_SPECIFIER.sub(replace, text)


def placeholders(text):
    return sum(1 for match in LITERAL_OR_SPECIFIER.finditer(text) if match.group(0) != "%%")


def fold(text):
    return text.upper().lower()


def resolve_collisions(keys):
    groups = {}
    for key in keys:
        groups.setdefault(fold(key), []).append(key)
    names = {}
    taken = {fold(key) for key in keys}
    for members in groups.values():
        names[members[0]] = members[0]
        for offset, key in enumerate(members[1:], 2):
            name = f"{key}~{offset}"
            if fold(name) in taken:
                sys.exit(f"disambiguating {key!r} collides with a real key")
            taken.add(fold(name))
            names[key] = name
    return names


def escape(text):
    return text.replace("&", "&amp;").replace(">", "&gt;").replace("<", "&lt;")


def escape_attribute(text):
    return (escape(text).replace('"', "&quot;").replace("'", "&apos;")
            .replace("\n", "&#10;").replace("\t", "&#9;"))


def review_row(language, key, status, value):
    return f"| `{language}` | `{key.replace('|', chr(92) + '|')}` | {status} | {value.replace('|', chr(92) + '|')} |"


def main():
    check = "--check" in sys.argv
    mac, windows = {}, {}
    for language, _ in LANGUAGES:
        mac[language] = parse(os.path.join(ROOT, "Packaging", "Resources", f"{language}.lproj", "Localizable.strings"))
        path = os.path.join(ROOT, "windows", "Localization", f"{language}.lproj", "Windows.strings")
        windows[language] = parse(path) if os.path.exists(path) else {}

    ordered, seen = [], set()
    for catalogue in list(mac.values()) + list(windows.values()):
        for key in catalogue:
            converted = convert(key)
            if converted not in seen:
                seen.add(converted)
                ordered.append(converted)
    names = resolve_collisions(ordered)

    with open(os.path.join(OUTPUT, "Strings.resx"), encoding="utf-8") as handle:
        existing = handle.read().replace("\r\n", "\n")
    header = existing[:existing.index("  <data ")]

    english = set(mac["en"]) | set(windows["en"])
    review, generated = [], []
    for language, suffix in LANGUAGES:
        keys = set(mac[language]) | set(windows[language])
        for label, difference in (("missing", english - keys), ("extra", keys - english)):
            if difference:
                print(f"warning: {language} {label} {len(difference)} key(s): {sorted(difference)[:3]}")
        for catalogue in (mac[language], windows[language]):
            for key, value in catalogue.items():
                if placeholders(key) != placeholders(value):
                    sys.exit(f"{language}: placeholders differ from the key: {key!r}")

        converted = []
        for key, mac_value in mac[language].items():
            if key in windows[language]:
                converted.append((names[convert(key)], convert(windows[language][key])))
                review.append(review_row(language, key, "windows override", windows[language][key]))
                continue
            value = mac_value
            for term, substitute in OVERRIDES:
                value = value.replace(term, substitute)
            overridden = value != mac_value
            converted.append((names[convert(key)], convert(value)))
            if overridden or any(term in value for term in PLATFORM_TERMS):
                review.append(review_row(language, key, "auto-rewritten" if overridden else "needs review", value))
        for key, value in windows[language].items():
            if key not in mac[language]:
                converted.append((names[convert(key)], convert(value)))

        body = "".join(
            f'  <data name="{escape_attribute(name)}" xml:space="preserve">\n'
            f"    <value>{escape(value)}</value>\n  </data>\n"
            for name, value in converted
        )
        generated.append((os.path.join(OUTPUT, f"Strings{suffix}.resx"), header + body + "</root>\n"))

    report = [
        "# Platform vocabulary review",
        "",
        "Generated by `windows/tools/StringsToResx`. Every string below mentions a",
        "platform-specific concept that may not be correct on Windows. Rows marked",
        "*auto-rewritten* were changed by `PlatformOverrides`; *windows override* rows use the",
        "wording from windows/Localization/*.lproj/Windows.strings; rows marked *needs review*",
        "were left alone and want a human decision.",
        "",
        "| Language | Key | Status | Value |",
        "| --- | --- | --- | --- |",
    ] + review + [""]
    generated.append((os.path.join(OUTPUT, "platform-review.md"), "\n".join(report)))

    stale = []
    for path, content in generated:
        with open(path, encoding="utf-8") as handle:
            current = handle.read().replace("\r\n", "\n")
        if current == content:
            continue
        stale.append(os.path.relpath(path, ROOT))
        if not check:
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(content)
    print(("stale: " if check else "rewrote: ") + (", ".join(stale) or "nothing"))
    return 1 if check and stale else 0


if __name__ == "__main__":
    sys.exit(main())
