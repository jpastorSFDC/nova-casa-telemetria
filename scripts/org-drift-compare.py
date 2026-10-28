#!/usr/bin/env python3
"""Real differences between what `org-check.sh drift` retrieved from the org and origin/main.

Usage: org-drift-compare.py <worktree>

The worktree is at origin/main with the org's version of each component written over it, so `git status` lists
every file the org spells differently. Most of those differ only in how the platform writes the file back, not in
what it says. This script compares meaning instead of text.

Apex, JS, HTML and CSS: trailing spaces and line endings are ignored.

XML: the order of elements is ignored, and so are the things the platform does on its own (each is a rule below,
so it can be argued with):
  * a boolean that is `false` counts the same as a boolean that isn't there;
  * `actionOverrides` of type Default, and the elements in PLATFORM_ADDS that the org fills in when the repo
    doesn't carry them (an element the repo does carry is still compared);
  * `allocatedPartnerCapacity` and `parameterGroup`, which the org adds inside elements the repo has;
  * a flexipage component written as `c:name` or `name`, and a layout field that is `Readonly` or `Required`
    (the org turns one into the other for fields it always fills);
  * formula fields: `precision` and `formulaTreatBlanksAs`;
  * standard objects (Account, Asset, Case...), profiles and settings: the repo carries only what Nova Casa
    changes, so only what the repo says and the org doesn't is reported, never what the org has besides.

Whatever is left is printed as REPO-ONLY (the repo says it and the org doesn't) or ORG-ONLY (the other way round).
It reads the repo and the worktree; it writes nothing and prints no Ids, usernames or tokens.
"""
import collections
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

PLATFORM_ADDS = {
    "compactLayoutAssignment", "contactAccessLevel", "deleteConstraint", "enableBulkApi", "enableFeeds",
    "enableSharing", "enableStreamingApi", "externalSharingModel", "feedLayout", "numPartitions", "partitionKey",
    "relationshipOrder", "searchLayouts", "summaryLayout", "visibility",
}
DROP_ANYWHERE = {"allocatedPartnerCapacity", "parameterGroup"}
FORMULA_NOISE = {"precision", "formulaTreatBlanksAs"}


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, errors="replace").stdout


def local_name(tag):
    return tag.split("}", 1)[1] if "}" in tag else tag


def cleaned(el, path):
    """A copy of el's meaning: no false booleans, no platform-only elements, equivalent spellings folded."""
    name = local_name(el.tag)
    text = (el.text or "").strip()
    if not len(el):
        if text == "false" or name in DROP_ANYWHERE:
            return None
        if name == "componentName" and text.startswith("c:"):
            text = text[2:]
        if name == "behavior" and text == "Readonly" and path.endswith(".layout-meta.xml"):
            text = "Required"
    kids = [k for k in (cleaned(c, path) for c in el) if k is not None]
    if len(el) and not kids and name != "actionOverrides":
        return None
    return (name, text, tuple(sorted(kids)))


def render(node):
    name, text, kids = node
    return f"<{name}>{text}{''.join(render(k) for k in kids)}</{name}>"


def readable(node, limit=170):
    spaced = re.sub(r"</?[A-Za-z0-9_]+>", lambda m: " " if m.group(0).startswith("</") else "{" + m.group(0)[1:-1] + ":", render(node))
    return spaced[:limit]


def top_leaves(xml_text, path):
    root = ET.fromstring(xml_text.encode("utf-8"))
    formula = root.find("{*}formula") is not None
    result = collections.Counter()
    for child in root:
        name = local_name(child.tag)
        if formula and name in FORMULA_NOISE:
            continue
        node = cleaned(child, path)
        if node is None:
            continue
        if name == "actionOverrides" and "<type>Default</type>" in render(node):
            continue
        result[node] += 1
    return result


def partial_in_repo(path):
    """Standard objects, profiles and settings: the repo file lists only what Nova Casa changes."""
    base = os.path.basename(path)
    if path.endswith((".profile-meta.xml", ".settings-meta.xml")):
        return True
    m = re.fullmatch(r"([A-Za-z0-9]+)\.object-meta\.xml", base)
    return bool(m) and os.path.basename(os.path.dirname(path)) == m.group(1) and "__" not in m.group(1)


def is_standard_part(path):
    """A file or folder inside a standard object's folder that isn't ours: it has no custom marker (__) in its name
    and, for a list view, doesn't start with Nova_Casa."""
    m = re.search(r"/objects/([A-Za-z0-9]+)/[A-Za-z]+/([^/]+)/?$", path)
    if not m:
        return False
    name = m.group(2)
    return "__" not in name and not name.startswith("Nova_Casa")


def main(root):
    os.chdir(root)
    entries = [e for e in git("status", "--porcelain", "-z", "-uall").split("\0") if e]
    modified = sorted(e[3:] for e in entries if e[:2].strip() == "M")
    org_only_files = sorted(e[3:] for e in entries if e.startswith("??"))
    # an Apex class or a bundle file comes with its -meta.xml: list the component once
    org_only_files = [f for f in org_only_files if not (f.endswith(".cls-meta.xml") or f.endswith(".trigger-meta.xml"))]
    # retrieving a standard object also brings its standard fields, record types and list views; those aren't ours.
    # A custom field (__c) or list view added by hand to a standard object still shows.
    org_only_files = [f for f in org_only_files if not is_standard_part(f)]
    # one line per LWC bundle instead of one per file
    org_only_files = sorted({re.sub(r"(/lwc/[^/]+)/.*", r"\1/", f) for f in org_only_files})

    same = 0
    text_diffs, xml_diffs = [], {}
    for path in modified:
        if not os.path.exists(path):
            continue
        org = open(path, encoding="utf-8", errors="replace").read()
        repo = git("show", f"HEAD:{path}")
        if path.endswith(".xml"):
            try:
                a, b = top_leaves(repo, path), top_leaves(org, path)
            except ET.ParseError as err:
                xml_diffs[path] = ("parse error", [str(err)], [])
                continue
            repo_names = {n[0] for n in a}
            repo_only = list((a - b).elements())
            org_extra = [] if partial_in_repo(path) else [
                x for x in (b - a).elements() if not (x[0] in PLATFORM_ADDS and x[0] not in repo_names)
            ]
            if repo_only or org_extra:
                xml_diffs[path] = ("diff", repo_only, org_extra)
            else:
                same += 1
        else:
            norm = lambda s: re.sub(r"[ \t\r]+\n", "\n", s).replace("\r", "").strip()
            if norm(repo) != norm(org):
                text_diffs.append(path)
            else:
                same += 1

    print(f"Files the org writes differently: {len(modified)}; same meaning after normalizing: {same}")
    print(f"Text files (Apex, JS, HTML, CSS) that really differ: {len(text_diffs)}")
    for path in text_diffs:
        print("   ", path)
    print(f"XML files that really differ: {len(xml_diffs)}")
    for path, (kind, repo_only, org_extra) in xml_diffs.items():
        print(f"## {path.replace('force-app/main/default/', '')}" + (" (parse error)" if kind == "parse error" else ""))
        for leaf in repo_only[:6]:
            print("   REPO-ONLY:", leaf if kind == "parse error" else readable(leaf))
        if len(repo_only) > 6:
            print(f"   ... +{len(repo_only) - 6} more repo-only")
        for leaf in org_extra[:4]:
            print("   ORG-ONLY :", readable(leaf))
        if len(org_extra) > 4:
            print(f"   ... +{len(org_extra) - 4} more org-only")
    print(f"Files only in the org (not in the repo): {len(org_only_files)}")
    for path in org_only_files[:40]:
        print("   ", path.replace("force-app/main/default/", ""))
    if len(org_only_files) > 40:
        print(f"   ... +{len(org_only_files) - 40} more")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
