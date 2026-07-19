#!/usr/bin/env python3
"""Update Sparkle appcasts and the legacy update feed after a release.

Reads the <zip>.sparkle.json metadata files produced by package-app.sh and
inserts a new <item> at the top of each variant's appcast. Also rewrites the
legacy docs/update-feed.json so pre-Sparkle builds still learn about new
releases.
"""
import argparse
import html
import json
import pathlib
import re
import sys
from datetime import datetime, timezone
from email.utils import formatdate

VARIANTS = {
    "Koe-macOS-arm64.zip": "docs/appcast.xml",
    "Koe-MLX-macOS-arm64.zip": "docs/appcast-mlx.xml",
}

# Pre-Sparkle builds all poll the single legacy feed, and the old
# Koe-macOS-arm64.zip they shipped from was the full (MLX) build — point them
# at the MLX zip so nobody silently loses on-device ASR support.
LEGACY_FEED_ZIP = "Koe-MLX-macOS-arm64.zip"

ITEM_TEMPLATE = """    <item>
      <title>Version {version}</title>
      <link>{notes_url}</link>{description}
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
      <pubDate>{pub_date}</pubDate>
      <enclosure url="{url}"
        sparkle:edSignature="{signature}"
        length="{length}"
        type="application/octet-stream" />
    </item>"""


INLINE_CODE_RE = re.compile(r"`([^`]+)`")
BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")


def md_inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = INLINE_CODE_RE.sub(r"<code>\1</code>", text)
    text = BOLD_RE.sub(r"<strong>\1</strong>", text)
    return text


def md_to_html(lines: list) -> str:
    """Convert the changelog's markdown subset (### headings, wrapped '- '
    bullets, plain paragraphs) to HTML for Sparkle's release-notes view."""
    out = []
    bullets = []

    def flush():
        if bullets:
            out.append("<ul>")
            for item in bullets:
                out.append("<li>%s</li>" % md_inline(" ".join(item)))
            out.append("</ul>")
            bullets.clear()

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("### "):
            flush()
            out.append("<h3>%s</h3>" % md_inline(stripped[4:]))
        elif stripped.startswith("- "):
            bullets.append([stripped[2:]])
        elif stripped and bullets:
            # Continuation of a wrapped bullet.
            bullets[-1].append(stripped)
        elif stripped:
            flush()
            out.append("<p>%s</p>" % md_inline(stripped))
        else:
            flush()
    flush()
    return "\n".join(out)


def changelog_html(version: str) -> str:
    """Extract the '## <version>' section from CHANGELOG.md as HTML.
    Returns an empty string when the section is missing."""
    path = pathlib.Path("CHANGELOG.md")
    if not path.exists():
        return ""
    section = []
    in_section = False
    for line in path.read_text().splitlines():
        if line.startswith("## "):
            if in_section:
                break
            heading = line[3:].strip()
            if heading.split(" - ")[0].strip() == version:
                in_section = True
            continue
        if in_section:
            section.append(line)
    if not in_section:
        return ""
    return md_to_html(section)


def description_block(version: str, notes_url: str) -> str:
    """Sparkle renders <description> HTML directly in the update dialog."""
    notes = changelog_html(version)
    if not notes:
        notes = '<p>See the <a href="%s">full release notes</a>.</p>' % notes_url
    # A CDATA section must not contain the ']]>' terminator.
    notes = notes.replace("]]>", "]]&gt;")
    return "\n      <description><![CDATA[\n%s\n      ]]></description>" % notes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True, help="release tag, e.g. v1.0.17")
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--dist", required=True, help="directory holding the zips and .sparkle.json files")
    args = parser.parse_args()

    dist = pathlib.Path(args.dist)
    pub_date = formatdate(usegmt=True)
    notes_url = f"https://github.com/{args.repo}/releases/tag/{args.tag}"
    legacy_meta = None

    for zip_name, appcast_path in VARIANTS.items():
        meta_path = dist / f"{zip_name}.sparkle.json"
        if not meta_path.exists():
            sys.exit(f"missing Sparkle metadata: {meta_path}")
        meta = json.loads(meta_path.read_text())
        if zip_name == LEGACY_FEED_ZIP:
            legacy_meta = meta

        url = f"https://github.com/{args.repo}/releases/download/{args.tag}/{zip_name}"
        appcast = pathlib.Path(appcast_path)
        xml = appcast.read_text()
        if url in xml:
            print(f"{appcast_path}: item for {args.tag} already present, skipping")
            continue

        item = ITEM_TEMPLATE.format(
            version=meta["version"],
            build=meta["build"],
            min_os=meta["minimum_system_version"],
            pub_date=pub_date,
            url=url,
            signature=meta["signature"],
            length=meta["length"],
            notes_url=notes_url,
            description=description_block(meta["version"], notes_url),
        )
        new_xml, count = re.subn(
            r"(<language>en</language>)",
            lambda m: m.group(1) + "\n" + item,
            xml,
            count=1,
        )
        if count != 1:
            sys.exit(f"{appcast_path}: could not find <language> insertion point")
        appcast.write_text(new_xml)
        print(f"{appcast_path}: added {meta['version']} ({meta['build']})")

    # Legacy feed for pre-Sparkle builds.
    legacy = pathlib.Path("docs/update-feed.json")
    feed = json.loads(legacy.read_text())
    feed.update({
        "version": legacy_meta["version"],
        "build": int(legacy_meta["build"]),
        "published_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "minimum_system_version": legacy_meta["minimum_system_version"],
        "download_url": f"https://github.com/{args.repo}/releases/download/{args.tag}/{LEGACY_FEED_ZIP}",
        "release_notes_url": notes_url,
        "notes": [f"See the full release notes at {notes_url}"],
    })
    legacy.write_text(json.dumps(feed, indent=2) + "\n")
    print("docs/update-feed.json: updated")


if __name__ == "__main__":
    main()
