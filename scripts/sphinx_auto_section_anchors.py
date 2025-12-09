"""
sphinx_auto_section_anchors
===========================

A small, reusable Sphinx transform extension that assigns stable, slug-based
HTML anchors (ids) to section headings. It is intended to be robust for
version-like headings (e.g. ``25.12.1``, ``v1.2.0-rc1``) and ordinary
headings alike.

Put this file in a repository (for example your `.cicd` submodule in dir `scripts`)
and add the directory to ``sys.path`` in your project's ``docs/conf.py`` and
add the extension to ``extensions``.

Features
- Assigns an id like ``25-12-1`` for a heading ``25.12.1``.
- Works for any heading; you can limit behavior via config values.
- Doesn't overwrite existing ids by default (configurable).
- Ensures uniqueness by adding numeric suffixes when necessary.
- Configurable prefix and toggles via ``conf.py``.

Configuration options (add to your conf.py with desired values):

- ``auto_section_anchor_enabled`` (bool, default True) -- globally enable/disable.
- ``auto_section_anchor_force`` (bool, default False) -- if True, overwrite existing ids.
- ``auto_section_anchor_prefix`` (str, default "") -- string to prefix every generated id with.
- ``auto_section_anchor_pattern`` (str, default r"\\d+(?:[.-]\\d+)*") -- regex; only headings matching this pattern get anchors when pattern_mode is "match".
- ``auto_section_anchor_pattern_mode`` (str, default "any") -- one of: "any", "match", "all". If "match", only headings matching the pattern are processed. "any" processes all headings. "all" processes headings only if the _entire_ title matches the pattern.

Notes
- HTML5 allows ids that start with digits; we do not force a letter prefix by default so you will get anchors like ``#25-12-1``.
- The extension tries to be conservative: it will not stomp on existing ids unless you explicitly set ``auto_section_anchor_force = True``.

Usage example (in your docs/conf.py)::

    import os
    import sys
    sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '.cicd', 'scripts')))
    extensions.append('sphinx_auto_section_anchors')

Paste this file into your `.cicd` repo and reference it from each project's
``conf.py`` as shown above.

"""

from __future__ import annotations

import re
from typing import Set

from docutils import nodes
from sphinx.transforms import SphinxTransform


def _slugify(text: str) -> str:
    """Turn a heading text into a URL-friendly slug.

    Rules used here (deliberately simple and predictable):
    - strip leading/trailing whitespace
    - lowercase
    - replace any sequence of characters that are not alphanumerics
      (``[A-Za-z0-9]``) with a single dash "-"
    - collapse multiple dashes into one
    - strip leading/trailing dashes

    This produces compact slugs such as ``25-12-1``, ``v1-2-0-rc1`` or
    ``chapter-1-introduction``.
    """
    s = text.strip().lower()
    # replace non-alnum with dash
    s = re.sub(r"[^a-z0-9]+", "-", s)
    # collapse dashes
    s = re.sub(r"-+", "-", s)
    s = s.strip("-")
    return s or "section"


class AutoSectionAnchorTransform(SphinxTransform):
    """Sphinx Transform that assigns stable slug ids to section nodes."""

    default_priority = 210

    def _existing_ids(self) -> Set[str]:
        # docutils keeps a mapping of ids to nodes on the document
        return set(getattr(self.document, "ids", {}).keys())

    def apply(self) -> None:  # type: ignore[override]
        cfg_enabled = getattr(self.app.config, "auto_section_anchor_enabled", True)
        if not cfg_enabled:
            return

        used_ids: Set[str] = self._existing_ids()
        prefix: str = getattr(self.app.config, "auto_section_anchor_prefix", "") or ""
        force: bool = getattr(self.app.config, "auto_section_anchor_force", False)
        pattern: str = getattr(
            self.app.config, "auto_section_anchor_pattern", r"\d+(?:[.-]\d+)*"
        )
        pattern_mode: str = getattr(
            self.app.config, "auto_section_anchor_pattern_mode", "any"
        )

        try:
            pattern_re = re.compile(pattern)
        except re.error:
            pattern_re = re.compile(r"\d+(?:[.-]\d+)*")

        for node in list(self.document.traverse(nodes.section)):
            # find title child
            title_nodes = [n for n in node.children if isinstance(n, nodes.title)]
            if not title_nodes:
                continue
            title_node = title_nodes[0]
            title_text = title_node.astext()

            # decide whether to process this heading according to pattern_mode
            if pattern_mode == "match":
                if not pattern_re.search(title_text):
                    continue
            elif pattern_mode == "all":
                if not pattern_re.fullmatch(title_text):
                    continue
            # else 'any' -> process all headings

            # skip if there are already ids and we're not forcing
            existing_ids = node.get("ids", [])[:]
            if existing_ids and not force:
                # still record them so we don't later collide
                used_ids.update(existing_ids)
                continue

            base_slug = _slugify(title_text)
            candidate = f"{prefix}{base_slug}"

            # ensure uniqueness
            if candidate in used_ids:
                # append suffixes until unique
                i = 1
                while f"{candidate}-{i}" in used_ids:
                    i += 1
                candidate = f"{candidate}-{i}"

            # set ids and (optionally) names
            node["ids"] = [candidate]
            # docutils often stores names too; set where safe
            names = node.get("names", [])
            if candidate not in names:
                names.insert(0, candidate)
                node["names"] = names

            used_ids.add(candidate)


def setup(app):
    # config values
    app.add_config_value("auto_section_anchor_enabled", True, "env")
    app.add_config_value("auto_section_anchor_force", False, "env")
    app.add_config_value("auto_section_anchor_prefix", "", "env")
    app.add_config_value("auto_section_anchor_pattern", r"\d+(?:[.-]\d+)*", "env")
    app.add_config_value("auto_section_anchor_pattern_mode", "any", "env")

    app.add_transform(AutoSectionAnchorTransform)

    return {
        "version": "0.1",
        "parallel_read_safe": True,
        "parallel_write_safe": True,
    }
